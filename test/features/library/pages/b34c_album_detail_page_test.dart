// batch34 C 路 —— `lib/features/library/pages/album_detail_page.dart` 补测。
//
// 覆盖点：加载态 / 失败错误态+重试 / 详情为空（未找到） / 有数据完整渲染 /
// 播放全部（整队起播 + 来源标记）/ 点歌曲行按索引起播 / 收藏切换成功与失败 /
// 排序按钮未就绪禁用 / 排序弹窗打开 / loadFailed 缓存提示条 / 正在播放遮罩。
//
// 踩坑记录：
// #D1 albumDetailProvider 是 autoDispose.family，override 回调签名是
//     (ref, String albumId)，漏掉第二参编译不过。
// #D2 成功/失败 toast 走 ToastNotifier → rootNavigatorKey（core/utils），
//     MaterialApp 必须挂该 navigatorKey。
// #D3 详情头 MediaDetailArtwork 内部是 CoverArtImage ⇒ activeAddress/
//     subsonicApiClientProvider 必须 override。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';

import '../../player/test_player_notifier.dart';

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<int> playQueueStartIndices = <int>[];

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
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));

  Object? setStarredError;
  final List<(String, bool)> starredCalls = <(String, bool)>[];

  @override
  Future<void> setAlbumStarred(String albumId, bool starred) async {
    starredCalls.add((albumId, starred));
    if (setStarredError != null) throw setStarredError!;
  }
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

const String kAlbumId = 'al-1';

Album _album({bool starred = false}) => Album(
      id: kAlbumId,
      name: '寓言',
      artist: '王菲',
      coverArt: null,
      songCount: 2,
      duration: 500,
      year: 2000,
      genre: '流行',
      starred: starred,
    );

List<Song> _songs() => <Song>[
      Song(id: 's1', title: '寒武纪', artist: '王菲', duration: 260),
      Song(id: 's2', title: '新房客', artist: '王菲', duration: 210),
    ];

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

late AppLocalizations loc;

class _Harness {
  _Harness({
    this.detail,
    this.detailError,
    this.detailNeverCompletes = false,
  }) : musicRepository = _FakeMusicRepository(),
       player = _RecordingPlayer();

  final AlbumDetail? detail;
  final Object? detailError;
  final bool detailNeverCompletes;
  final _FakeMusicRepository musicRepository;
  final _RecordingPlayer player;

  int fetchRuns = 0;
  late final ProviderContainer container;

  Widget build(WidgetTester tester) {
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
        activeLibraryProvider.overrideWithValue(library),
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
        musicRepositoryProvider.overrideWithValue(musicRepository),
        playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
        playerProvider.overrideWith((ref) => player),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
        albumDetailProvider.overrideWith((ref, String albumId) async {
          fetchRuns += 1;
          if (detailNeverCompletes) {
            // 永不完成（无 Timer，用例结束无 pending timer 风险）。
            return Completer<AlbumDetail?>().future;
          }
          if (detailError != null) throw detailError!;
          return detail;
        }),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: const AlbumDetailPage(albumId: kAlbumId),
      ),
    );
  }
}

void main() {
  testWidgets('加载态渲染 MediaDetailLoadingView', (tester) async {
    final h = _Harness(detailNeverCompletes: true);
    await tester.pumpWidget(h.build(tester));
    await settle(tester, frames: 4);

    expect(find.byType(MediaDetailLoadingView), findsOneWidget);
    expect(h.fetchRuns, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情加载异常 → 错误态 + 点重试重新拉取', (tester) async {
    final h = _Harness(detailError: StateError('boom'));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text(loc.library_album_load_failed), findsOneWidget);
    final retry = find.text(loc.widgets_retry);
    expect(retry, findsOneWidget);
    expect(h.fetchRuns, 1);

    await tester.tap(retry);
    await settle(tester, frames: 4);
    expect(h.fetchRuns, 2, reason: '重试应 invalidate provider 重新拉取');
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情为 null → 未找到空态，且排序/更多按钮禁用', (tester) async {
    final h = _Harness(detail: null);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text(loc.library_album_not_found), findsOneWidget);
    // 排序按钮（icon sort）currentAlbum == null → onPressed null。
    final sortButton = tester.widget<MusicFlowIconButton>(
      find.byWidgetPredicate(
        (w) => w is MusicFlowIconButton && w.icon == AppIcons.sort,
      ),
    );
    expect(sortButton.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有数据：渲染专辑名/歌手/元信息与歌曲列表', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('寓言'), findsOneWidget);
    expect(find.text('王菲'), findsOneWidget);
    expect(find.text('2000'), findsOneWidget);
    expect(find.text('流行'), findsOneWidget);
    expect(find.text('寒武纪'), findsOneWidget);
    expect(find.text('新房客'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放全部 → 整队起播 + 来源标记为 album', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.tap(find.text(loc.library_play_all));
    await settle(tester, frames: 6);

    expect(h.player.playQueueCalls, <List<String>>[
      <String>['s1', 's2'],
    ]);
    expect(h.player.playQueueStartIndices, <int>[0]);
    expect(
      h.container.read(queueOriginProvider)!.kind.name,
      'album',
    );
    expect(h.container.read(queueOriginProvider)!.id, kAlbumId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点第 2 首歌行 → 按索引起播', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.tap(find.text('新房客'));
    await settle(tester, frames: 6);

    expect(h.player.playQueueStartIndices, <int>[1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收藏切换成功 → 仓库收到取反值 + 成功 toast', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.tap(find.bySemanticsLabel(loc.library_favorite_album));
    await settle(tester, frames: 8);

    expect(h.musicRepository.starredCalls, <(String, bool)>[
      (kAlbumId, true),
    ]);
    expect(
      find.text(loc.library_favorited_album),
      findsOneWidget,
      reason: '成功 toast 文案',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('收藏切换失败 → 仓库被调用且不崩溃', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    h.musicRepository.setStarredError = StateError('offline');
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.tap(find.bySemanticsLabel(loc.library_favorite_album));
    await settle(tester, frames: 8);

    expect(h.musicRepository.starredCalls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('loadFailed=true（缓存回退）→ 数据仍在 + 缓存提示条', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    h.container
        .read(albumDetailLoadFailedProvider(kAlbumId).notifier)
        .state = true;
    await settle(tester);

    expect(find.text('寒武纪'), findsOneWidget, reason: '缓存内容仍展示');
    expect(find.text(loc.library_network_cached_content), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('当前播放来源是该专辑 → 封面叠加跳动竖条', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    h.container.read(queueOriginProvider.notifier).state =
        QueueOrigin(QueueOriginKind.album, kAlbumId);
    await settle(tester);

    expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排序弹窗可打开（有数据时排序按钮可用）', (tester) async {
    final h = _Harness(detail: AlbumDetail(album: _album(), songs: _songs()));
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is MusicFlowIconButton && w.icon == AppIcons.sort,
      ),
    );
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
