// batch35 C 路 —— `lib/features/player/widgets/player_hero_helpers.dart` 补测。
//
// 覆盖点（Hero 飞行动画本身不驱动，只测纯函数与 shuttle builder 的装配分支）：
//   * playerLinearRectTween / playerCoverRectTween 纯函数（null → Rect.zero、
//     封面用 MaterialRectCenterArcTween）；
//   * playerTextFlightShuttleBuilder：
//       - reduceMotion（disableAnimations）→ push 返回 toChild / pop 返回 fromChild；
//       - 一侧无 Text（或 Text.data 为 null）→ 兜底 toChild/fromChild；
//       - 文本互为前后缀 → 单文本样式插值：progress<0.52 显示 from 文本，
//         ≥0.52 显示 to 文本；字号线性插值；对齐从源端过渡到目标端；
//       - interpunct/中点归一化让 '歌手' 匹配 '歌手 · 专辑'；
//       - 深层子树遍历 Material/Padding/Align/Center/SizedBox。
//
// 踩坑记录：
// #H1 shuttle builder 的 from/to HeroContext 需要 `context.widget is Hero`——
//     测试里真挂两个 Hero，用 Key 从 element 树取 context。
// #H2 动画进度用 AnimationController(vsync: tester) 直接设 value + pump，
//     不需要真的发起 Hero flight。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';

late BuildContext flightContext;
late BuildContext fromHeroContext;
late BuildContext toHeroContext;

Widget _heroHost(Widget fromChild, Widget toChild) {
  return MaterialApp(
    home: Builder(
      builder: (context) {
        flightContext = context;
        return Scaffold(
          body: Column(
            children: <Widget>[
              Hero(
                key: const ValueKey<String>('from'),
                tag: 'from',
                child: fromChild,
              ),
              Hero(
                key: const ValueKey<String>('to'),
                tag: 'to',
                child: toChild,
              ),
            ],
          ),
        );
      },
    ),
  );
}

void _grabHeroContexts(WidgetTester tester) {
  fromHeroContext = tester.element(find.byKey(const ValueKey<String>('from')));
  toHeroContext = tester.element(find.byKey(const ValueKey<String>('to')));
}

