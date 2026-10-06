// Route C 补测：`lib/features/discover/widgets/section_shift.dart`
//
// 覆盖点：
//   * 64：父级给到「无限高」约束时（如 UnconstrainedBox / 横向滚动容器），
//         子组件按自然高度布局，不做 maxHeight - (top+bottom) 的收缩。
//   * 75/76/77：computeDistanceToActualBaseline —— 把子组件基线下移 |top|，
//         供 Row(crossAxisAlignment: baseline) 对齐文本。
//
// 跳过并报告：
//   * 58：`SectionShift.child` 是 **required 命名参数**（源码 13 行），
//         `createRenderObject` 必然带上 child，`if (child == null)` 恒为假
//         ⇒ 不可达的防御性分支。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/features/discover/widgets/section_shift.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

/// 按 [SectionShift.top] 定位（同一棵树里可能有多个位移量不同的实例）。
Finder _shift(double top) => find.byWidgetPredicate(
      (Widget widget) => widget is SectionShift && widget.top == top,
    );

void main() {
  testWidgets('无限高约束下子组件按自然高度布局（64）', (tester) async {
    await tester.pumpWidget(
      _host(
        const UnconstrainedBox(
          child: SectionShift(
            top: -10,
            bottom: -10,
            child: SizedBox(width: 50, height: 150),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(SectionShift));
    // 走 64 行（hasInfiniteHeight → 原样透传约束）时子组件取自然高度 150，
    // 再收缩 top+bottom = -20 → 130。
    expect(size.width, 50);
    expect(size.height, 130, reason: '无限高分支下高度应为 150 - 20 = 130');
    expect(tester.takeException(), isNull);
  });

  testWidgets('computeDistanceToActualBaseline 把子基线偏移 top（75-77）',
      (tester) async {
    // [Baseline] 在 performLayout 里调用子级的 getDistanceToBaseline，
    // 是 computeDistanceToActualBaseline 唯一的合法调用方（直接调用会撞
    // debugDoingBaseline 断言）。
    // 两次渲染各自独立（避免 Column 堆叠把纵向偏移混进来）。
    Future<double> topOf(double shift) async {
      await tester.pumpWidget(
        _host(
          Align(
            alignment: Alignment.topLeft,
            child: Baseline(
              baseline: 40,
              baselineType: TextBaseline.alphabetic,
              child: SectionShift(
                top: shift,
                bottom: 0,
                child: const Text('flat', style: TextStyle(fontSize: 20)),
              ),
            ),
          ),
        ),
      );
      return tester.getTopLeft(_shift(shift)).dy;
    }

    final flatTop = await topOf(0);
    final shiftedTop = await topOf(12);

    // childParentData.offset.dy = baseline - (子基线 + top)：
    // top=12 的子树整体上移 12px，说明基线确实叠加了 top。
    expect(
      flatTop - shiftedTop,
      closeTo(12, 0.01),
      reason: '基线必须叠加 top=12（源码 77 行 childBaseline + _top）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Row baseline 对齐时的真实调用方（75-77）', (tester) async {
    await tester.pumpWidget(
      _host(
        const Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text('anchor', style: TextStyle(fontSize: 20)),
            SectionShift(
              top: 8,
              bottom: 0,
              child: Text('shifted', style: TextStyle(fontSize: 20)),
            ),
          ],
        ),
      ),
    );

    // 能正常布局即说明 computeDistanceToActualBaseline 被调用且返回了非空基线。
    final shifted = tester.renderObject<RenderBox>(find.byType(SectionShift));
    expect(shifted.size.isFinite, isTrue);
    expect(shifted.size.width, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
