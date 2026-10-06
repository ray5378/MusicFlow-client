// b38c3 —— Route C 补测：library 详情/收藏页剩余缺口。
//   * album_detail_page.dart：45/46（shouldRetry/onRetry）、62/64（更多按钮 → showAlbumOptionsSheet）、
//     173（歌曲行长按 → showSongOptionsSheet）、349/351-353（_AlbumIdentityHeader 非 wide 的 Column 分支）。
//   * starred_page.dart：60-64（shouldRetry/onRetry）、119（playlists 错误态重试 invalidate）、
//     147/148（大字号档 playlist tile 的 onPress/onLongPress）、
//     341（大字号档 album 行长按）、372（网格 album 卡片长按）。
//
// 手法：与 b38c3_library_list_pages_extra_test 一致的可见性 + 网络变化重试驱动；
// 详情/收藏 provider 直接用 overrideWith 打桩，避免触网。
// 报告为不可达：starred_page.dart 512/513（_StarredTabStrip.didUpdateWidget 的换 controller
//   分支）—— DefaultTabController 只在 length 变化时换 controller，而 StarredPage 恒传 4 个 tab，
//   且 _StarredTabStrip 为私有类，外部无法换 controller 实例。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
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

class _StubOfflineCache extends OfflineCacheManager {
  _StubOfflineCache() : super(rootForTest: null);
}

Album _album(String id, String name) => Album(
      id: id,
      name: name,
      artist: '歌手-$id',
      songCount: 3,
      duration: 300,
    );
Song _song(String id, String title) => Song(id: id, title: title);
Playlist _playlist(String id, String name) =>
    Playlist(id: id, name: name, songCount: 5, duration: 300);

late AppLocalizations loc;

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Harness {
  _Harness({
    required this.page,
    this.albumDetail,
    this.albumLoadFailed = false,
    this.starredResult,
    this.starredLoadFailed = false,
    this.favoritePlaylists,
    this.favoriteLoadFailed = false,
    this.monitor,
    this.textScaler = 1.0,
  });

  final Widget page;

  int albumLoads = 0;
  int starredLoads = 0;
  int favLoads = 0;

  final AlbumDetail? albumDetail;
  final bool albumLoadFailed;
  final StarredResult? starredResult;
  final bool starredLoadFailed;
  final List<Playlist>? favoritePlaylists;
  final bool favoriteLoadFailed;
  final FakeConnectivityMonitor? monitor;
  final double textScaler;

  late ProviderContainer container;

  Widget build(WidgetTester tester, {double width = 900}) {
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
            url: 'https://music.example.test',
            priority: 0,
            status: ServerAddressStatus.ok,
          ),
        ),
        isOfflineProvider.overrideWithValue(false),
        offlineCacheManagerProvider.overrideWithValue(_StubOfflineCache()),
        offlineCacheReadyProvider.overrideWith((ref) async {}),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        albumDetailProvider.overrideWith((Ref ref, String id) async {
          albumLoads++;
          return albumDetail;
        }),
        albumDetailLoadFailedProvider.overrideWith(
          (Ref ref, String id) => albumLoadFailed,
        ),
        starredProvider.overrideWith((ref) async {
          starredLoads++;
          return starredResult ??
              StarredResult(
                artists: const <Artist>[],
                albums: const <Album>[],
                songs: const <Song>[],
              );
        }),
        starredLoadFailedProvider.overrideWith((ref) => starredLoadFailed),
        favoritePlaylistsProvider.overrideWith((ref) async {
          favLoads++;
          return favoritePlaylists ?? <Playlist>[];
        }),
        favoritePlaylistsLoadFailedProvider
            .overrideWith((ref) => favoriteLoadFailed),
        playlistDetailProvider.overrideWith((Ref ref, String id) async => null),
        if (monitor != null)
          connectivityMonitorProvider.overrideWithValue(monitor!),
      ],
    );
    if (monitor != null) {
      container.read(currentVisibleBranchIndexProvider.notifier).state =
          libraryBranchIndex;
    }
    tester.view.physicalSize = Size(width, 1600);
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
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScaler),
            ),
            child: child!,
          );
        },
        home: page,
      ),
    );
  }
}