Future<void> pumpShuttle(
  WidgetTester tester,
  Animation<double> animation,
  HeroFlightDirection direction,
  Widget fromChild,
  Widget toChild, {
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    _heroHost(fromChild, toChild),
  );
  _grabHeroContexts(tester);
  final Widget shuttle = playerTextFlightShuttleBuilder(
    flightContext,
    animation,
    direction,
    fromHeroContext,
    toHeroContext,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: shuttle),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('纯函数', () {
    test('playerLinearRectTween：null 侧补 Rect.zero，可线性插值', () {
      final tween = playerLinearRectTween(null, const Rect.fromLTWH(0, 0, 10, 10));
      expect(tween.begin, Rect.zero);
      expect(tween.end, const Rect.fromLTWH(0, 0, 10, 10));
      final mid = tween.lerp(0.5)!;
      expect(mid.width, 5);
    });

    test('playerCoverRectTween：返回中心弧形 tween，null 侧补 Rect.zero', () {
      final tween = playerCoverRectTween(null, null);
      expect(tween, isA<MaterialRectCenterArcTween>());
      expect(tween.begin, Rect.zero);
      expect(tween.end, Rect.zero);
    });
  });

  group('playerTextFlightShuttleBuilder', () {
    testWidgets('reduceMotion：push 返回 toChild，pop 返回 fromChild', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await pumpShuttle(
        tester,
        controller,
        HeroFlightDirection.push,
        const Text('迷你标题'),
        const Text('全屏标题'),
        disableAnimations: true,
      );
      expect(find.text('全屏标题'), findsOneWidget, reason: 'reduceMotion push 应直接显示目标文本');

      await pumpShuttle(
        tester,
        controller,
        HeroFlightDirection.pop,
        const Text('迷你标题'),
        const Text('全屏标题'),
        disableAnimations: true,
      );
      expect(find.text('迷你标题'), findsOneWidget, reason: 'reduceMotion pop 应直接显示来源文本');
    });

    testWidgets('来源侧没有 Text → 兜底显示 toChild', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await pumpShuttle(
        tester,
        controller,
        HeroFlightDirection.push,
        const Icon(Icons.music_note),
        const Text('目标文本'),
      );
      expect(find.text('目标文本'), findsOneWidget);
    });

    testWidgets('目标侧 Text.data 为 null（Text.rich）→ push 兜底显示 toChild 富文本', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await pumpShuttle(
        tester,
        controller,
        HeroFlightDirection.push,
        const Text('来源文本'),
        Text.rich(const TextSpan(text: '富文本')),
      );
      // 插值分支要求两侧都能提取 Text；to 侧 data=null → 走兜底，
      // push 方向兜底返回 toChild（渲染为 RichText）。
      expect(find.text('来源文本'), findsNothing);
      expect(find.byType(RichText), findsOneWidget);
    });

    testWidgets('文本完全不同 → 兜底显示 toChild，不做插值', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await pumpShuttle(
        tester,
        controller,
        HeroFlightDirection.push,
        const Text('甲'),
        const Text('乙'),
      );
      expect(find.text('乙'), findsOneWidget);
      expect(find.text('甲'), findsNothing);
    });

    testWidgets('push 前缀对：progress<0.52 显示 from 文本，之后切到 to 文本', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(_heroHost(
        const Text('同一首歌'),
        const Text('同一首歌 · 专辑名'),
      ));
      _grabHeroContexts(tester);
      final Widget shuttle = playerTextFlightShuttleBuilder(
        flightContext,
        controller,
        HeroFlightDirection.push,
        fromHeroContext,
        toHeroContext,
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: shuttle)),
      );

      controller.value = 0.1;
      await tester.pump();
      expect(find.text('同一首歌'), findsOneWidget, reason: 'progress 0.1 < 0.52 应显示来源文本');

      controller.value = 0.9;
      await tester.pump();
      expect(find.text('同一首歌 · 专辑名'), findsOneWidget, reason: 'progress 0.9 ≥ 0.52 应切换到目标文本');
      expect(tester.takeException(), isNull);
    });

    testWidgets('pop 方向：progress = 1 - raw，raw=0.9 时仍显示 from 文本', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(_heroHost(
        const Text('同一首歌'),
        const Text('同一首歌 · 专辑名'),
      ));
      _grabHeroContexts(tester);
      final Widget shuttle = playerTextFlightShuttleBuilder(
        flightContext,
        controller,
        HeroFlightDirection.pop,
        fromHeroContext,
        toHeroContext,
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: shuttle)),
      );

      controller.value = 0.9; // progress = 0.1 → from
      await tester.pump();
      expect(find.text('同一首歌'), findsOneWidget);

      controller.value = 0.2; // progress = 0.8 → to
      await tester.pump();
      expect(find.text('同一首歌 · 专辑名'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('字号线性插值：progress 0.5 时 fontSize 位于两侧之间', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(_heroHost(
        const Text('同曲', style: TextStyle(fontSize: 12)),
        const Text('同曲', style: TextStyle(fontSize: 24)),
      ));
      _grabHeroContexts(tester);
      final Widget shuttle = playerTextFlightShuttleBuilder(
        flightContext,
        controller,
        HeroFlightDirection.push,
        fromHeroContext,
        toHeroContext,
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: shuttle)),
      );

      controller.value = 0.5;
      await tester.pump();
      final text = tester.widget<Text>(find.text('同曲'));
      expect(text.style?.fontSize, closeTo(18, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('interpunct 归一化：来源文本匹配目标前缀 → 走插值分支', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await pumpShuttle(
        tester,
        controller,
        HeroFlightDirection.push,
        const Text('歌手名'),
        const Text('歌手名 · 专辑名'),
      );
      controller.value = 0.9;
      await tester.pump();
      expect(find.text('歌手名 · 专辑名'), findsOneWidget, reason: '归一化后互为前后缀应走插值分支');
      expect(tester.takeException(), isNull);
    });

    testWidgets('深层子树遍历：Material/Padding/Align/Center/SizedBox 包裹的 Text 可被提取', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await pumpShuttle(
        tester,
        controller,
        HeroFlightDirection.push,
        Padding(
          padding: const EdgeInsets.all(4),
          child: Material(
            child: Align(
              child: Center(
                child: SizedBox(child: const Text('深埋文本')),
              ),
            ),
          ),
        ),
        const Text('深埋文本 · 后缀'),
      );
      controller.value = 0.1;
      await tester.pump();
      expect(find.text('深埋文本'), findsOneWidget, reason: '嵌套包裹的 Text 应被提取并走插值分支');
      expect(tester.takeException(), isNull);
    });

    testWidgets('对齐插值与属性透传：progress=1 时 Align 为目标对齐，maxLines 取目标侧', (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(_heroHost(
        const Text(
          '标题',
          textAlign: TextAlign.left,
        ),
        const Text(
          '标题 · 副标题',
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ));
      _grabHeroContexts(tester);
      final Widget shuttle = playerTextFlightShuttleBuilder(
        flightContext,
        controller,
        HeroFlightDirection.push,
        fromHeroContext,
        toHeroContext,
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: shuttle)),
      );

      controller.value = 1.0;
      await tester.pump();

      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.center, reason: '目标 textAlign=center 应映射为 Alignment.center');

      final text = tester.widget<Text>(find.text('标题 · 副标题'));
      expect(text.maxLines, 3, reason: '切到目标侧后 maxLines 透传目标 Text 属性');
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });
  });
}
