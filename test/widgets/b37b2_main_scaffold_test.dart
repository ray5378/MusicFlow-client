// ============================================================================
// b37b2 —— `lib/widgets/main_scaffold.dart` 残余未覆盖分支补测。
//
// 基线 lcov（coverage/lcov.info）里 main_scaffold.dart 仍标 0 的 12 行：
//   65,69,70,73     `_restoreMusicFlowAppDrawerFocus` 整段
//   310,311,312,313 `_startNetworkObservation` 的 stream 监听体
//   406,407         `_handleBackPressed` 的 closeDrawer 分支
//   409,410         `_handleBackPressed` 的 popRootNavigator 分支
//
// 本文件只打**可覆盖**的 6 行（310–313 / 409–410），剩下 6 行是死代码/平台
// 盲区，见文件末尾「不可覆盖说明」。
//
// 关键手法（与 b30c 的 harness 同源，但这里做了两处增强）：
//   * ConnectivityMonitor 是普通可继承类，`networkTypeStream` / `currentNetworkType`
//     都是可覆写的 getter ⇒ 子类换成自建 StreamController，就能把
//     `_startNetworkObservation` 里「第二次事件才落地」的监听体（310–313）打起来
//     （b30c 曾判定此处不可覆盖，见其 #30C-7 注释；其实可通过子类化注入）。
//   * 分支导航器缺失时 `_openPageInContentArea` 会回落到**根**导航器推页，此时
//     触发系统返回键 → `rootNavigator.canPop()` 为真 → 命中 popRootNavigator。
//
// 只读 lib，零产品代码改动。
// ============================================================================

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/features/settings/pages/offline_cached_songs_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/main_scaffold.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_network_status_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/player/test_player_notifier.dart';

// ---------------------------------------------------------------------------
// 桩
// ---------------------------------------------------------------------------

class _FakeStatusLyricsController extends Mock
    implements StatusLyricsController {}

/// Cast peer 桩：MainScaffold 本组用例不触发 Cast，仅需避免真控制器起 Timer。
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

/// DLNA 直投桩：只保 `isCasting == false`，让链路落到本机分支。
class _RecordingDlnaCast extends DlnaCastNotifier {
  _RecordingDlnaCast(super.ref);

  @override
  Future<void> toggle() async {}

  @override
  Future<void> setVolume(int volume) async {}
}

/// 可手动注入 NetworkType 事件的 ConnectivityMonitor 子类。
///
/// 父类的 `_networkTypeController` 是库私有 StreamController，外部拿不到；
/// 但 `networkTypeStream` 是可覆写 getter，这里换成自建 broadcast 控制器，
/// 就能把 `_startNetworkObservation` 的监听体（310–313）跑起来。
class _ManualConnectivityMonitor extends ConnectivityMonitor {
  _ManualConnectivityMonitor(super.addressPool);

  final StreamController<NetworkType> _controller =
      StreamController<NetworkType>.broadcast();
  NetworkType _current = NetworkType.none;

  @override
  Stream<NetworkType> get networkTypeStream => _controller.stream;

  @override
  NetworkType get currentNetworkType => _current;

  void emit(NetworkType type) {
    _current = type;
    _controller.add(type);
  }

  @override
  void stop() {
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }
}

class _BranchPage extends StatelessWidget {
  const _BranchPage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}

// ---------------------------------------------------------------------------
// 仿真台
// ---------------------------------------------------------------------------

class _Bench {
  _Bench({
    this.networkStatusOverride = MusicFlowNetworkStatus.online,
    this.branchNavigatorKeys,
  });

  final String initialLocation = '/home';
  final MusicFlowNetworkStatus? networkStatusOverride;
  final List<GlobalKey<NavigatorState>>? branchNavigatorKeys;
  final Size size = const Size(1280, 900);

  late _ManualConnectivityMonitor connectivity;
  late GoRouter router;
  late ProviderContainer container;
  late AppLocalizations loc;
  late List<GlobalKey<NavigatorState>> branchKeys;

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Logger.setLoggingEnabled(false);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    connectivity = _ManualConnectivityMonitor(AddressPool(Dio()));
    addTearDown(connectivity.stop);

    final lyrics = _FakeStatusLyricsController();

    branchKeys = List<GlobalKey<NavigatorState>>.generate(
      2,
      (_) => GlobalKey<NavigatorState>(),
    );

    container = ProviderContainer(
      overrides: <Override>[
        // 非 ok 状态地址 ⇒ `activeAddressIsHealthy == false`，配合非 none 网络
        // 类型即可命中 `_resolveNetworkStatus` 的 weak 分支。
        activeAddressProvider.overrideWith(
          (ref) => const ServerAddress(
            id: 'test-addr',
            libraryId: 'test-lib',
            label: '测试服务器',
            url: 'https://music.example.test',
            priority: 1,
          ),
        ),
        connectivityMonitorProvider.overrideWithValue(connectivity),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        castPeerControllerProvider.overrideWith(
          (Ref ref) => _RecordingCastPeer(ref),
        ),
        dlnaCastProvider.overrideWith((Ref ref) => _RecordingDlnaCast(ref)),
        statusLyricsControllerProvider.overrideWithValue(lyrics),
      ],
    );
    addTearDown(container.dispose);

