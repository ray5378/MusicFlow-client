// batch37 C —— `lib/features/discover/widgets/random_songs_section.dart` 剩余未覆盖分支。
//
// 既有 b34c 已覆盖骨架/缓存/TTL/刷新/本机播完续播/本机推送追加/高亮；本文件专补：
//   * activeLibraryProvider listenManual 回调：活跃库由空切到就绪 → 补读缓存（81-85）；
//   * castPeerControllerProvider listenManual 回调：投屏队列播完 → _loadNextRound（89-98）；
//   * _loadCachedSongs 缓存读取异常兜底网络拉取（149/153）；
//   * _fetchLatestForDisplay 拉取失败静默（167）；
//   * _playRound 无内容时回退刷新一批（203）；
//   * _handleRandomSongsChanged 的**投屏(cast)分支**（256-271）与
//     **DLNA 直投分支**（272-282）；
//   * 单曲点击播放（361-366）与 onOpenActions 打开歌曲选项（368-370）。
//
// 只写 test/，只读 lib/。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/discover/widgets/discover_song_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/random_songs_section.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../../player/test_player_notifier.dart';

final _activeLib = StateProvider<MusicLibrary?>((ref) => null);

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<int> playQueueStartIndices = <int>[];
  final List<List<String>> addAllToQueueCalls = <List<String>>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls.add(songs.map((Song s) => s.id).toList());
    playQueueStartIndices.add(startIndex);
    state = state.copyWith(
      queue: songs,
      currentIndex: startIndex,
      currentSong: songs.isEmpty ? null : songs[startIndex],
    );
  }

  @override
  void addAllToQueue(List<Song> songs) {
    addAllToQueueCalls.add(songs.map((Song s) => s.id).toList());
    state = state.copyWith(queue: <Song>[...state.queue, ...songs]);
  }
}

class _MutableCastPeer extends CastPeerController {
  _MutableCastPeer(super.ref);

  final List<List<String>> enqueueCalls = <List<String>>[];

  void setActive(PeerInfo peer, {List<Map<String, dynamic>> queue = const []}) {
    state = CastPeerState(activePeer: peer, castQueue: queue, castIndex: 0);
  }

  void bumpEndOfQueue() {
    state = state.copyWith(endOfQueueCount: state.endOfQueueCount + 1);
  }

  @override
  Future<void> enqueueSongs(List<dynamic> songs) async {
    enqueueCalls.add(songs.map((dynamic e) => (e as Song).id).toList());
  }
}

class _MutableDlnaCast extends DlnaCastNotifier {
  _MutableDlnaCast(super.ref);

  final List<List<String>> enqueueCalls = <List<String>>[];

  void setCasting(List<DlnaCastTrack> queue) {
    state = DlnaCastState(isCasting: true, queue: queue, currentIndex: 0);
  }

  @override
  Future<void> enqueueSongs(List<Song> songs) async {
    enqueueCalls.add(songs.map((Song s) => s.id).toList());
  }
}

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakeCache extends MetadataCacheRepository {
  _FakeCache({this.cached, this.lastLibraryId = 'lib-1', this.throwOnRead = false});

  ({List<Song> songs, DateTime cachedAt})? cached;
  String? lastLibraryId;
  bool throwOnRead;

  @override
  Future<String?> getLastLibraryId() async => lastLibraryId;

  @override
  Future<({List<Song> songs, DateTime cachedAt})?> getRandomSongsWithMeta(
    String libraryId,
  ) async {
    if (throwOnRead) throw StateError('corrupt cache');
    return cached;
  }
}

Song _song(String id, String title) =>
    Song(id: id, title: title, artist: '歌手', duration: 180);

PeerInfo _peer(String id, {String name = '设备'}) =>
    PeerInfo(peerId: id, name: name, kind: 'dlna', available: true, self: false);

