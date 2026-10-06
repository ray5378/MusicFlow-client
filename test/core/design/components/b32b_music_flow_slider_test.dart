// batch32 B 路 —— `lib/core/design/components/music_flow_slider.dart` 补测。
//
// 基线覆盖率 0%（纯自绘滑条，从未在测试里装配过）。打点：
//   * 手势路径：onTapDown 命中定位（onTapUp → onChangeEnd）、水平拖拽
//     （onHorizontalDragStart/Update/End）；
//   * RTL：localPosition 镜像（local = width - dx）；
//   * Semantics：onIncrease/onDecrease 按 step = (max-min)/20 步进并 clamp；
//   * 禁用态：onChanged == null 时手势/语义动作全部短路；
//   * 视觉：active/secondary 进度条宽度因子；semanticValue 透传。
//
// 该滑条是 StatelessWidget，回调后由宿主 StatefulWidget 持值重建
// （真实场景即如此：父组件 setState 回写 value）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_slider.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';

/// 宿主：持值 + 记录回调，模拟真实父组件「回调里 setState 回写」。
class _SliderHost extends StatefulWidget {
  const _SliderHost({
    this.onChange, // ignore: unused_element_parameter
    this.onChangeStart,
    this.onChangeEnd,
    this.initialValue = 0,
    this.secondaryValue,
    this.semanticValue,
    this.enabled = true,
  });

  final ValueChanged<double>? onChange;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double initialValue;
  final double? secondaryValue;
  final String? semanticValue;
  final bool enabled;

  @override
  State<_SliderHost> createState() => _SliderHostState();
}

class _SliderHostState extends State<_SliderHost> {
  late double value = widget.initialValue;

  @override
  Widget build(BuildContext context) {
    return MusicFlowSlider(
      value: value,
      min: 0,
      max: 100,
      semanticLabel: '音量',
      semanticValue: widget.semanticValue,
      secondaryValue: widget.secondaryValue,
      onChanged: widget.enabled
          ? (v) {
              widget.onChange?.call(v);
              setState(() => value = v);
            }
          : null,
      onChangeStart: widget.onChangeStart,
      onChangeEnd: widget.onChangeEnd,
    );
  }
}

Widget _wrap(Widget child, {TextDirection direction = TextDirection.ltr}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: Center(child: SizedBox(width: 300, child: child)),
      ),
    ),
  );
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder outerSemantics() => find.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.label == '音量',
    );

