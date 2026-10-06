// b38c3 —— Route C 补测：features/discover/widgets/section_shift.dart 剩余缺口。
//   * 64：performLayout 里 constraints.hasInfiniteHeight == true 的分支
//     （直接把 SectionShift 放进垂直无界的 SingleChildScrollView）。
//
// line 58（child == null → size = constraints.smallest）为**不可达分支**：
// SectionShift 的构造函数把 child 声明为 `required Widget child`（非空），
// RenderProxyBox.child 永远不会为 null，故无法构造该路径 —— 已在回报中列入死代码。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/features/discover/widgets/section_shift.dart';

void main() {
  testWidgets('SectionShift：垂直无界高度 → hasInfiniteHeight 分支（64）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SectionShift(
              top: -8,
              bottom: -8,
              child: const SizedBox(width: 120, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SectionShift), findsOneWidget);
    // 无界高度下 childConstraints 直接沿用外层 constraints，布局应正常收敛。
    final size = tester.getSize(find.byType(SectionShift));
    expect(size.width, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SectionShift：有界高度 → 走 copyWith 收缩分支（对照）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 200,
              child: SectionShift(
                top: -8,
                bottom: -8,
                child: const SizedBox(width: 120, height: 40),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SectionShift), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SectionShift：top/bottom setter 变化触发 markNeedsLayout', (tester) async {
    Widget build(double top) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 200,
                child: SectionShift(
                  top: top,
                  bottom: -8,
                  child: const SizedBox(width: 120, height: 40),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(build(-8));
    await tester.pump();
    await tester.pumpWidget(build(-16));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
