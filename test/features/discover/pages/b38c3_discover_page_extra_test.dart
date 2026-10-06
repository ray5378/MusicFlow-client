// b38c3 —— discover_page.dart 剩余可达分支补测（Route C）。
//
// 单点缺口：line 633 最近歌单卡片 `onLongPress: () => showPlaylistOptionsSheet(...)`。
// 既有 b37c2 用例只对「本地平台推荐 / 固定推荐」两类卡片做过长按，最近歌单卡片
// （RecentPlaylistsSection 的横向 rail）的长按回调从未触发。
//
// 直接挂公开的 RecentPlaylistsSection（无需整页），长按卡片即可。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/features/discover/pages/discover_page.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../player/test_player_notifier.dart';

class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({this.currentNetworkType = NetworkType.wifi});

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

  Future<void> dispose() => _controller.close();
}

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);
}

class _PlaylistRepository extends Mock implements PlaylistRepository {}

class _RecommendRepository extends Mock implements RecommendRepository {}

class _CastPeer extends CastPeerController {
  _CastPeer(super.ref);
}

class _Dlna extends DlnaCastNotifier {
  _Dlna(super.ref);
}

List<Override> _coreOverrides() => <Override>[
      connectivityMonitorProvider.overrideWithValue(FakeConnectivityMonitor()),
      ensureActiveAddressProvider.overrideWith(
        (ref) async => const ServerAddress(
          id: 'server-1',
          libraryId: 'library-1',
          label: 'Test server',
          url: 'https://example.test',
          priority: 0,
        ),
      ),
      playerProvider.overrideWith((ref) => _RecPlayer(PlayerState())),
      castPeerControllerProvider.overrideWith((Ref ref) => _CastPeer(ref)),
      dlnaCastProvider.overrideWith((Ref ref) => _Dlna(ref)),
      effectiveIsPlayingProvider.overrideWith((ref) => false),
      playlistRepositoryProvider.overrideWith((ref) => _PlaylistRepository()),
      recommendRepositoryProvider.overrideWith((ref) => _RecommendRepository()),
      playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
      playlistDetailProvider.overrideWith(
        (ref, String id) async =>
            Playlist(id: id, name: '歌单', songCount: 0, duration: 0),
      ),
    ];

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pumpSection(
  WidgetTester tester,
  Widget child,
  List<Override> overrides,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await _settle(tester, frames: 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('最近歌单卡片长按 → 打开歌单操作弹窗（633）', (tester) async {
    await _pumpSection(
      tester,
      const RecentPlaylistsSection(),
      <Override>[
        ..._coreOverrides(),
        recentPlaylistsProvider.overrideWith(
          (ref) async => <Playlist>[
            Playlist(id: 'pl-1', name: '最近一', songCount: 5, duration: 100),
          ],
        ),
      ],
    );

    final card = find.widgetWithText(DiscoverPlaylistCard, '最近一');
    expect(card, findsOneWidget);

    await tester.longPress(card);
    await _settle(tester, frames: 12);

    // 长按回调里 showPlaylistOptionsSheet 打开 → 出现底部弹窗。
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
