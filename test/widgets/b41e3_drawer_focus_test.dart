// ============================================================================
// b41e3 —— [D-042] AppDrawer.onReturnFocus 接线守卫。
//
// 接线原理：Scaffold 抽屉由 DrawerController 承载，动画完全收起后不再构建
// child，AppDrawer 随之被卸载 ⇒ _AppDrawerState.dispose 是「抽屉真正关闭」
// 的单一收敛点（手势关闭 / 点遮罩 / 返回键 / Navigator.pop / closeDrawer
// 全部汇入）。dispose 回调 onReturnFocus → MainScaffold 的
// _restoreMusicFlowAppDrawerFocus 把焦点还给 openMusicFlowAppDrawer 记录
// 的触发控件。
// ============================================================================

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/library/random_songs_push_provider.dart';
import 'package:musicflow_client/widgets/app_drawer.dart';
import 'package:musicflow_client/widgets/main_scaffold.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_network_status_bar.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/player/test_player_notifier.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockLibraryRepository extends Mock implements LibraryRepository {}

/// 借用 AuthNotifier 状态机；mock 未打桩时 _init() 走 catch，落地为
/// 「未认证、初始化完成」（同 b38b2 手法），AppDrawer 展示 Guest 视图。
class _StaticAuthNotifier extends AuthNotifier {
  _StaticAuthNotifier()
      : super(_MockAuthRepository(), _MockLibraryRepository());
}

class _FakeStatusLyricsController extends Mock
    implements StatusLyricsController {}

/// 空推送客户端桩：真客户端构造即连 WebSocket，失败后挂 2s 重连 Timer，
/// 会让 fake_async 判定 pending Timer；MainScaffold 只 read 激活不调方法。
class _NoopRandomSongsPush extends Fake implements RandomSongsPushClient {}

class _RecordingCastPeer extends CastPeerController {
  _RecordingCastPeer(super.ref);

  @override
  Future<void> toggle() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> setVolume(int volume) async {}
}

class _RecordingDlnaCast extends DlnaCastNotifier {
  _RecordingDlnaCast(super.ref);

  @override
  Future<void> toggle() async {}

  @override
  Future<void> setVolume(int volume) async {}
}

class _ManualConnectivityMonitor extends ConnectivityMonitor {
  _ManualConnectivityMonitor(super.addressPool);

  final StreamController<NetworkType> _controller =
      StreamController<NetworkType>.broadcast();

  @override
  Stream<NetworkType> get networkTypeStream => _controller.stream;

  @override
  NetworkType get currentNetworkType => NetworkType.none;

  @override
  void stop() {
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }
}

/// AppDrawer + 裸 Scaffold 仿真台：只验证 AppDrawer 自身的接线时序。
class _DrawerBench {
  _DrawerBench(this.onReturnFocus);