void main() {
  group('music_flow_slider · 点击定位', () {
    testWidgets('onTapDown 命中中线 -> onChanged 约 50，onTapUp 触发 onChangeEnd', (
      WidgetTester tester,
    ) async {
      final starts = <double>[];
      final ends = <double>[];
      await tester.pumpWidget(
        _wrap(
          _SliderHost(
            onChangeStart: starts.add,
            onChangeEnd: ends.add,
          ),
        ),
      );
      await settle(tester);

      final rect = tester.getRect(find.byType(MusicFlowSlider));
      final gesture = await tester.startGesture(rect.center);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(rect.width, 300);
      expect(starts, <double>[0], reason: 'onChangeStart 带旧值 0');
      expect(ends, hasLength(1), reason: 'onTapUp -> onChangeEnd');
      // travel = 300 - 22 = 278；中心 dx=150 -> (150-11)/278 ≈ 0.5
      expect(tester.state<_SliderHostState>(find.byType(_SliderHost)).value,
          closeTo(50, 1));
    });

    testWidgets('点击左端 -> clamp 到 min，点击右端 -> clamp 到 max', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_wrap(const _SliderHost(initialValue: 50)));
      await settle(tester);

      final rect = tester.getRect(find.byType(MusicFlowSlider));
      await tester.tapAt(rect.centerLeft + const Offset(2, 0));
      await tester.pump();
      expect(
        tester.state<_SliderHostState>(find.byType(_SliderHost)).value,
        0,
        reason: 'dx 远小于 thumbSize/2 -> 进度 clamp 到 0',
      );

      await tester.tapAt(rect.centerRight - const Offset(2, 0));
      await tester.pump();
      expect(
        tester.state<_SliderHostState>(find.byType(_SliderHost)).value,
        100,
        reason: 'dx 超出 travel -> 进度 clamp 到 1',
      );
    });
  });

  group('music_flow_slider · 拖拽', () {
    testWidgets('从左端拖到中部 -> onChanged 递增序列 + onChangeEnd 收尾', (
      WidgetTester tester,
    ) async {
      final ends = <double>[];
      await tester.pumpWidget(
        _wrap(_SliderHost(initialValue: 0, onChangeEnd: ends.add)),
      );
      await settle(tester);

      final rect = tester.getRect(find.byType(MusicFlowSlider));
      final gesture = await tester.startGesture(rect.centerLeft);
      await tester.pump();
      await gesture.moveBy(const Offset(139, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(1, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final state = tester.state<_SliderHostState>(find.byType(_SliderHost));
      expect(state.value, closeTo(46.4, 1),
          reason: '累计移动 140px -> (140-11)/278 ≈ 0.464');
      expect(ends, hasLength(1));
      expect(ends.single, closeTo(46.4, 1));
    });

    testWidgets('RTL 下点击同一位置取镜像值', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const _SliderHost(initialValue: 0),
          direction: TextDirection.rtl,
        ),
      );
      await settle(tester);

      final rect = tester.getRect(find.byType(MusicFlowSlider));
      // dx=41 -> rtl: local = 300-41 = 259 -> (259-11)/278 ≈ 0.892
      await tester.tapAt(rect.centerLeft + const Offset(41, 0));
      await tester.pump();

      expect(
        tester.state<_SliderHostState>(find.byType(_SliderHost)).value,
        closeTo(89.2, 2),
        reason: 'RTL 镜像：local = width - dx',
      );
    });
  });

  group('music_flow_slider · Semantics 步进', () {
    testWidgets('onIncrease/onDecrease 按 (max-min)/20 步进并 clamp', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const _SliderHost(initialValue: 50)),
      );
      await settle(tester);

      final sem = tester.widget<Semantics>(outerSemantics());
      expect(sem.properties.slider, isTrue);
      expect(sem.properties.label, '音量');
      expect(sem.properties.value, '50');
      expect(sem.properties.increasedValue, '55',
          reason: 'step = 100/20 = 5');
      expect(sem.properties.decreasedValue, '45');

      sem.properties.onIncrease!();
      await tester.pump();
      expect(
        tester.state<_SliderHostState>(find.byType(_SliderHost)).value,
        55,
      );

      // pump 后重新取 Semantics：闭包捕获的是重建后的最新 value。
      tester
          .widget<Semantics>(outerSemantics())
          .properties
          .onDecrease!();
      await tester.pump();
      expect(
        tester.state<_SliderHostState>(find.byType(_SliderHost)).value,
        50,
      );
    });

    testWidgets('value 已在 max -> onIncrease clamp 到 max', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const _SliderHost(initialValue: 100)),
      );
      await settle(tester);

      final sem = tester.widget<Semantics>(outerSemantics());
      expect(sem.properties.increasedValue, '100',
          reason: '(100+5).clamp(0,100) = 100');
      sem.properties.onIncrease!();
      await tester.pump();
      expect(
        tester.state<_SliderHostState>(find.byType(_SliderHost)).value,
        100,
      );
    });

    testWidgets('semanticValue 非空时覆盖默认 value 文案', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const _SliderHost(initialValue: 40, semanticValue: '40%')),
      );
      await settle(tester);

      final sem = tester.widget<Semantics>(outerSemantics());
      expect(sem.properties.value, '40%');
    });
  });

  group('music_flow_slider · 禁用态与视觉', () {
    testWidgets('onChanged 为 null -> 手势不响应、语义动作不挂', (
      WidgetTester tester,
    ) async {
      final starts = <double>[];
      await tester.pumpWidget(
        _wrap(_SliderHost(enabled: false, onChangeStart: starts.add)),
      );
      await settle(tester);

      final rect = tester.getRect(find.byType(MusicFlowSlider));
      await tester.tapAt(rect.center);
      await tester.pump();

      expect(starts, isEmpty);
      final sem = tester.widget<Semantics>(outerSemantics());
      expect(sem.properties.enabled, isFalse);
      expect(sem.properties.onIncrease, isNull);
      expect(sem.properties.onDecrease, isNull);
    });

    testWidgets('active/secondary 进度条宽度因子与值成比例', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const _SliderHost(initialValue: 50, secondaryValue: 25)),
      );
      await settle(tester);

      final factors = tester
          .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .map((w) => w.widthFactor)
          .whereType<double>()
          .toList();
      expect(factors, containsAll(<double>[0.5, 0.25]));
    });

    testWidgets('构造参数 max <= min -> 触发断言', (WidgetTester tester) async {
      expect(
        () => MusicFlowSlider(
          value: 0,
          min: 1,
          max: 1,
          onChanged: (_) {},
          semanticLabel: 'x',
        ),
        throwsAssertionError,
      );
    });
  });
}