MusicLibrary _library() => MusicLibrary(
      id: 'lib-1',
      name: '测试库',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    );

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Harness {
  _Harness({this.cache});

  final _RecordingPlayer player = _RecordingPlayer();
  _MutableCastPeer? cast;
  _MutableDlnaCast? dlna;
  _FakeCache? cache;
  List<Song> fetched = <Song>[];
  int fetchCount = 0;
  bool alwaysThrow = false;
  bool throwOnce = false;
  late final ProviderContainer container;

  Widget build() {
    final library = _library();
    final client = SubsonicApiClient(
      dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
    )..setLibrary(library);
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        activeLibraryProvider.overrideWith((ref) => ref.watch(_activeLib)),
        activeAddressProvider.overrideWith(
          (ref) => ServerAddress(
            id: 'addr',
            libraryId: 'lib-1',
            label: '测试',
            url: 'http://127.0.0.1:4533',
            priority: 0,
            status: ServerAddressStatus.unknown,
          ),
        ),
        metadataCacheRepositoryProvider.overrideWithValue(cache ?? _FakeCache()),
        musicRepositoryProvider.overrideWithValue(_FakeMusicRepository()),
        playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
        randomSongsProvider.overrideWith((ref) async {
          fetchCount += 1;
          if (alwaysThrow) throw StateError('network down');
          if (throwOnce) {
            throwOnce = false;
            throw StateError('first call fails');
          }
          return fetched;
        }),
        playerProvider.overrideWith((ref) => player),
        castPeerControllerProvider.overrideWith((ref) => cast = _MutableCastPeer(ref)),
        dlnaCastProvider.overrideWith((ref) => dlna = _MutableDlnaCast(ref)),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 900, child: RandomSongsSection()),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container.dispose());
    await tester.pumpWidget(build());
    await settle(tester);
  }
}

Finder get _section => find.byKey(const Key('discover-random-mix'));

