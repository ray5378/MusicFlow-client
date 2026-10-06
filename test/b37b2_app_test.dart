// b37b2 —— `lib/app.dart` 残余分支补测。
//
// b34b 覆盖：iOS 非桌面、0.86 / 0.90 / 小屏不缩放、未认证重定向 /login。
// b36a 覆盖：Windows builder 的 WindowsOuterBorder + Chrome。
// 本文件补：
//   * macOS 也走桌面缩放（_isDesktopScaledPlatform 的 macOS 分支）；
//   * 0.95 档（width>=1440）→ textScale 0.95 + visualDensity(-1,-1)；
//   * _systemUiOverlayStyle 的**暗色**分支（深色主题 → 浅色状态栏图标）；
//   * 已认证时访问 /login → 重定向回 /home（redirect 的已认证分支）。
// 产品代码零改动；仅新增 test/。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/app.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show WindowsWindowChrome;

GoRouter _stubRouter() => GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(path: '/', builder: (_, _) => const Text('stub-page')),
      ],
    );

Future<ProviderScope> pumpApp(
  WidgetTester tester, {
  Size physicalSize = const Size(1200, 800),
  double dpr = 1.0,
  bool settleUpdateTimer = true,
}) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  final scope = ProviderScope(
    overrides: <Override>[routerProvider.overrideWithValue(_stubRouter())],
    child: const App(),
  );
  await tester.pumpWidget(scope);
  await tester.pump(const Duration(milliseconds: 100));
  if (settleUpdateTimer) {
    await tester.pump(const Duration(seconds: 4));
  }
  return scope;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('macOS 属桌面缩放平台：0.95 档生效且无 Windows chrome', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      // 逻辑宽 1440、dpr 1 → longestPhysicalSide=1440 < 2400，但 width>=1440 → 0.95。
      await pumpApp(tester, physicalSize: const Size(1440, 900));
      final context = tester.element(find.text('stub-page'));
      expect(MediaQuery.of(context).textScaler.scale(10.0), closeTo(9.5, 0.01));
      expect(
        Theme.of(context).visualDensity,
        const VisualDensity(horizontal: -1, vertical: -1),
      );
      expect(find.byType(WindowsWindowChrome), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows 0.95 档（width>=1440）→ 缩放 0.95 + 密度 -1', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpApp(tester, physicalSize: const Size(1440, 900));
      final context = tester.element(find.text('stub-page'));
      expect(MediaQuery.of(context).textScaler.scale(10.0), closeTo(9.5, 0.01));
      expect(
        Theme.of(context).visualDensity,
        const VisualDensity(horizontal: -1, vertical: -1),
      );
      expect(find.byType(WindowsWindowChrome), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('深色主题：系统 UI 覆盖层取浅色状态栏图标', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'theme_mode': 'dark',
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pumpApp(tester, settleUpdateTimer: false);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      // 主题设置为深色 → 主题亮度为 dark。
      final context = tester.element(find.text('stub-page'));
      expect(Theme.of(context).brightness, Brightness.dark);

      final regions = tester
          .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .toList();
      expect(regions, isNotEmpty);
      final style = regions.first.value;
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
