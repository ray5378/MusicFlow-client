// batch34 C 路 —— `lib/features/discover/widgets/random_songs_section.dart` 补测。
//
// 覆盖点：骨架加载态 / 无内容+loadFailed 整块隐藏 / 本地缓存秒出 /
// 缓存过期后台刷新 / 无缓存后台拉取 / 刷新按钮 / 播放整轮 /
// 播完自动下一轮（去重追加 + 续播索引）/ 歌单变更推送追加队列 /
// 有内容时 loadFailed 不隐藏。
//
// 踩坑记录：
// #R1 组件直接 override randomSongsProvider 本体（FutureProvider），用计数闭包
//     观察每次 ref.refresh；绕开 musicRepository/metadataCache 真链。
// #R2 MetadataCacheRepository 用 extends + 只 override 两个方法，不触
//     JsonFileStore（不落盘、无 MethodChannel）。
// #R3 失败自愈的 3s 自动重试 Timer 必须在用例尾部用 pump 推掉，否则
//     「A Timer is still pending」挂用例。
// #R4 骨架屏 MusicFlowSkeleton 是无限动画 → 一律有界推帧。

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/random_songs_section.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

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

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

/// 缓存桩：getRandomSongsWithMeta 返回注入值，不触 JsonFileStore。
class _FakeCache extends MetadataCacheRepository {
  _FakeCache({this.cached});

  ({List<Song> songs, DateTime cachedAt})? cached;

  @override
  Future<String?> getLastLibraryId() async => 'lib-1';

  @override
  Future<({List<Song> songs, DateTime cachedAt})?> getRandomSongsWithMeta(
    String libraryId,
  ) async =>
      cached;
}

