// Route C 补测：`lib/features/library/widgets/library_collection_components.dart`
//
// 覆盖点：
//   * 329：`MusicFlowLibrarySectionLabel` 的构造函数（此前全库无构造点）。
//   * 390-396：`MusicFlowAzIndexReveal.didUpdateWidget` —— 由 enabled=true
//     切到 false 时，取消延时隐藏定时器并把浮层状态复位；复位后再切回
//     enabled=true，浮层不应「诈尸」重新显示。
//
// 跳过并报告：
//   * 439：`Listener.onPointerCancel` —— 需要在一次真实手势中途派发
//     PointerCancelEvent；flutter_test 的 TestGesture 没有稳定的 cancel 入口，
//     强行拼事件会让用例变成「断言无异常」的空壳，故不凑数。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: SizedBox(width: 360, height: 640, child: child),
      ),
    );

void main() {
  testWidgets('MusicFlowLibrarySectionLabel 渲染分区标题（329）', (tester) async {
    await tester.pumpWidget(
      _host(const MusicFlowLibrarySectionLabel(label: '本周新增')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MusicFlowLibrarySectionLabel), findsOneWidget);
    expect(find.text('本周新增'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A-Z 索引条禁用时复位浮层状态（390-396）', (tester) async {
    final seen = <bool>[];
    Widget build(bool enabled) => _host(
          MusicFlowAzIndexReveal(
            enabled: enabled,
            builder: (context, opacity, visible) {
              seen.add(visible);
              // 外层 Listener 默认 deferToChild：子级必须整块可命中，
              // 否则右边缘按下收不到 PointerDownEvent。
              return Listener(
                behavior: HitTestBehavior.opaque,
                child: SizedBox.expand(
                  child: Center(
                    child: Text(visible ? '显示索引条' : '隐藏索引条'),
                  ),
                ),
              );
            },
          ),
        );

    await tester.pumpWidget(build(true));
    await tester.pump();
    expect(seen.last, isFalse, reason: '初始态索引条是隐藏的');

    // 在右边缘 40px 内按下 → _beginPointer → _reveal() → 浮层显示。
    // 注意：不能用 pumpAndSettle —— 它会把时间推进到 1200ms 的自动隐藏定时器
    // 之后，浮层反而已经收回了。
    await tester.tapAt(const Offset(355, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(seen.last, isTrue, reason: '右边缘按下后索引条应浮出');

    // enabled: true → false：didUpdateWidget 取消定时器并把 _visible 复位。
    await tester.pumpWidget(build(false));
    await tester.pump();
    expect(seen.last, isFalse, reason: '禁用后 builder 应拿到 visible=false');

    // 再切回 enabled=true：若复位没生效（_visible 仍为 true），这里会重新显示。
    await tester.pumpWidget(build(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      seen.last,
      isFalse,
      reason: '复位后再启用不应让索引条诈尸（证明 396 行 _visible = false 生效）',
    );
    expect(tester.takeException(), isNull);
  });
}