void main() {
  testWidgets('活跃库由空切到就绪 → listenManual 回调补读缓存', (tester) async {
    final h = _Harness(cache: _FakeCache(lastLibraryId: null));
    h.fetched = <Song>[_song('s1', '晴天')];
    await h.pump(tester);
    expect(h.fetchCount, 0, reason: '库为 null 且无最近库 → 初始化不拉取');

    h.container.read(_activeLib.notifier).state = _library();
    await settle(tester);

    expect(h.fetchCount, 1, reason: '活跃库就绪 → 补读缓存/后台拉取一次');
    expect(find.byType(DiscoverSongTile), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存读取抛错 → 兜底网络拉取一次', (tester) async {
    final h = _Harness(cache: _FakeCache(throwOnRead: true));
    h.fetched = <Song>[_song('s1', '晴天')];
    await h.pump(tester);

    expect(h.fetchCount, 1, reason: '缓存坏数据不阻断首屏，回退网络拉取');
    expect(tester.takeException(), isNull);
  });

  testWidgets('后台拉取失败 → 静默吞掉，区块不崩', (tester) async {
    final h = _Harness();
    h.alwaysThrow = true;
    await h.pump(tester);

    expect(h.fetchCount, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('无内容时点播放 → _playRound 回退刷新一批后起播', (tester) async {
    final h = _Harness();
    h.throwOnce = true; // 首载拉取失败 → 区块无内容
    h.fetched = <Song>[_song('s1', '晴天')];
    await h.pump(tester);
    expect(h.player.playQueueCalls, isEmpty);

    await tester.tap(find.byIcon(AppIcons.play));
    await settle(tester, frames: 8);

    expect(h.player.playQueueCalls, <List<String>>[
      <String>['s1'],
    ], reason: '无展示内容时回退拉取一批再播');
    expect(tester.takeException(), isNull);
  });

  testWidgets('投屏(cast)播放中收到推送 → enqueueSongs 追加新歌', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
    );
    h.fetched = <Song>[_song('s1', '晴天'), _song('s2', '七里香')];
    await h.pump(tester);

    // 本机起播建立随机轮次 + _roundSongIds。
    await tester.tap(find.byIcon(AppIcons.play));
    await settle(tester, frames: 6);
    expect(h.player.playQueueCalls, hasLength(1));

    // 切到投屏态：设备队列已含本轮整批随机歌 s1/s2（真机投屏播放的是整轮队列）。
    h.cast!.setActive(
      _peer('dlna:AAA'),
      queue: <Map<String, dynamic>>[
        <String, dynamic>{'songId': 's1', 'title': '晴天'},
        <String, dynamic>{'songId': 's2', 'title': '七里香'},
      ],
    );
    await settle(tester, frames: 3);

    // 推送到达，新批含新歌 s3。
    h.fetched = <Song>[
      _song('s1', '晴天'),
      _song('s2', '七里香'),
      _song('s3', '夜曲'),
    ];
    notifyRandomSongsChanged();
    await settle(tester, frames: 8);

    expect(h.cast!.enqueueCalls, <List<String>>[
      <String>['s3'],
    ], reason: '投屏链路按 id 去重后只追加 s3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('DLNA 直投播放中收到推送 → enqueueSongs 追加新歌', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
    );
    h.fetched = <Song>[_song('s1', '晴天'), _song('s2', '七里香')];
    await h.pump(tester);

    await tester.tap(find.byIcon(AppIcons.play));
    await settle(tester, frames: 6);
    expect(h.player.playQueueCalls, hasLength(1));

    // DLNA 直投态：直投队列已含本轮整批随机歌 s1/s2（cast 未激活 → 走 dlna 分支）。
    h.dlna!.setCasting(<DlnaCastTrack>[
      const DlnaCastTrack(songId: 's1', title: '晴天'),
      const DlnaCastTrack(songId: 's2', title: '七里香'),
    ]);
    await settle(tester, frames: 3);

    h.fetched = <Song>[
      _song('s1', '晴天'),
      _song('s2', '七里香'),
      _song('s3', '夜曲'),
    ];
    notifyRandomSongsChanged();
    await settle(tester, frames: 8);

    expect(h.dlna!.enqueueCalls, <List<String>>[
      <String>['s3'],
    ], reason: 'DLNA 链路按 id 去重后只追加 s3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('投屏队列播完信号 → _loadNextRound 合并追加续播', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
    );
    h.fetched = <Song>[_song('s1', '晴天'), _song('s2', '七里香')];
    await h.pump(tester);

    await tester.tap(find.byIcon(AppIcons.play));
    await settle(tester, frames: 6);
    expect(h.player.playQueueCalls, hasLength(1));

    // 投屏队列自然播完：endOfQueueCount 递增 → 触发 _loadNextRound。
    h.fetched = <Song>[
      _song('s1', '晴天'),
      _song('s2', '七里香'),
      _song('s3', '夜曲'),
    ];
    final beforeBump = h.fetchCount;
    h.cast!.bumpEndOfQueue();
    await settle(tester, frames: 8);

    expect(h.fetchCount, greaterThan(beforeBump), reason: '下一轮触发远程拉取');
    expect(h.player.playQueueCalls, hasLength(2));
    expect(h.player.playQueueCalls[1], <String>['s1', 's2', 's3'],
        reason: '保留旧轮次 + 追加去重新批');
    expect(h.player.playQueueStartIndices[1], 2, reason: '从新批首接续播放');
    expect(tester.takeException(), isNull);
  });

  testWidgets('单曲点击播放 / 点更多打开歌曲选项', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
    );
    h.fetched = <Song>[_song('s1', '晴天'), _song('s2', '七里香')];
    await h.pump(tester);
    expect(find.byType(DiscoverSongTile), findsWidgets);

    // onPressed：点歌曲行本身 → playEffectiveQueue(startIndex)。
    // 先点行：避免先开歌曲选项浮层（模态 BottomSheet）遮挡后续对行的点击。
    await tester.tap(find.byType(MusicFlowSongRow).first);
    await settle(tester, frames: 6);
    expect(h.player.playQueueCalls, isNotEmpty);
    expect(tester.takeException(), isNull);

    // onOpenActions：点单元内的「更多」图标。
    final moreBtn = find.descendant(
      of: find.byType(DiscoverSongTile).first,
      matching: find.byType(MusicFlowIconButton),
    );
    await tester.tap(moreBtn.first);
    await settle(tester, frames: 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有内容 + loadFailed → 区块仍展示（非隐藏）', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天')],
          cachedAt: DateTime.now(),
        ),
      ),
    );
    await h.pump(tester);
    h.container.read(randomSongsLoadFailedProvider.notifier).state = true;
    await settle(tester);

    expect(_section, findsOneWidget, reason: '有内容时失败不隐藏');
    await tester.pump(const Duration(seconds: 4));
    await settle(tester, frames: 2);
    expect(tester.takeException(), isNull);
  });
}