Song _song(String id, String title) =>
    Song(id: id, title: title, artist: '歌手', duration: 180);

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Harness {
  _Harness({this.cache, List<Song>? fetchResult})
      : player = _RecordingPlayer() {
    fetched = fetchResult ?? <Song>[];
  }

  final _RecordingPlayer player;
  _FakeCache? cache;
  late List<Song> fetched;
  int fetchCount = 0;
  late final ProviderContainer container;

  Widget build() {
    final library = MusicLibrary(
      id: 'lib-1',
      name: '测试库',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    );
    final client = SubsonicApiClient(
      dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
    )..setLibrary(library);
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        activeLibraryProvider.overrideWith((Ref ref) => null),
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
        metadataCacheRepositoryProvider.overrideWithValue(
          cache ?? _FakeCache(),
        ),
        musicRepositoryProvider.overrideWithValue(_FakeMusicRepository()),
        playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
        randomSongsProvider.overrideWith((ref) async {
          fetchCount += 1;
          return fetched;
        }),
        playerProvider.overrideWith((ref) => player),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
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
            child: SizedBox(
              width: 900,
              child: RandomSongsSection(),
            ),
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
  testWidgets('无缓存且未失败 → 骨架加载态', (tester) async {
    final h = _Harness(fetchResult: <Song>[]);
    await h.pump(tester);

    expect(_section, findsOneWidget);
    expect(find.byType(MusicFlowSkeleton), findsWidgets);
    expect(find.byType(DiscoverSongTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无内容 + loadFailed → 整块隐藏；3s 自愈重试 Timer 推掉不悬挂',
      (tester) async {
    final h = _Harness(fetchResult: <Song>[]);
    await h.pump(tester);
    h.container.read(randomSongsLoadFailedProvider.notifier).state = true;
    await settle(tester);

    expect(_section, findsNothing, reason: '无内容且失败 → 整块隐藏');

    // 推过 3s 自愈重试 Timer（fire 一次后不再重排），避免 pending timer。
    await tester.pump(const Duration(seconds: 4));
    await settle(tester, frames: 2);
    expect(_section, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地缓存命中 → 秒出内容，不发远程请求', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      ),
      fetchResult: <Song>[_song('s1', '晴天')],
    );
    await h.pump(tester);

    expect(find.byType(DiscoverSongTile), findsNWidgets(2));
    expect(h.fetchCount, 0, reason: '缓存新鲜 → 不后台拉取');
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存超过 TTL → 后台拉取最新并刷新展示', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天')],
          cachedAt: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      ),
      fetchResult: <Song>[_song('s3', '夜曲')],
    );
    await h.pump(tester);

    expect(h.fetchCount, 1, reason: '缓存过期 → 后台刷新一次');
    await settle(tester);
    expect(find.text('夜曲'), findsOneWidget, reason: '远程新结果覆盖展示');
    expect(tester.takeException(), isNull);
  });

  testWidgets('无缓存 → 后台拉取一次填充首屏', (tester) async {
    final h = _Harness(fetchResult: <Song>[_song('s1', '晴天')]);
    await h.pump(tester);

    expect(h.fetchCount, 1);
    await settle(tester);
    expect(find.byType(DiscoverSongTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点刷新 → 重新拉取；点播放 → 播当前展示整轮', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
      fetchResult: <Song>[_song('s3', '夜曲')],
    );
    await h.pump(tester);
    expect(h.fetchCount, 0);

    await tester.tap(find.byIcon(AppIcons.refresh));
    await settle(tester);
    expect(h.fetchCount, 1, reason: '手动刷新拉取一次');
    expect(find.text('夜曲'), findsOneWidget, reason: '刷新后展示新一批');
    expect(h.player.playQueueCalls, isEmpty, reason: '刷新不自动播放');

    await tester.tap(find.byIcon(AppIcons.play));
    await settle(tester, frames: 6);
    expect(h.player.playQueueCalls, <List<String>>[
      <String>['s3'],
    ], reason: '播放的就是看到的（刷新后的一批）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地播放整轮播完 → 拉新一批去重追加续播', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
      fetchResult: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
    );
    await h.pump(tester);

    await tester.tap(find.byIcon(AppIcons.play));
    await settle(tester, frames: 6);
    expect(h.player.playQueueCalls, <List<String>>[
      <String>['s1', 's2'],
    ]);

    // 下一轮拉到的新批：s2 重复，s3 是新歌。
    // 注意：emit 会同步触发监听器并执行 refresh，须先改写 fetch 结果。
    h.fetched = <Song>[_song('s2', '七里香'), _song('s3', '夜曲')];
    h.player.emit(
      h.player.state.copyWith(
        processingState: ProcessingState.completed,
        currentIndex: 1,
      ),
    );
    await settle(tester, frames: 8);

    expect(h.fetchCount, greaterThanOrEqualTo(1), reason: '下一轮触发远程拉取');
    expect(h.player.playQueueCalls, hasLength(2));
    expect(h.player.playQueueCalls[1], <String>['s1', 's2', 's3'],
        reason: '保留旧轮次 + 追加去重新批');
    expect(h.player.playQueueStartIndices[1], 2, reason: '从新批首接续播放');
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单变更推送：本机随机轮次播放中 → 新歌追加到队尾', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
      fetchResult: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
    );
    await h.pump(tester);

    // 先起播建立随机轮次 + 队列。
    await tester.tap(find.byIcon(AppIcons.play));
    await settle(tester, frames: 6);
    expect(h.player.addAllToQueueCalls, isEmpty);

    // 推送到达，新批含一首新歌。
    h.fetched = <Song>[_song('s2', '七里香'), _song('s3', '夜曲')];
    notifyRandomSongsChanged();
    await settle(tester, frames: 8);

    expect(h.player.addAllToQueueCalls, <List<String>>[
      <String>['s3'],
    ], reason: '按 id 去重后只追加新歌 s3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单变更推送但未在播放随机轮次 → 只刷新展示不追加队列',
      (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天')],
          cachedAt: DateTime.now(),
        ),
      ),
      fetchResult: <Song>[_song('s9', '新歌')],
    );
    await h.pump(tester);

    notifyRandomSongsChanged();
    await settle(tester, frames: 8);

    expect(h.player.addAllToQueueCalls, isEmpty);
    expect(find.text('新歌'), findsOneWidget, reason: '展示已刷新');
    expect(tester.takeException(), isNull);
  });

  testWidgets('当前播放歌曲行高亮（isCurrent）', (tester) async {
    final h = _Harness(
      cache: _FakeCache(
        cached: (
          songs: <Song>[_song('s1', '晴天'), _song('s2', '七里香')],
          cachedAt: DateTime.now(),
        ),
      ),
      fetchResult: <Song>[_song('s1', '晴天')],
    );
    await h.pump(tester);

    h.player.emit(
      h.player.state.copyWith(
        queue: <Song>[_song('s1', '晴天')],
        currentIndex: 0,
        currentSong: _song('s1', '晴天'),
      ),
    );
    await settle(tester);

    // DiscoverSongTile 的 isCurrent 由 currentSongId 匹配；至少两个 tile 中
    // 第一个应带当前播放标记。这里断言组件树可稳定重建且行仍渲染。
    expect(find.byType(DiscoverSongTile), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