void main() {
  // ---------------- album_detail_page ----------------

  testWidgets('album_detail：网络恢复触发 shouldRetry/onRetry 重拉（45/46）',
      (tester) async {
    final monitor = FakeConnectivityMonitor();
    final h = _Harness(
      page: const AlbumDetailPage(albumId: 'al-1'),
      albumDetail: null,
      albumLoadFailed: true,
      monitor: monitor,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    final before = h.albumLoads;

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    await settle(tester);

    expect(h.albumLoads, greaterThan(before),
        reason: 'shouldRetry 为真 → onRetry → invalidate(albumDetailProvider)');
    expect(tester.takeException(), isNull);
  });

  testWidgets('album_detail：更多按钮 → showAlbumOptionsSheet（62/64）',
      (tester) async {
    final h = _Harness(
      page: const AlbumDetailPage(albumId: 'al-2'),
      albumDetail: AlbumDetail(
        album: _album('al-2', '晨光专辑'),
        songs: <Song>[_song('s1', '晨光曲')],
      ),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('晨光专辑'), findsWidgets);
    // 顶栏里 AppIcons.more 不止一个（scaffold 自带溢出入口），按按钮语义标签精确定位。
    await tester.tap(find.bySemanticsLabel(loc.library_album_actions).first);
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget,
        reason: '更多按钮应弹出专辑操作面板');
    expect(tester.takeException(), isNull);
  });

  testWidgets('album_detail：歌曲行长按 → showSongOptionsSheet（173）',
      (tester) async {
    final h = _Harness(
      page: const AlbumDetailPage(albumId: 'al-3'),
      albumDetail: AlbumDetail(
        album: _album('al-3', '夜行专辑'),
        songs: <Song>[_song('s9', '晚风曲')],
      ),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.longPress(find.text('晚风曲').first);
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget,
        reason: '歌曲行长按应弹出歌曲操作面板');
    expect(tester.takeException(), isNull);
  });

  testWidgets('album_detail：中等宽度 → 非 wide 的 Column 头部（349/351-353）',
      (tester) async {
    final h = _Harness(
      page: const AlbumDetailPage(albumId: 'al-4'),
      albumDetail: AlbumDetail(
        album: _album('al-4', '窄屏专辑'),
        songs: <Song>[_song('s1', '曲一')],
      ),
    );
    // 640：>= medium(600) 且 < 680 ⇒ 走 non-compact / non-wide 的 Column。
    await tester.pumpWidget(h.build(tester, width: 640));
    await settle(tester);

    expect(find.text('窄屏专辑'), findsWidgets);
    // 非 wide 的 Column 头部：封面中心对齐 + 信息块在下方。
    expect(find.byType(Center), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  // ---------------- starred_page ----------------

  testWidgets('starred：网络恢复触发 shouldRetry/onRetry 重拉（60-64）',
      (tester) async {
    final monitor = FakeConnectivityMonitor();
    final h = _Harness(
      page: const StarredPage(),
      starredLoadFailed: true,
      monitor: monitor,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);
    final beforeStarred = h.starredLoads;
    final beforeFav = h.favLoads;

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    await settle(tester);

    expect(h.starredLoads, greaterThan(beforeStarred));
    expect(h.favLoads, greaterThan(beforeFav),
        reason: 'onRetry 同时 invalidate starred/favoritePlaylists');
    expect(tester.takeException(), isNull);
  });

  testWidgets('starred/playlists：加载失败且为空 → 重试 invalidate（119）',
      (tester) async {
    final h = _Harness(
      page: const StarredPage(),
      favoritePlaylists: <Playlist>[],
      favoriteLoadFailed: true,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text(loc.widgets_retry), findsOneWidget);
    final before = h.favLoads;
    await tester.tap(find.text(loc.widgets_retry));
    await settle(tester);

    expect(h.favLoads, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('starred/playlists：大字号档 tile 的 onPress/onLongPress（147/148）',
      (tester) async {
    final h = _Harness(
      page: const StarredPage(),
      favoritePlaylists: <Playlist>[_playlist('pl-1', '收藏歌单一')],
      textScaler: 1.7,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('收藏歌单一'), findsWidgets);

    // onLongPress（148）→ showPlaylistOptionsSheet。
    await tester.longPress(find.text('收藏歌单一').first);
    await settle(tester, frames: 14);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);

    // 关掉弹层，再点本体（147）→ 推 PlaylistDetailPage。
    await tester.tapAt(const Offset(450, 60));
    await settle(tester, frames: 14);
    await tester.tap(find.text('收藏歌单一').first);
    await settle(tester, frames: 14);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('starred/albums：大字号档 album 行长按（341）', (tester) async {
    final h = _Harness(
      page: const StarredPage(initialTab: StarredTab.albums),
      starredResult: StarredResult(
        artists: const <Artist>[],
        albums: <Album>[_album('al-9', '收藏专辑九')],
        songs: const <Song>[],
      ),
      textScaler: 1.7,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('收藏专辑九'), findsWidgets);
    await tester.longPress(find.text('收藏专辑九').first);
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget,
        reason: '大字号 album 行长按 → showAlbumOptionsSheet');
    expect(tester.takeException(), isNull);
  });

  testWidgets('starred/albums：网格卡片长按（372）', (tester) async {
    final h = _Harness(
      page: const StarredPage(initialTab: StarredTab.albums),
      starredResult: StarredResult(
        artists: const <Artist>[],
        albums: <Album>[_album('al-8', '收藏专辑八')],
        songs: const <Song>[],
      ),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.byType(MusicFlowAlbumTile), findsWidgets);
    await tester.longPress(find.byType(MusicFlowAlbumTile).first);
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