    final localKeys = branchKeys;
    final overrideKeys = branchNavigatorKeys;
    final overrideStatus = networkStatusOverride;

    router = GoRouter(
      initialLocation: initialLocation,
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) => MainScaffold(
            navigationShell: navigationShell,
            branchNavigatorKeys: overrideKeys ?? localKeys,
            miniPlayerOverride: const SizedBox.shrink(),
            showMiniPlayerOverride: false,
            networkStatusOverride: overrideStatus,
          ),
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              navigatorKey: localKeys[0],
              routes: <RouteBase>[
                GoRoute(
                  path: '/home',
                  builder: (context, state) => const _BranchPage('Home root'),
                  routes: <RouteBase>[
                    GoRoute(
                      path: 'detail',
                      builder: (context, state) =>
                          const _BranchPage('Home detail'),
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranch(
              navigatorKey: localKeys[1],
              routes: <RouteBase>[
                GoRoute(
                  path: '/songs',
                  builder: (context, state) => const _BranchPage('Songs root'),
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
          builder: (context, child) {
            loc = AppLocalizations.of(context);
            return child!;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

/// 固定帧推进，避免弱网横幅动画让 pumpAndSettle 不收敛。
Future<void> _settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  testWidgets('网络事件驱动 _resolveNetworkStatus：非 none + 地址不健康 → weak 条',
      (tester) async {
    final bench = _Bench(networkStatusOverride: null);
    await bench.pump(tester);

    // 注入一条 NetworkType 事件，让 _startNetworkObservation 的监听体
    // （310–313：取消兜底 Timer + 去重判断 + setState 落地观测值）跑起来。
    bench.connectivity.emit(NetworkType.wifi);
    await tester.pump();
    await _settle(tester);

    expect(find.byType(MusicFlowNetworkStatusBar), findsOneWidget);
    expect(find.text(bench.loc.widgets_network_weak_title), findsOneWidget);
    expect(find.text(bench.loc.widgets_network_offline_title), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重复同一网络类型命中 _observedNetworkType 去重提前返回', (tester) async {
    final bench = _Bench(networkStatusOverride: null);
    await bench.pump(tester);

    bench.connectivity.emit(NetworkType.wifi);
    await tester.pump();
    await _settle(tester);

    // 第二次同值 → 311 行 `_observedNetworkType == networkType` 直接 return。
    bench.connectivity.emit(NetworkType.wifi);
    await tester.pump();
    await _settle(tester);

    expect(find.text(bench.loc.widgets_network_weak_title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根导航器可弹时返回键走 popRootNavigator 分支', (tester) async {
    final bench = _Bench(
      networkStatusOverride: MusicFlowNetworkStatus.online,
      branchNavigatorKeys: const <GlobalKey<NavigatorState>>[],
    );
    await bench.pump(tester);

    // 分支导航器缺失 ⇒ `_openPageInContentArea` 回落到**根**导航器推页。
    final entry = find.descendant(
      of: find.byKey(
        const ValueKey<String>('musicflow-expanded-navigation'),
      ),
      matching: find.text(bench.loc.offline_cache_cached_songs_title),
    );
    expect(entry, findsOneWidget, reason: '宽屏侧栏缺少「已缓存音乐」入口');
    await tester.tap(entry);
    // 目标页存在常驻动画，用固定帧推进代替 pumpAndSettle（否则永不收敛）。
    await _settle(tester, frames: 8);
    expect(find.byType(OfflineCachedSongsPage), findsOneWidget);

    // 根导航器此时 canPop() 为真 ⇒ 系统返回键命中 popRootNavigator（409–410）。
    await tester.binding.handlePopRoute();
    await _settle(tester, frames: 8);

    expect(find.byType(OfflineCachedSongsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // 不可覆盖说明（真实缺陷/死代码，如需覆盖必须先改 lib，本轮铁律不改）：
  //   * 65–73 `_restoreMusicFlowAppDrawerFocus`：MainScaffold 把它作为
  //     `onReturnFocus` 传给 AppDrawer，但 AppDrawer 从头到尾**没有调用**该回调
  //     （全仓仅声明处命中，见 lib/widgets/app_drawer.dart [D-042]）⇒ 整段是
  //     死代码，键盘/无障碍「关闭抽屉后焦点回到触发控件」的承诺实际未接线。
  //   * 406–407 closeDrawer 分支：抽屉打开时返回事件被 DrawerController 的
  //     ChildBackButtonDispatcher 先吃掉，BackButtonListener 收不到
  //     （见 lib/widgets/main_scaffold.dart [D-044]）。
  // -------------------------------------------------------------------------
}
