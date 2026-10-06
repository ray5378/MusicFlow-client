// b39b —— Route B：设计层小组件剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * music_flow_surface.dart:22   MusicFlowSurface.canvas 命名构造
//   * music_flow_pressable.dart:307 键盘激活脉冲 animateTo 完成后的回弹分支
//   * music_flow_context.dart:52-55 无 MediaQuery 祖先时 reduce-motion 回退
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_pressable.dart';
import 'package:musicflow_client/core/design/components/music_flow_surface.dart';
import 'package:musicflow_client/core/design/music_flow_context.dart';

void main() {
  testWidgets('MusicFlowSurface.canvas 命名构造可渲染并取画布底色（line 22）',
      (tester) async {
    // 刻意用**非 const** 调用，让命名构造函数在运行时真正执行（const 上下文会
    // 在编译期折叠，不计入运行时覆盖）。
    final surface = MusicFlowSurface.canvas(
      key: const ValueKey<String>('canvas-surface'),
      child: const SizedBox(width: 10, height: 10),
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: surface))),
    );

    expect(find.byKey(const ValueKey<String>('canvas-surface')), findsOneWidget);
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('canvas-surface')),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, isNotNull, reason: 'canvas 档位应解析出画布底色');
    expect(decoration.borderRadius, BorderRadius.zero);
  });

  testWidgets('MusicFlowPressable 键盘激活脉冲 animateTo 完成 → 回弹（line 307）',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicFlowPressable(
            onPressed: () => tapped++,
            child: const Text('可点'),
          ),
        ),
      ),
    );

    // 直接派发 ActivateIntent（Enter/Space 的语义意图）：命中 Actions 里注册的
    // 回调 → _activatePulse() → animateTo 完成后 whenComplete 执行 line 307。
    final inkWell = find.descendant(
      of: find.byType(MusicFlowPressable),
      matching: find.byType(InkWell),
    );
    expect(inkWell, findsOneWidget);
    Actions.invoke(tester.element(inkWell), const ActivateIntent());

    // 让 _pressIn 动画跑完，触发 whenComplete 内的回弹分支。
    await tester.pumpAndSettle();

    expect(tapped, 1, reason: 'ActivateIntent 应同时触发 onPressed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('无 MediaQuery 祖先时 reduce-motion 回退到 platformDispatcher（line 52-55）',
      (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());

    // rootElement 位于 View 之上（View 才注入 MediaQuery.fromView），
    // 因此此处 maybeOf 为 null，会走 platformDispatcher 回退分支。
    final Element root = tester.binding.rootElement!;
    expect(MediaQuery.maybeOf(root), isNull,
        reason: 'rootElement 不应看到 View 注入的 MediaQuery');

    final resolved = root.musicFlowReduceMotion;
    expect(
      resolved,
      WidgetsBinding
          .instance.platformDispatcher.accessibilityFeatures.disableAnimations,
      reason: '无 MediaQuery 时应回退读 platformDispatcher 而非崩溃',
    );
  });
}
