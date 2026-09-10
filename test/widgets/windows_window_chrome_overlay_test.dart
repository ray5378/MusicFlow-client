import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show WindowsWindowChrome;

/// `WindowsWindowChrome` 的 Overlay 祖先回归防线。
///
/// 2026-09-10 用户反馈:主窗口**右侧**出现一列竖排黄字。抓取的文本是:
///
///   No Overlay widget found.
///   ... widgets require an Overlay widget ancestor ...
///   ... either directly include one, or use a widget that contains an
///   Overlay itself, such as a Navigator, WidgetApp ...
///
/// 根因:`app.dart` 把 [WindowsWindowChrome] 挂进 `MaterialApp.builder` 的
/// `Stack`(为了「弹窗打开时顶部仍可拖拽窗口」),而这个位置**在
/// Navigator/Overlay 之外**。组件内的窗口控制按钮用了 `Tooltip`,
/// `Tooltip` 显示时需要 `Overlay.of(context)` → 找不到 Overlay → 抛异常 →
/// 被 `ErrorWidget` 顶替(红框 + 黄字),塞进窄槽横向折行后,
/// 就成了"一列竖排英文"。
///
/// 本组测试锁死「chrome 在 Overlay 之外也必须能安全构建」。
void main() {
  /// 复刻 `app.dart` 的真实结构:chrome 挂在 MaterialApp.builder 里的 Stack,
  /// 即 Navigator/Overlay 之外。
  Widget appLikeHost() {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.dark(),
        home: const Scaffold(body: SizedBox.expand()),
        builder: (context, child) => Stack(
          children: <Widget>[
            child!,
            const WindowsWindowChrome(),
          ],
        ),
      ),
    );
  }

  List<String> collectOverlayErrors(WidgetTester tester) {
    final out = <String>[];
    Object? ex = tester.takeException();
    while (ex != null) {
      out.add('$ex');
      ex = tester.takeException();
    }
    for (final element in find.byType(Text).evaluate()) {
      final data = (element.widget as Text).data ?? '';
      if (data.contains('No Overlay widget found') ||
          data.contains('Overlay widget ancestor')) {
        out.add(data);
      }
    }
    return out;
  }

  group('WindowsWindowChrome 挂在 Overlay 之外', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('构建与悬停都不产生 "No Overlay widget found"',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(appLikeHost());
      await tester.pump();
      expect(collectOverlayErrors(tester), isEmpty);

      // 悬停到右上角窗口控制按钮上:Tooltip 会尝试显示,
      // 这一步正是「No Overlay widget found」的触发点。
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byType(WindowsWindowChrome),
        findsOneWidget,
        reason: 'chrome 本体必须渲染出来(不能整块被 ErrorWidget 顶替)。',
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('窗口控制按钮仍可命中(未被 ErrorWidget 顶替)',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(appLikeHost());
      await tester.pump();

      // 右上角三个系统按钮之一(关闭)必须存在且位于右缘。
      final closeIcons = find.byIcon(Icons.close);
      expect(closeIcons, findsWidgets);
      final rect = tester.getRect(closeIcons.first);
      expect(rect.center.dx, greaterThan(1200 * 0.8));
      expect(collectOverlayErrors(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
