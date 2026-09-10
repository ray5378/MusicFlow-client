import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 「No Overlay widget found」回归防线。
///
/// 2026-09-10 用户反馈:主窗口**右侧**出现一列竖排黄字。
/// 那是 Flutter 的 `ErrorWidget`(红框 + 黄字),文案为:
///
///   No Overlay widget found.
///   ... widgets require an Overlay widget ancestor ...
///   found ... To introduce an Overlay ...
///   either directly include one, or use a widget that contains an
///   Overlay itself, such as a Navigator, WidgetApp ...
///
/// 即某处调用了**非空版** `Overlay.of(context)`,
/// 而那个 `context` 底下没有 Overlay 祖先 —— 抛异常 → ErrorWidget 顶替,
/// 再被塞进一个极窄的槽位,横向折行后就成了"一列竖排英文"。
///
/// 这一组测试从**真实入口**驱动右侧队列面板,复现并锁死这个失败。
void main() {
  Widget host({
    required Widget child,
    List<Override> overrides = const <Override>[],
    Size size = const Size(1200, 800),
  }) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(body: Center(child: child)),
        ),
      ),
    );
  }

  /// 把 ErrorWidget 的黄字文案统一抓出来(框架异常文本 + 已渲染的 Text)。
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

  testWidgets('showRightQueuePanel 从普通页面上下文打开不报 "No Overlay widget found"',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BuildContext pageContext;
    await tester.pumpWidget(
      host(
        child: Builder(
          builder: (context) {
            pageContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    // 直接走桌面端真实入口(内部走 showRightQueuePanel → Overlay.of)。
    toggleRightQueuePanel(context: pageContext);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      collectOverlayErrors(tester),
      isEmpty,
      reason: '打开右侧队列面板时出现了 Overlay 查找失败 —— '
          '说明 OverlayEntry 被插入到了一个没有 Overlay 祖先的上下文。',
    );

    // 面板本体确实渲染出来了。
    expect(find.byKey(const ValueKey<String>('right-queue-panel')),
        findsOneWidget);

    closeRightQueuePanel();
    await tester.pump();
  });

  testWidgets('右侧队列面板二次点击可关闭且不留残影', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BuildContext pageContext;
    await tester.pumpWidget(
      host(
        child: Builder(
          builder: (context) {
            pageContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    toggleRightQueuePanel(context: pageContext);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('right-queue-panel')),
        findsOneWidget);

    toggleRightQueuePanel(context: pageContext);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey<String>('right-queue-panel')),
      findsNothing,
      reason: '二次点击「队列」应当关闭面板。',
    );
    expect(collectOverlayErrors(tester), isEmpty);
  });
}
