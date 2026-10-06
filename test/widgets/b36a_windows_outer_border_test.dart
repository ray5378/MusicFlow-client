// b36a —— Windows 窗口细黑边（`lib/widgets/windows_title_bar.dart` 新增的
// `WindowsOuterBorder` + `lib/app.dart` builder 的 Windows 分支）补测。
//
// 覆盖点：
//   * WindowsOuterBorder 用 DecoratedBox 描四边 1 逻辑像素纯黑边；
//   * 只描边不填充（BoxDecoration.color 为 null）；child 原样渲染；
//   * 恒定纯黑，与亮/暗主题、主色无关；
//   * WindowsOuterBorder.borderWidth == 1；
//   * app.dart：Windows 平台 builder 用 WindowsOuterBorder 包裹内容并叠加
//     WindowsWindowChrome；非 Windows 平台不出现边框。
//
// 产品代码零改动；仅新增 test/。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:musicflow_client/app.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

Widget host(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? AppTheme.light(),
    home: Scaffold(body: child),
  );
}

/// 取出 WindowsOuterBorder 内部那个 DecoratedBox 的 BoxDecoration。
BoxDecoration outerDecoration(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byType(WindowsOuterBorder),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  return box.decoration as BoxDecoration;
}

GoRouter _stubRouter() => GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (_, _) => const Text('stub-page'),
        ),
      ],
    );

Future<ProviderScope> pumpApp(WidgetTester tester) async {
  final scope = ProviderScope(
    overrides: <Override>[routerProvider.overrideWithValue(_stubRouter())],
    child: const App(),
  );
  await tester.pumpWidget(scope);
  await tester.pump(const Duration(milliseconds: 100));
  // Windows/Android 的 StartupUpdateCheckScope 3s 后检查更新，泵过定时器。
  await tester.pump(const Duration(seconds: 4));
  return scope;
}

void main() {
  group('WindowsOuterBorder 组件', () {
    testWidgets('用 DecoratedBox 描四边 1px 纯黑边、只描边不填充', (tester) async {
      await tester.pumpWidget(host(const WindowsOuterBorder(child: Text('x'))));

      final deco = outerDecoration(tester);
      expect(deco.border, isA<Border>());
      final border = deco.border! as Border;
      for (final side in <BorderSide>[
        border.top,
        border.right,
        border.bottom,
        border.left,
      ]) {
        expect(side.color, Colors.black, reason: '窗口外框恒为纯黑');
        expect(side.width, 1.0);
        expect(side.style, BorderStyle.solid);
      }
      expect(deco.color, isNull, reason: '只描边，不填充背景');
      expect(tester.takeException(), isNull);
    });

    testWidgets('borderWidth 常量恰为 1', (tester) async {
      expect(WindowsOuterBorder.borderWidth, 1.0);
    });

    testWidgets('child 原样渲染且可直接命中', (tester) async {
      await tester.pumpWidget(host(const WindowsOuterBorder(child: Text('内容层'))));

      expect(find.text('内容层'), findsOneWidget);
      // DecoratedBox 的 child 就是传入的 child（无额外包裹层）。
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(WindowsOuterBorder),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(box.child, isA<Text>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('恒定纯黑：暗主题 / 自定义主色下仍是黑色 1px', (tester) async {
      final decoLists = <BoxDecoration>[];
      for (final theme in <ThemeData>[
        AppTheme.dark(),
        AppTheme.light(seedColor: const Color(0xFF123456)),
      ]) {
        await tester.pumpWidget(
          host(const WindowsOuterBorder(child: Text('x')), theme: theme),
        );
        decoLists.add(outerDecoration(tester));
      }
      for (final deco in decoLists) {
        final border = deco.border! as Border;
        expect(border.top.color, Colors.black);
        expect(border.top.width, 1.0);
      }
    });
  });

  group('app.dart Windows 分支', () {
    testWidgets('Windows：builder 用 WindowsOuterBorder 包裹内容并叠加 chrome',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpApp(tester);

        expect(find.byType(WindowsOuterBorder), findsOneWidget);
        expect(find.byType(WindowsWindowChrome), findsOneWidget);
        expect(find.text('stub-page'), findsOneWidget);

        // 内容层那圈边框仍是 1px 纯黑。
        final deco = outerDecoration(tester);
        final border = deco.border! as Border;
        expect(border.top.color, Colors.black);
        expect(border.top.width, 1.0);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('非 Windows（iOS）：不出现窗口外框与 chrome', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpApp(tester);

        expect(find.byType(WindowsOuterBorder), findsNothing);
        expect(find.byType(WindowsWindowChrome), findsNothing);
        expect(find.text('stub-page'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
