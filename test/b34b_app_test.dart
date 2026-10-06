import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicflow_client/app.dart';
import 'package:musicflow_client/features/auth/pages/login_page.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show WindowsWindowChrome;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DummyAuthRepo extends Mock implements AuthRepository {}

class _EmptyLibraryRepo extends Mock implements LibraryRepository {}

/// 用空仓库构造真实 AuthNotifier：_init 读取库列表失败/为空时自然落到
/// 「未认证 + 初始化完成」状态，恰好驱动未认证重定向分支。
GoRouter _stubRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Text('stub-page'),
        ),
      ],
    );

  Future<ProviderScope> pumpAppWithStubRouter(WidgetTester tester,
      {bool settleUpdateTimer = false}) async {
    final scope = ProviderScope(
      overrides: [routerProvider.overrideWithValue(_stubRouter())],
      child: const App(),
    );
    await tester.pumpWidget(scope);
    await tester.pump(const Duration(milliseconds: 100));
    if (settleUpdateTimer) {
      // Windows 平台 StartupUpdateCheckScope 会在 3s 后检查更新，
      // 泵过定时器避免「Timer still pending」，检查失败会被内部吞掉。
      await tester.pump(const Duration(seconds: 4));
    }
    return scope;
  }

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('App 正常构建（非桌面缩放分支：iOS 平台）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pumpAppWithStubRouter(tester, settleUpdateTimer: true);

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('stub-page'), findsOneWidget);
    // iOS 非 Windows 桌面：无自绘窗口 chrome。
    expect(find.byType(WindowsWindowChrome), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面缩放：超大屏（longestPhysicalSide>=3800）→ 0.86 + 最紧凑密度',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(4200, 2000);
    tester.view.devicePixelRatio = 2.0; // longestPhysicalSide = 4000
    addTearDown(tester.view.reset);

    await pumpAppWithStubRouter(tester, settleUpdateTimer: true);

    final context = tester.element(find.text('stub-page'));
    final mediaQuery = MediaQuery.of(context);
    expect(mediaQuery.textScaler.scale(10.0), closeTo(8.6, 0.01),
        reason: '文本缩放应乘以 0.86');
    expect(
      Theme.of(context).visualDensity,
      const VisualDensity(horizontal: -2, vertical: -2),
    );
    // Windows 桌面：自绘窗口 chrome 挂在 builder 层。
    expect(find.byType(WindowsWindowChrome), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面缩放：中屏（longestPhysicalSide>=3000）→ 0.90 档', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // longestPhysicalSide = 物理最长边 = 3200 ≥ 3000；逻辑宽 2000 < 2200、
    // 逻辑 shortestSide 1250 < 1400，避开更高档位。
    tester.view.physicalSize = const Size(3200, 2000);
    tester.view.devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);

    await pumpAppWithStubRouter(tester, settleUpdateTimer: true);

    final context = tester.element(find.text('stub-page'));
    expect(MediaQuery.of(context).textScaler.scale(10.0),
        closeTo(9.0, 0.01));
    expect(
      Theme.of(context).visualDensity,
      const VisualDensity(horizontal: -1.5, vertical: -1.5),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面缩放：小屏（各阈值之下）→ 不缩放 + 标准密度', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpAppWithStubRouter(tester, settleUpdateTimer: true);

    final context = tester.element(find.text('stub-page'));
    expect(MediaQuery.of(context).textScaler.scale(10.0), closeTo(10.0, 0.01));
    expect(Theme.of(context).visualDensity, VisualDensity.standard);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('真实路由：未认证且初始化完成 → 重定向到 /login', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final scope = ProviderScope(
      overrides: [
        authStateProvider.overrideWith(
          (ref) => AuthNotifier(_DummyAuthRepo(), _EmptyLibraryRepo()),
        ),
      ],
      child: const App(),
    );
    await tester.pumpWidget(scope);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(LoginPage), findsOneWidget,
        reason: '未认证应被重定向到登录页');
    debugDefaultTargetPlatformOverride = null;
  });
}
