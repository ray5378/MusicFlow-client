// b39c2 —— Route C 清尾：VisibleRemoteRetryScope 的 shouldRetry 闭包体。
//   * starred_page.dart:61 —— `loadFailed || playlistsLoadFailed ||
//     starredAsync.hasError`（网络恢复触发可见重试时执行）；
//   * artist_detail_page.dart:58 —— `loadFailed || detailAsync.hasError ||
//     topSongsLoadFailed`（同上）。
//
// 手法：FakeConnectivityMonitor 自持 StreamController，loadFailed 桩为 true，
// 库分支索引对齐后 emit 网络变化 → _retryIfNeeded → shouldRetry(ref) 执行。
// 手法沿用 b37c2（artist_detail）与 b35c_visible_remote_retry_scope_test。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
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

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

StarredResult _filled() => StarredResult(
      artists: <Artist>[Artist(id: 'artist-1', name: '收藏歌手', albumCount: 3)],
      albums: <Album>[
        Album(
          id: 'album-1',
          name: '收藏专辑',
          artist: '收藏歌手',
          songCount: 1,
          duration: 200,
        ),
      ],
      songs: <Song>[
        Song(id: 'song-1', title: '收藏歌曲', artist: '收藏歌手', duration: 200),
      ],
    );

Playlist _playlist() => Playlist(
      id: 'playlist-1',
      name: '收藏歌单',
      songCount: 8,
      duration: 1600,
      favorite: true,
    );

ArtistDetail _detail() => ArtistDetail(
      artist: Artist(
        id: 'ar-1',
        name: '夜航西飞',
        coverArt: null,
        albumCount: 2,
        starred: false,
      ),
      albums: const <Album>[],
      songs: const <Song>[],
    );

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  testWidgets('StarredPage：网络恢复触发可见重试 → shouldRetry 闭包体（61）',
      (tester) async {
    final monitor = FakeConnectivityMonitor();
    final container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(monitor),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        starredProvider.overrideWith((ref) async => _filled()),
        favoritePlaylistsProvider
            .overrideWith((ref) async => <Playlist>[_playlist()]),
        starredLoadFailedProvider.overrideWith((ref) => true),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentVisibleBranchIndexProvider.notifier).state =
        libraryBranchIndex;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.light(),
          home: const StarredPage(),
        ),
      ),
    );
    await settle(tester);
    expect(find.text('收藏歌单'), findsOneWidget);

    // none → wifi：_retryIfNeeded → widget.shouldRetry(ref)（61 行闭包体执行）。
    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    await settle(tester);

    expect(find.text('收藏歌单'), findsOneWidget,
        reason: '重试后页面正常重建');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ArtistDetailPage：网络恢复触发可见重试 → shouldRetry 闭包体（58）',
      (tester) async {
    final monitor = FakeConnectivityMonitor();
    final api = MockSubsonicApiClient();
    when(
      () => api.getCoverArtUrl(any(), size: any(named: 'size')),
    ).thenReturn('https://example.test/cover?id=x');

    final container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(monitor),
        subsonicApiClientProvider.overrideWithValue(api),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
        ensureActiveAddressProvider.overrideWith(
          (ref) async => const ServerAddress(
            id: 'addr-1',
            libraryId: 'lib-1',
            label: '主线路',
            url: 'https://example.test',
            priority: 0,
          ),
        ),
        artistDetailProvider.overrideWith((ref, String artistId) => _detail()),
        artistDetailLoadFailedProvider.overrideWith((ref, String artistId) => true),
        topSongsByArtistProvider
            .overrideWith((ref, String artistName) async => const <Song>[]),
        playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
        albumDetailProvider.overrideWith(
          (Ref ref, String albumId) async => throw UnimplementedError(),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentVisibleBranchIndexProvider.notifier).state =
        libraryBranchIndex;

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
    await settle(tester);
    expect(find.text('夜航西飞'), findsOneWidget);

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    await settle(tester);

    expect(find.text('夜航西飞'), findsOneWidget, reason: '重试后页面正常重建');
    expect(tester.takeException(), isNull);
  });
}
