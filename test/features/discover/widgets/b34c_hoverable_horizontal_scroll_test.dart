// batch34 C 路 —— `lib/features/discover/widgets/hoverable_horizontal_scroll.dart` 补测。
//
// 覆盖点：
//   * 右箭头初始可见 / 左箭头初始不可见（滚动边界计算）；
//   * MouseRegion hover → 淡入动画（FadeTransition opacity 上升）；
//   * 点击右箭头 → animateTo 前进 scrollStep，随后左箭头出现；
//   * 滚到最右 → 右箭头消失（右边界）；
//   * 长按箭头 → 持续滚动定时器推进，抬手停止；
//   * 长按取消（pointer cancel）→ 定时器停止、offset 不再变化；
//   * builder 未把 controller 传给子级滚动视图 → hasClients=false，
//     箭头永不出现（历史 bug 回归守卫，见源码类注释）。
//
// 注意：组件内有 AnimationController/Timer，一律用有界推帧，不用 pumpAndSettle
// 之外还必须保证用例结束前手势已结束（否则 hold Timer 会挂死用例）。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';

const double kViewWidth = 800;
const double kViewHeight = 120;

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder get _leftArrow => find.byIcon(Icons.chevron_left);
Finder get _rightArrow => find.byIcon(Icons.chevron_right);

/// 标准宿主：400 宽视口 + 2000 宽内容（20 个 100 宽块）。
/// builder 收到的 ScrollController 存入 [latestController] 供断言 offset
/// （builder 每次 rebuild 都会被调用，故只保留最新一个句柄）。
ScrollController? latestController;

Widget host({required Widget Function(ScrollController) builder}) {
  latestController = null;
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: kViewWidth,
          height: kViewHeight,
          child: HoverableHorizontalScroll(
            builder: (context, controller) {
              latestController = controller;
              return builder(controller);
            },
          ),
        ),
      ),
    ),
  );
}

Widget listViewBuilder(ScrollController controller) {
  return ListView.builder(
    controller: controller,
    scrollDirection: Axis.horizontal,
    itemCount: 20,
    itemExtent: 100,
    itemBuilder: (context, index) => SizedBox(
      width: 100,
      child: Text('块$index'),
    ),
  );
}

