// b38c3 —— Route C 补测：四个「窗口化分页列表页」的剩余缺口：
//   * album_list_page.dart：78/79（shouldRetry/onRetry）、125-129（搜索卡 onOpen 推详情）。
//   * artist_list_page.dart：76/77（shouldRetry/onRetry）、123-126（搜索卡 onOpen 推详情）。
//   * playlist_search_page.dart：74/75（shouldRetry/onRetry）、112（本地块仓库为空）、
//     121-128（搜索卡 onOpen 推详情）。
//   * song_list_page.dart：104/105（shouldRetry/onRetry）、150（本地块仓库为空）、
//     227（行长按 → showSongOptionsSheet）。
//
// 补测手段：
//   * 重试：VisibleRemoteRetryScope 只在「网络类型变化 + 页面可见 + shouldRetry」时回调。
//     用 FakeConnectivityMonitor 广播 none→wifi，配合抛错仓库让 `_list.hasError` 为真，
//     即可驱动 onRetry → `_list.retry()`（fetcher 会再次调用仓库）。
//   * onOpen：搜索卡的 `MusicFlowPressable.onPressed` 就是 `onOpen` 闭包，直接调用它
//     （与 b37c2_search_page_test 直接调 `SearchScopeTabs.onChanged` 同一手法）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/features/search/widgets/search_result_card.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/library_stats_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';

import '../../player/test_player_notifier.dart';

class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({this.currentNetworkType = NetworkType.none});

  final StreamController<NetworkType> _controller =
      StreamController<NetworkType>.broadcast();

  @override
  NetworkType currentNetworkType;

  @override
  Stream<NetworkType> get networkTypeStream => _controller.stream;

  @override
  void start() {}

  @override
  void stop() {}

  void emit(NetworkType type) {
    currentNetworkType = type;
    _controller.add(type);
  }
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

/// 可抛错 / 可返回数据的音乐仓库桩（四个列表页共用）。
class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository({
    this.albums = const <Album>[],
    this.artists = const <Artist>[],
    this.songs = const <Song>[],
    this.failPages = false,
  }) : super(SubsonicApiClient(dio: Dio()));

  final List<Album> albums;
  final List<Artist> artists;
  final List<Song> songs;
  final bool failPages;
  int pageCalls = 0;

  @override
  Future<({List<Album> items, int total})> getAlbumsPage(
    int page,
    int pageSize, {
    String query = '',
  }) async {
    pageCalls++;
    if (failPages) throw StateError('b38c3 模拟专辑分页失败');
    return (items: albums, total: albums.length);
  }

  @override
  Future<({List<Artist> items, int total})> getArtistsPage(
    int page,
    int pageSize, {
    String query = '',
  }) async {
    pageCalls++;
    if (failPages) throw StateError('b38c3 模拟艺人分页失败');
    return (items: artists, total: artists.length);
  }

  @override
  Future<({List<Song> items, int total})> getSongsPage(
    int page,
    int pageSize, {
    String query = '',
    String sort = '',
  }) async {
    pageCalls++;
    if (failPages) throw StateError('b38c3 模拟歌曲分页失败');
    return (items: songs, total: songs.length);
  }

  @override
  Future<List<Song>> getAllSongs({String query = ''}) async => songs;
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository({
    this.playlists = const <Playlist>[],
    this.failPages = false,
  }) : super(SubsonicApiClient(dio: Dio()));

  final List<Playlist> playlists;
  final bool failPages;
  int pageCalls = 0;

  @override
  Future<({List<Playlist> items, int total})> getPlaylistsPage(
    int page,
    int pageSize, {
    String query = '',
    bool favoriteOnly = false,
  }) async {
    pageCalls++;
    if (failPages) throw StateError('b38c3 模拟歌单分页失败');
    return (items: playlists, total: playlists.length);
  }
}

Album _album(String id, String name) =>
    Album(id: id, name: name, artist: '歌手-$id', songCount: 3, duration: 300);
Artist _artist(String id, String name) =>
    Artist(id: id, name: name, albumCount: 5);
Playlist _playlist(String id, String name) =>
    Playlist(id: id, name: name, songCount: 5, duration: 300);
Song _song(String id, String title) => Song(id: id, title: title);

late AppLocalizations loc;

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Harness {
  _Harness({
    required this.page,
    this.musicRepository,
    this.playlistRepository,
    this.provideMusicRepo = true,
    this.providePlaylistRepo = true,
    this.monitor,
  });

  final Widget page;
  final _FakeMusicRepository? musicRepository;
  final _FakePlaylistRepository? playlistRepository;
  final bool provideMusicRepo;
  final bool providePlaylistRepo;
  final FakeConnectivityMonitor? monitor;

  late ProviderContainer container;

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
        musicRepositoryProvider.overrideWithValue(
          provideMusicRepo ? musicRepository : null,
        ),
        playlistRepositoryProvider.overrideWithValue(
          providePlaylistRepo ? playlistRepository : null,
        ),
        libraryCountsProvider.overrideWith(
          (ref) async =>
              const LibraryCounts(albumCount: 3, artistCount: 2, songCount: 30),
        ),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
        searchResultsProvider.overrideWith(
          (Ref ref, SearchRequest req) async => SearchOutcome(),
        ),
        // 详情 provider 一律返回 null：被推入的详情页不触网、只渲染空态。
        albumDetailProvider.overrideWith((Ref ref, String id) async => null),
        artistDetailProvider.overrideWith((Ref ref, String id) async => null),
        playlistDetailProvider.overrideWith((Ref ref, String id) async => null),
        if (monitor != null)
          connectivityMonitorProvider.overrideWithValue(monitor!),
      ],
    );
    if (monitor != null) {
      container.read(currentVisibleBranchIndexProvider.notifier).state =
          libraryBranchIndex;
    }
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
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
        home: page,
      ),
    );
  }
}

