import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/navigation_provider.dart';
import 'package:musicflow_client/widgets/main_scaffold.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_network_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  group('MainScaffold back decision', () {
    test('keeps the established priority levels', () {
      expect(
        resolveMusicFlowBackAction(
          drawerOpen: true,
          rootCanPop: true,
          branchCanPop: true,
          currentBranchIndex: discoverBranchIndex,
        ),
        MusicFlowBackAction.closeDrawer,
      );
      expect(
        resolveMusicFlowBackAction(
          drawerOpen: false,
          rootCanPop: true,
          branchCanPop: true,
          currentBranchIndex: discoverBranchIndex,
        ),
        MusicFlowBackAction.popRootNavigator,
      );
      expect(
        resolveMusicFlowBackAction(
          drawerOpen: false,
          rootCanPop: false,
          branchCanPop: true,
          currentBranchIndex: discoverBranchIndex,
        ),
        MusicFlowBackAction.popBranchNavigator,
      );
      // 探索/我的分支已移除,音乐流即根分支 → 退到后台。
      expect(
        resolveMusicFlowBackAction(
          drawerOpen: false,
          rootCanPop: false,
          branchCanPop: false,
          currentBranchIndex: discoverBranchIndex,
        ),
        MusicFlowBackAction.moveAppToBackground,
      );
    });
  });

  group('MainScaffold destination mapping', () {
    testWidgets('page drawer trigger is compact-only', (tester) async {
      Future<void> pumpAtWidth(double width) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => Text(
                shouldShowPageDrawerTrigger(context) ? 'compact' : 'wide',
              ),
            ),
          ),
        );
        await tester.pump();
      }

      addTearDown(tester.view.reset);
      await pumpAtWidth(599);
      expect(find.text('compact'), findsOneWidget);

      await pumpAtWidth(600);
      expect(find.text('wide'), findsOneWidget);
    });

    test('exposes only the music-flow destination', () {
      // 探索分支已移除:侧栏仅保留「音乐流」,分支索引固定为 0。
      final destinations = musicFlowMainDestinations();
      expect(destinations, hasLength(1));
      expect(destinations.single.branchIndex, discoverBranchIndex);
      expect(destinations.single.label, '音乐流');
    });

    testWidgets('sidebar selects the only branch and reselect resets stack', (
      tester,
    ) async {
      final harness = await _pumpMainScaffold(tester);

      harness.router.go('/home/detail');
      await tester.pumpAndSettle();
      expect(find.text('Home detail'), findsOneWidget);
      expect(
        harness.container.read(currentVisibleBranchIndexProvider),
        discoverBranchIndex,
      );

      // 宽屏侧栏可见;重选当前分支 → 重置到分支根(对齐主项目行为)。
      await tester.tap(find.text('音乐流'));
      await tester.pumpAndSettle();
      expect(find.text('Home root'), findsOneWidget);
      expect(find.text('Home detail'), findsNothing);
    });
  });
}

Future<_MainScaffoldHarness> _pumpMainScaffold(WidgetTester tester) async {
  // 宽屏尺寸:侧栏常驻,可点击分支目标(compact 无底部导航)。
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: <Override>[
      // 给定一个非空地址,让 RandomSongsPush._connect 在「无库→无 token」分支
      // 直接返回,不再调度 2s 重连 Timer,避免测试结束时遗留 pending Timer。
      activeAddressProvider.overrideWith(
        (ref) => const ServerAddress(
          id: 'test-addr',
          libraryId: 'test-lib',
          label: '测试服务器',
          url: 'https://music.example.test',
          priority: 1,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final branchNavigatorKeys = <GlobalKey<NavigatorState>>[
    GlobalKey<NavigatorState>(),
  ];

  final router = GoRouter(
    initialLocation: '/home',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainScaffold(
            navigationShell: navigationShell,
            branchNavigatorKeys: branchNavigatorKeys,
            showMiniPlayerOverride: false,
            networkStatusOverride: MusicFlowNetworkStatus.online,
            drawerOverride: const SizedBox(width: 320),
            miniPlayerOverride: const SizedBox(height: 72),
          );
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[discoverBranchIndex],
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
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return _MainScaffoldHarness(router: router, container: container);
}

class _MainScaffoldHarness {
  const _MainScaffoldHarness({required this.router, required this.container});

  final GoRouter router;
  final ProviderContainer container;
}

class _BranchPage extends StatelessWidget {
  const _BranchPage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}