void main() {
  testWidgets('初始状态：右箭头可见、左箭头不可见', (tester) async {
    await tester.pumpWidget(
      host(builder: (c) => listViewBuilder(c)),
    );
    await settle(tester);

    expect(_rightArrow, findsOneWidget);
    expect(_leftArrow, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('鼠标悬停 → 淡入动画推进（FadeTransition opacity 上升）', (tester) async {
    await tester.pumpWidget(
      host(builder: (c) => listViewBuilder(c)),
    );
    await settle(tester);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(_rightArrow));
    await settle(tester);

    final fade = tester.widget<FadeTransition>(
      find.ancestor(
        of: _rightArrow,
        matching: find.byType(FadeTransition),
      ).first,
    );
    expect(fade.opacity.value, greaterThan(0.5), reason: '悬停后淡入应接近 1');

    await gesture.moveTo(const Offset(0, 0));
    await settle(tester);
    final fadeAfterExit = tester.widget<FadeTransition>(
      find.ancestor(
        of: _rightArrow,
        matching: find.byType(FadeTransition),
      ).first,
    );
    expect(fadeAfterExit.opacity.value, lessThan(0.5), reason: '移出后淡出');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击右箭头 → 前进 scrollStep，左箭头出现', (tester) async {
    await tester.pumpWidget(
      host(builder: (c) => listViewBuilder(c)),
    );
    await settle(tester);

    await tester.tap(_rightArrow);
    await settle(tester, frames: 16);

    // scrollStep 默认 240；直接断言组件内控制器 offset。
    expect(latestController!.offset, closeTo(240, 1));
    expect(_leftArrow, findsOneWidget, reason: '离开左边界后左箭头应出现');
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚到最右 → 右箭头消失（右边界）', (tester) async {
    await tester.pumpWidget(
      host(builder: (c) => listViewBuilder(c)),
    );
    await settle(tester);

    // 连续点右箭头到底（2000-800=1200 可滚动，240*5=1200）。
    for (var i = 0; i < 6; i++) {
      if (find.byIcon(Icons.chevron_right).evaluate().isEmpty) break;
      await tester.tap(_rightArrow);
      await settle(tester, frames: 16);
    }
    expect(_rightArrow, findsNothing, reason: '到达右边界后右箭头应消失');
    expect(_leftArrow, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按右箭头 → 持续滚动推进，抬手后停止', (tester) async {
    await tester.pumpWidget(
      host(builder: (c) => listViewBuilder(c)),
    );
    await settle(tester);

    final gesture = await tester.startGesture(tester.getCenter(_rightArrow));
    // 越过长按阈值，触发 onLongPressStart → 定时器每 80ms 跳 100。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));

    final heldOffset = latestController!.offset;
    expect(heldOffset, greaterThan(240), reason: '长按应持续推进超过单步 240');

    await gesture.up();
    await settle(tester, frames: 6);
    final afterUp = latestController!.offset;
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      latestController!.offset,
      closeTo(afterUp, 1),
      reason: '抬手后持续滚动应停止',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按被取消 → 定时器停止，offset 不再变化', (tester) async {
    await tester.pumpWidget(
      host(builder: (c) => listViewBuilder(c)),
    );
    await settle(tester);

    final gesture = await tester.startGesture(tester.getCenter(_rightArrow));
    await tester.pump(const Duration(milliseconds: 600));
    // 指针取消 → onLongPressCancel → _stopHoldScroll。
    await gesture.cancel();
    await settle(tester, frames: 4);

    final before = latestController!.offset;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      latestController!.offset,
      closeTo(before, 1),
      reason: '取消后定时器应已停止',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('builder 未把 controller 传给滚动视图 → 箭头永不出现（回归守卫）',
      (tester) async {
    await tester.pumpWidget(
      host(
        builder: (_) => ListView.builder(
          // 故意不接 controller：父级 ScrollController 无 client。
          scrollDirection: Axis.horizontal,
          itemCount: 20,
          itemExtent: 100,
          itemBuilder: (context, index) => Text('游离块$index'),
        ),
      ),
    );
    await settle(tester);

    expect(_rightArrow, findsNothing, reason: 'hasClients=false 时不应显示箭头');
    expect(_leftArrow, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容不超过视口 → 两侧箭头都不出现', (tester) async {
    await tester.pumpWidget(
      host(
        builder: (c) => ListView.builder(
          controller: c,
          scrollDirection: Axis.horizontal,
          itemCount: 4,
          itemExtent: 100,
          itemBuilder: (context, index) => Text('短块$index'),
        ),
      ),
    );
    await settle(tester);

    expect(_rightArrow, findsNothing);
    expect(_leftArrow, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义 scrollStep 生效', (tester) async {
    ScrollController? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: kViewWidth,
              height: kViewHeight,
              child: HoverableHorizontalScroll(
                scrollStep: 600,
                builder: (context, controller) {
                  captured = controller;
                  return listViewBuilder(controller);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    await tester.tap(_rightArrow);
    await settle(tester, frames: 16);

    expect(captured!.offset, closeTo(600, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('_ArrowBtn 悬停高亮：hover 后容器重建为高亮底色', (tester) async {
    await tester.pumpWidget(
      host(builder: (c) => listViewBuilder(c)),
    );
    await settle(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_rightArrow));
    await settle(tester, frames: 12);

    final container = tester.widget<AnimatedContainer>(
      find.ancestor(of: _rightArrow, matching: find.byType(AnimatedContainer)),
    );
    final decoration = container.decoration as BoxDecoration;
    expect(
      ((decoration.color!.a) * 255.0).round(),
      greaterThan(140),
      reason: '悬停后底色加深（alpha 170 vs 110）',
    );
    await mouse.moveTo(const Offset(0, 0));
    await settle(tester, frames: 12);
    expect(tester.takeException(), isNull);
  });
}