/// 点搜索卡本体（onOpen）：直接调用卡片外层 MusicFlowPressable 的 onPressed
/// （与 b37c2_search_page_test 直接调 `SearchScopeTabs.onChanged` 同一手法）。
void _tapCard(WidgetTester tester, String name) {
  final pressable = find
      .ancestor(
        of: find.text(name),
        matching: find.byType(MusicFlowPressable),
      )
      .first;
  tester.widget<MusicFlowPressable>(pressable).onPressed?.call();
}

void main() {
  testWidgets('album_list：网络恢复触发 shouldRetry/onRetry 重拉（78/79）',
      (tester) async {
    final repo = _FakeMusicRepository(failPages: true);
    final monitor = FakeConnectivityMonitor();
    final h = _Harness(
        page: const AlbumListPage(),
        musicRepository: repo,
        monitor: monitor);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    expect(repo.pageCalls, greaterThanOrEqualTo(1));

    final before = repo.pageCalls;
    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    await settle(tester);
    expect(repo.pageCalls, greaterThan(before),
        reason: 'shouldRetry 为真 → onRetry → _list.retry() 再次拉取');
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist_list：网络恢复触发 shouldRetry/onRetry 重拉（76/77）',
      (tester) async {
    final repo = _FakeMusicRepository(failPages: true);
    final monitor = FakeConnectivityMonitor();
    final h = _Harness(
        page: const ArtistListPage(),
        musicRepository: repo,
        monitor: monitor);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    final before = repo.pageCalls;

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    await settle(tester);
    expect(repo.pageCalls, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist_search：网络恢复触发 shouldRetry/onRetry 重拉（74/75）',
      (tester) async {
    final repo = _FakePlaylistRepository(failPages: true);
    final monitor = FakeConnectivityMonitor();
    final h = _Harness(
        page: const PlaylistSearchPage(),
        playlistRepository: repo,
        monitor: monitor);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    final before = repo.pageCalls;

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    await settle(tester);
    expect(repo.pageCalls, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('song_list：网络恢复触发 shouldRetry/onRetry 重拉（104/105）',
      (tester) async {
    final repo = _FakeMusicRepository(failPages: true);
    final monitor = FakeConnectivityMonitor();
    final h = _Harness(
        page: const SongListPage(),
        musicRepository: repo,
        monitor: monitor);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    final before = repo.pageCalls;

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    await settle(tester);
    expect(repo.pageCalls, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('album_list：搜索卡 onOpen 推 AlbumDetailPage（125-129）',
      (tester) async {
    final repo =
        _FakeMusicRepository(albums: <Album>[_album('al1', '晨光专辑')]);
    final h = _Harness(page: const AlbumListPage(), musicRepository: repo);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '晨光');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byType(SearchAlbumCard), findsWidgets);

    _tapCard(tester, '晨光专辑');
    await settle(tester, frames: 14);
    expect(find.byType(AlbumDetailPage), findsOneWidget,
        reason: '点搜索卡本体应跳专辑详情');
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist_list：搜索卡 onOpen 推 ArtistDetailPage（123-126）',
      (tester) async {
    final repo =
        _FakeMusicRepository(artists: <Artist>[_artist('ar1', '晨光歌手')]);
    final h = _Harness(page: const ArtistListPage(), musicRepository: repo);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '晨光');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byType(SearchArtistCard), findsWidgets);

    _tapCard(tester, '晨光歌手');
    await settle(tester, frames: 14);
    expect(find.byType(ArtistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist_search：搜索卡 onOpen 推 PlaylistDetailPage（121-128）',
      (tester) async {
    final repo = _FakePlaylistRepository(
        playlists: <Playlist>[_playlist('pl1', '晨光歌单')]);
    final h = _Harness(
        page: const PlaylistSearchPage(), playlistRepository: repo);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '晨光');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byType(SearchPlaylistCard), findsWidgets);

    _tapCard(tester, '晨光歌单');
    await settle(tester, frames: 14);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist_search：搜索且仓库未就绪 → 本地块空结果（112）',
      (tester) async {
    final h = _Harness(
      page: const PlaylistSearchPage(),
      providePlaylistRepo: false,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '无库');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.text(loc.library_local_no_match_playlists), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('song_list：搜索且仓库未就绪 → 本地块空结果（150）',
      (tester) async {
    final h = _Harness(
      page: const SongListPage(),
      provideMusicRepo: false,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '无库');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.text(loc.library_local_no_match_songs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('song_list：行长按 → showSongOptionsSheet（227）', (tester) async {
    final repo = _FakeMusicRepository(songs: <Song>[_song('s1', '晨光曲')]);
    final h = _Harness(page: const SongListPage(), musicRepository: repo);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('晨光曲'), findsWidgets);
    await tester.longPress(find.text('晨光曲').first);
    await settle(tester, frames: 14);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget,
        reason: '长按歌曲行应弹出歌曲操作面板');
    expect(tester.takeException(), isNull);
  });
}
