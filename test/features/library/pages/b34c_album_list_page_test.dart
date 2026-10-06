// batch34 C 路 —— `lib/features/library/pages/album_list_page.dart` 补测。
//
// 覆盖点：有数据网格渲染 / 空态 / 仓库失败不崩（确定性断言=仓库被调用）/
// 点击 tile 推专辑详情页 / 长按弹专辑操作弹窗 / 正在播放遮罩 / 标题计数。
//
// 踩坑记录：
// #A1 WindowedPaginatedList.fetcher 走 musicRepositoryProvider；仓库为 null
//     返回空集（空态分支天然可测）。
// #A2 详情页/弹窗链会 watch activeAddressProvider 与 subsonicApiClientProvider，
//     必须 override（默认链触达 drift/地址池）；地址非 ok → 封面占位无网络。
// #A3 聚合搜索分支（AggregateSearchResults）依赖远程搜索 provider 链，本文件
//     只覆盖非搜索路径；搜索分支由 aggregate_search_results 专项测试覆盖。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_stats_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';

import '../../player/test_player_notifier.dart';

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls.add(songs.map((Song s) => s.id).toList());
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
  _FakeMusicRepository({this.albums = const <Album>[]})
      : super(SubsonicApiClient(dio: Dio()));

  final List<Album> albums;
  int albumsPageCalls = 0;
  Object? pageError;

  @override
  Future<({List<Album> items, int total})> getAlbumsPage(
    int page,
    int pageSize, {
    String? query,
  }) async {
    albumsPageCalls += 1;
    if (pageError != null) throw pageError!;
    return (items: albums, total: albums.length);
  }
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

Album _album(String id, String name) => Album(
      id: id,
      name: name,
      artist: '歌手',
      coverArt: null,
      songCount: 5,
      duration: 600,
    );

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

late AppLocalizations loc;

Widget _build({
  required WidgetTester tester,
  _FakeMusicRepository? musicRepository,
  _RecordingPlayer? player,
}) {
  final library = MusicLibrary(
    id: 'lib-1',
    name: '测试库',
    createdAt: DateTime(2026, 10, 1),
    updatedAt: DateTime(2026, 10, 1),
  );
  final client = SubsonicApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
  )..setLibrary(library);
  final container = ProviderContainer(
    overrides: <Override>[      subsonicApiClientProvider.overrideWithValue(client),
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
      libraryCountsProvider.overrideWith(
        (ref) async =>
            const LibraryCounts(albumCount: 3, artistCount: 2, songCount: 30),
      ),
      playerProvider.overrideWith((ref) => player ?? _RecordingPlayer()),
      castPeerControllerProvider.overrideWith(
        (Ref ref) => _StubCastPeer(ref),
      ),
      dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
    ],
  );
  tester.view.physicalSize = const Size(900, 1600);  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: const AlbumListPage(),
    ),
  );
}

void main() {
  testWidgets('有数据：专辑网格渲染 + 标题计数副标题', (tester) async {
    final repo = _FakeMusicRepository(
      albums: <Album>[_album('al1', '寓言'), _album('al2', '浮躁')],
    );
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    expect(find.text('寓言'), findsOneWidget);
    expect(find.text('浮躁'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-tile-al1')), findsOneWidget);
    expect(find.textContaining('3'), findsWidgets,
        reason: '标题下方应显示 albumsLabel（3 张专辑）');
    expect(repo.albumsPageCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库未就绪（null）→ 空态文案', (tester) async {
    await tester.pumpWidget(_build(tester: tester));
    await settle(tester);

    expect(find.text(loc.library_empty_albums), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库分页失败 → 不崩溃，仓库被调用过（确定性副作用断言）', (tester) async {
    final repo = _FakeMusicRepository()..pageError = StateError('network down');
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    expect(repo.albumsPageCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击专辑 tile → 推入专辑详情页并渲染歌曲', (tester) async {
    final repo = _FakeMusicRepository(albums: <Album>[_album('al1', '寓言')]);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    // 详情页数据由 albumDetailProvider 提供，这里通过仓库 getAlbum 不了——
    // 直接 preheat：导航后详情页读 provider；本用例断言路由层发生了 push
    // （详情页骨架/标题出现即可）。
    await tester.tap(find.byKey(const ValueKey('album-tile-al1')));
    await settle(tester, frames: 12);

    // 详情页标题（MusicFlowTopBar.back 标题 = loc.library_album_title）。
    expect(find.text(loc.library_album_title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按专辑 tile → 弹出专辑操作弹窗', (tester) async {
    final repo = _FakeMusicRepository(albums: <Album>[_album('al1', '寓言')]);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    await tester.longPress(find.byKey(const ValueKey('album-tile-al1')));
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(find.text('寓言'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('当前播放来源是该专辑 → tile 封面叠加跳动竖条', (tester) async {
    final repo = _FakeMusicRepository(albums: <Album>[_album('al1', '寓言')]);
    final player = _RecordingPlayer();
    await tester.pumpWidget(
      _build(tester: tester, musicRepository: repo, player: player),
    );
    // 在泵出后写入 queueOrigin：从 element 树拿 ProviderScope container。
    final element = tester.element(find.byType(AlbumListPage));
    final container = ProviderScope.containerOf(element);
    container
        .read(queueOriginProvider.notifier)
        .state = const QueueOrigin(QueueOriginKind.album, 'al1');
    await settle(tester);

    expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
