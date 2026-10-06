// Route C 补测：`lib/features/discover/widgets/hoverable_horizontal_scroll.dart`
//
// 覆盖点：
//   * 138：左箭头的单击回调（需先把列表滚离原点，`_canLeft` 才为 true，
//          这也是历史上「左箭头永不出现」的成因）。
//   * 139：左箭头长按开始 → 进入 80ms/步 的持续滚动。
//   * 161：右箭头长按结束 → `_stopHoldScroll()` 取消持续滚动定时器。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';

Widget _host() {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 120,
        child: HoverableHorizontalScroll(
          scrollStep: 240,
          builder: (context, controller) => ListView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            children: <Widget>[
              for (var i = 0; i < 6; i++)
                SizedBox(
                  width: 200,
                  height: 100,
                  child: Center(child: Text('card-$i')),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 左右箭头是纯图标按钮（`_ArrowBtn` 只渲染 Icon），按 Icon 定位。
Finder _arrow(IconData icon) => find.byWidgetPredicate(
      (Widget widget) => widget is Icon && widget.icon == icon,
    );

double _offsetOf(WidgetTester tester) {
  final list = tester.widget<ListView>(find.byType(ListView));
  return list.controller!.offset;
}

void main() {
  testWidgets('滚离原点后左箭头出现：单击左滚（138）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    // 起点：可右滚、不可左滚 → 只有右箭头。
    expect(_arrow(Icons.chevron_right), findsOneWidget);
    expect(_arrow(Icons.chevron_left), findsNothing);

    // 点右箭头滚一步，列表离开原点后左箭头才会出现。
    await tester.tap(_arrow(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(_arrow(Icons.chevron_left), findsOneWidget);
    final afterRight = _offsetOf(tester);
    expect(afterRight, greaterThan(0));

    // 单击左箭头：向左回退一步。
    await tester.tap(_arrow(Icons.chevron_left));
    await tester.pumpAndSettle();

    expect(
      _offsetOf(tester),
      lessThan(afterRight),
      reason: '左箭头应把列表往回滚',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('左箭头长按进入持续滚动（139）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(_arrow(Icons.chevron_right));
    await tester.pumpAndSettle();
    final before = _offsetOf(tester);

    // 长按左箭头：先立即平滑滚一步，随后定时器每 80ms 继续推进。
    final gesture =
        await tester.startGesture(tester.getCenter(_arrow(Icons.chevron_left)));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_offsetOf(tester), lessThan(before), reason: '长按左箭头应向左持续滚动');
    expect(tester.takeException(), isNull);
  });

  testWidgets('右箭头长按结束取消持续滚动定时器（161）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final gesture = await tester
        .startGesture(tester.getCenter(_arrow(Icons.chevron_right)));
    // 500ms 触发 onLongPressStart（持续滚动开始），再多推 300ms 让首步平滑动画收敛。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    final during = _offsetOf(tester);

    // 松手 → onLongPressEnd → _stopHoldScroll()，定时器取消，滚动停在原地。
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      (_offsetOf(tester) - during).abs(),
      lessThan(1),
      reason: '松手后不应再继续推进（定时器已取消）',
    );
    expect(tester.takeException(), isNull);
  });
}