  final VoidCallback onReturnFocus;
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Logger.setLoggingEnabled(false);
    container = ProviderContainer(overrides: <Override>[
      authStateProvider.overrideWith((ref) => _StaticAuthNotifier()),
      activeAddressProvider.overrideWith((ref) => null),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            key: scaffoldKey,
            drawer: AppDrawer(onReturnFocus: onReturnFocus),
            body: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    scaffoldKey.currentState!.closeDrawer();
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('抽屉未打开时 AppDrawer 不挂树，onReturnFocus 不触发', (tester) async {
    var calls = 0;
    final bench = _DrawerBench(() => calls++);
    await bench.pump(tester);

    expect(find.byType(AppDrawer), findsNothing);
    expect(calls, 0);
  });

  testWidgets('closeDrawer 关闭路径：onReturnFocus 恰好回调一次', (tester) async {
    var calls = 0;
    final bench = _DrawerBench(() => calls++);
    await bench.pump(tester);

    await bench.open(tester);
    expect(find.byType(AppDrawer), findsOneWidget);
    expect(calls, 0);

    await bench.close(tester);
    expect(find.byType(AppDrawer), findsNothing);
    expect(calls, 1);
  });

  testWidgets('点遮罩关闭路径（手势类）：onReturnFocus 同样回调', (tester) async {
    var calls = 0;
    final bench = _DrawerBench(() => calls++);
    await bench.pump(tester);

    await bench.open(tester);
    // 抽屉宽 240（compact 上限），默认 800x600 测试面其余区域是遮罩。
    await tester.tapAt(const Offset(700, 300));
    await tester.pumpAndSettle();

    expect(find.byType(AppDrawer), findsNothing);
    expect(calls, 1);
  });

  testWidgets('Navigator.pop 关闭路径（点菜单项关抽屉）：onReturnFocus 回调', (tester) async {
    var calls = 0;
    final bench = _DrawerBench(() => calls++);
    await bench.pump(tester);

    await bench.open(tester);
    // 与 _closeDrawerAndPushPage 相同的关闭方式：pop 掉 DrawerController
    // 挂在壳路由上的 LocalHistoryEntry。
    bench.scaffoldKey.currentState!.context
        .findAncestorStateOfType<NavigatorState>()!
        .pop();
    await tester.pumpAndSettle();

    expect(find.byType(AppDrawer), findsNothing);
    expect(calls, 1);
  });

  testWidgets('开-关-开-关两轮：每轮各回调一次，共两次', (tester) async {
    var calls = 0;
    final bench = _DrawerBench(() => calls++);
    await bench.pump(tester);

    await bench.open(tester);
    await bench.close(tester);
    expect(calls, 1);

    await bench.open(tester);
    await bench.close(tester);
    expect(find.byType(AppDrawer), findsNothing);
    expect(calls, 2);
  });

  testWidgets('MainScaffold 集成：关抽屉后焦点还原到触发控件（_restoreMusicFlowAppDrawerFocus 复活）',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Logger.setLoggingEnabled(false);
    final connectivity = _ManualConnectivityMonitor(AddressPool(Dio()));
    addTearDown(connectivity.stop);
    final container = ProviderContainer(overrides: <Override>[
      authStateProvider.overrideWith((ref) => _StaticAuthNotifier()),
      activeAddressProvider.overrideWith((ref) => null),
      connectivityMonitorProvider.overrideWithValue(connectivity),
      playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
      castPeerControllerProvider.overrideWith(
        (Ref ref) => _RecordingCastPeer(ref),
      ),
      dlnaCastProvider.overrideWith((Ref ref) => _RecordingDlnaCast(ref)),
      statusLyricsControllerProvider.overrideWithValue(
        _FakeStatusLyricsController(),
      ),
      randomSongsPushProvider.overrideWithValue(_NoopRandomSongsPush()),
    ]);
    addTearDown(container.dispose);

    final triggerNode = FocusNode();
    final branchKeys = List<GlobalKey<NavigatorState>>.generate(
      1,
      (_) => GlobalKey<NavigatorState>(),
    );
    final router = GoRouter(
      initialLocation: '/home',
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) => MainScaffold(
            navigationShell: navigationShell,
            branchNavigatorKeys: branchKeys,
            miniPlayerOverride: const SizedBox.shrink(),
            showMiniPlayerOverride: false,
            networkStatusOverride: MusicFlowNetworkStatus.online,
          ),
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              navigatorKey: branchKeys[0],
              routes: <RouteBase>[
                GoRoute(
                  path: '/home',
                  builder: (context, state) => Focus(
                    focusNode: triggerNode,
                    autofocus: true,
                    child: const Scaffold(body: SizedBox.expand()),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(triggerNode));

    // openMusicFlowAppDrawer 记录触发焦点后再开抽屉。
    openMusicFlowAppDrawer();
    await tester.pumpAndSettle();
    expect(find.byType(AppDrawer), findsOneWidget);

    // 关抽屉：AppDrawer 卸载 → onReturnFocus → 焦点还原到触发控件。
    scaffoldKey.currentState!.closeDrawer();
    await tester.pumpAndSettle();
    expect(find.byType(AppDrawer), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(triggerNode));
  });
}
