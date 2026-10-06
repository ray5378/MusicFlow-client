// batch37 C(2) —— `lib/features/library/pages/artist_detail_page.dart` 剩余分支。
//
// 既有 b32a 已覆盖骨架/空态/错误态/头部/热门歌曲/起播/收藏/来源面板等。
// 本文件补 lcov 仍标 0 的：
//   * VisibleRemoteRetryScope 的 shouldRetry / onRetry（57-62）；
//   * 头部「播放歌曲」按钮起播（123）；
//   * 热门歌曲局部错误条的重试回调（233-234）；
//   * 热门歌曲行长按弹出菜单（298）；
//   * 窄屏专辑列表行点击进专辑详情（350）；
//   * 宽屏专辑网格卡长按弹出菜单（384-386）。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';

import '../../../helpers/mocks.dart';
import '../../player/test_player_notifier.dart';

/// 可编程网络监视器（触发可见重试作用域）。
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

  Future<void> dispose() => _controller.close();
}

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  final List<int> playQueueLengths = <int>[];
  final List<int> playQueueStartIndexes = <int>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    if (songs.isEmpty) return;
    final safeIndex = startIndex.clamp(0, songs.length - 1);
    playQueueLengths.add(songs.length);
    playQueueStartIndexes.add(safeIndex);
    state = state.copyWith(
      queue: songs,
      currentIndex: safeIndex,
      currentSong: songs[safeIndex],
    );
  }
}


class _CastPeer extends CastPeerController {
  _CastPeer(super.ref);
}

class _Dlna extends DlnaCastNotifier {
  _Dlna(super.ref);
}

Song _song(String id, String title, {int duration = 180}) => Song(
      id: id,
      title: title,
      artist: '夜航西飞',
      album: '专辑一',
      albumId: 'al-1',
      track: 1,
      duration: duration,
    );

final List<Song> _detailSongs = <Song>[
  _song('s-1', '归途'),
  _song('s-2', '灯塔'),
  _song('s-3', '起航'),
];

final List<Album> _detailAlbums = <Album>[
  Album(
    id: 'al-1',
    name: '专辑一',
    artist: '夜航西飞',
    songCount: 3,
    duration: 900,
    year: 2026,
  ),
  Album(
    id: 'al-2',
    name: '专辑二',
    artist: '夜航西飞',
    songCount: 2,
    duration: 600,
    year: 2025,
  ),
];

ArtistDetail _detail({List<Album>? albums, List<Song>? songs}) => ArtistDetail(
      artist: Artist(
        id: 'ar-1',
        name: '夜航西飞',
        coverArt: null,
        albumCount: 2,
        starred: false,
      ),
      albums: albums ?? _detailAlbums,
      songs: songs ?? _detailSongs,
    );

List<Song> _topSongs({int count = 7}) => List<Song>.generate(
      count,
      (i) => _song('t-${i + 1}', '热歌${i + 1}', duration: 200 + i),
    );

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(MusicFlowPressable),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;
  late FakeConnectivityMonitor monitor;

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    api = MockSubsonicApiClient();
    when(
      () => api.getCoverArtUrl(any(), size: any(named: 'size')),
    ).thenReturn('https://example.test/cover?id=x');
    monitor = FakeConnectivityMonitor();
  });

  Future<(_RecPlayer, ProviderContainer)> pumpPage(
    WidgetTester tester, {
    required FutureOr<ArtistDetail?> Function() detail,
    FutureOr<List<Song>> Function()? topSongs,
    bool loadFailed = false,
    _RecPlayer? playerOverride,
    MusicRepository? repo,
    Size size = const Size(900, 1400),
    bool visibleLibraryBranch = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final activePlayer = playerOverride ?? _RecPlayer(PlayerState());
    final container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(monitor),
        subsonicApiClientProvider.overrideWithValue(api),
        playerProvider.overrideWith((ref) => activePlayer),
        castPeerControllerProvider.overrideWith((Ref ref) => _CastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _Dlna(ref)),
        musicRepositoryProvider.overrideWithValue(repo),
        ensureActiveAddressProvider.overrideWith(
          (ref) async => const ServerAddress(
            id: 'addr-1',
            libraryId: 'lib-1',
            label: '主线路',
            url: 'https://example.test',
            priority: 0,
          ),
        ),
        artistDetailProvider.overrideWith(
          (ref, String artistId) async => detail(),
        ),
        artistDetailLoadFailedProvider.overrideWith(
          (ref, String artistId) => loadFailed,
        ),
        topSongsByArtistProvider.overrideWith(
          (ref, String artistName) async {
            if (topSongs == null) return const <Song>[];
            return topSongs();
          },
        ),
        playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
        albumDetailProvider.overrideWith(
          (ref, String albumId) async => AlbumDetail(
            album: _detailAlbums.first,
            songs: const <Song>[],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    if (visibleLibraryBranch) {
      container.read(currentVisibleBranchIndexProvider.notifier).state =
          libraryBranchIndex;
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.light(),
          home: const Scaffold(body: ArtistDetailPage(artistId: 'ar-1')),
        ),
      ),
    );
    return (activePlayer, container);
  }

  testWidgets('艺术家详情:头部「播放歌曲」按钮从全部歌曲起播', (tester) async {
    final (recPlayer, _) = await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(find.text(loc.library_play_songs));
    await _settle(tester);

    expect(recPlayer.playQueueLengths, <int>[3]);
    expect(recPlayer.playQueueStartIndexes, <int>[0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:热门歌曲错误条点重试 → 重新拉取热门', (tester) async {
    var fail = true;
    await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () async {
        if (fail) throw StateError('top songs down');
        return _topSongs();
      },
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.byType(MediaLoadNotice), findsOneWidget);

    fail = false;
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester);

    expect(find.text(loc.library_top_songs), findsOneWidget);
    expect(find.text('热歌1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:长按热门歌曲行弹出歌曲操作面板', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
    );
    await _settle(tester);

    await tester.longPress(_row('热歌3'));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:窄屏专辑列表行点击进入专辑详情', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      size: const Size(480, 900),
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(find.byWidgetPredicate(
      (w) => w is MusicFlowPressable && w.semanticLabel == loc.library_albums,
    ));
    await _settle(tester);

    // 窄屏走列表行（非网格卡）。
    expect(find.byType(MediaDetailAlbumTile), findsNothing);
    await tester.tap(_row('专辑一'));
    await _settle(tester);

    expect(find.byType(AlbumDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:宽屏专辑网格卡长按弹出专辑操作面板', (tester) async {
    await pumpPage(tester, detail: () => _detail());
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(find.byWidgetPredicate(
      (w) => w is MusicFlowPressable && w.semanticLabel == loc.library_albums,
    ));
    await _settle(tester);

    expect(find.byType(MediaDetailAlbumTile), findsNWidgets(2));
    await tester.longPress(find.byType(MediaDetailAlbumTile).first);
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:网络恢复触发可见重试作用域（缓存提示态）', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      loadFailed: true,
      visibleLibraryBranch: true,
    );
    await _settle(tester);
    expect(find.text('夜航西飞'), findsOneWidget);

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    await _settle(tester);

    expect(tester.takeException(), isNull);
  });
}
