// b38c3 —— hoverable_horizontal_scroll.dart 剩余可达分支补测（Route C）。
//
// 单点缺口：line 161 右侧箭头的 `onLongPressEnd: (_) => _stopHoldScroll()`。
// 左侧箭头同款回调（line 140）被点过，右侧箭头（`_canRight` 态）从未走到——
// 既有用例只覆盖了左箭头 / 未溢出（无箭头）两种布局。
//
// 这里构造一个真实横向溢出（maxScrollExtent > 0）的列表，让 `_canRight` 为真，
// 再从右箭头所在 GestureDetector 直接驱动 onLongPressEnd（避开 FadeTransition
// 未悬停时 opacity=0 的命中噪声）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';

void main() {
  testWidgets('右侧箭头长按结束 → 停止持续滚动（onLongPressEnd 闭包体）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 120,
              child: HoverableHorizontalScroll(
                builder: (BuildContext context, ScrollController controller) {
                  return ListView(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    children: <Widget>[
                      for (var i = 0; i < 10; i++)
                        SizedBox(
                          width: 100,
                          height: 100,
                          child: Center(child: Text('item$i')),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    // 首帧 post-frame 回调里 _checkBounds 才知道能否右滚。
    await tester.pump();
    await tester.pumpAndSettle();

    // 内容溢出 → 右箭头出现。
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    final rightArrow = find
        .ancestor(
          of: find.byIcon(Icons.chevron_right),
          matching: find.byType(GestureDetector),
        )
        .first;
    final detector = tester.widget<GestureDetector>(rightArrow);
    expect(detector.onLongPressEnd, isNotNull);

    // 直接驱动长按结束回调体。
    detector.onLongPressEnd!(
      const LongPressEndDetails(
        globalPosition: Offset.zero,
        localPosition: Offset.zero,
        velocity: Velocity.zero,
      ),
    );
    await tester.pump();

    // 顺带把长按开始/取消也走一遍（同一侧箭头）。
    detector.onLongPressStart?.call(
      const LongPressStartDetails(globalPosition: Offset.zero),
    );
    await tester.pump(const Duration(milliseconds: 10));
    detector.onLongPressCancel?.call();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
