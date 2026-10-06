import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_progress_bar.dart';

/// 覆盖 MusicFlowProgressBar：归一化/钳制 + 语义值与自定义属性渲染。
/// 设计 token 在无 Theme 扩展时回退到默认值，故用裸 MaterialApp 即可渲染。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required double value,
    Color? color,
    Color? trackColor,
    double height = 4,
    String? semanticLabel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicFlowProgressBar(
            value: value,
            color: color,
            trackColor: trackColor,
            height: height,
            semanticLabel: semanticLabel,
          ),
        ),
      ),
    );
  }

  Semantics findSemantics(WidgetTester tester) {
    return tester.widget<Semantics>(
      find.descendant(
        of: find.byType(MusicFlowProgressBar),
        matching: find.byType(Semantics),
      ),
    );
  }

  testWidgets('value=0.5 渲染为 50% 语义值', (tester) async {
    await pump(tester, value: 0.5);
    expect(findSemantics(tester).properties.value, '50%');
  });

  testWidgets('value>1 被钳制为 100%', (tester) async {
    await pump(tester, value: 2.0);
    expect(findSemantics(tester).properties.value, '100%');
  });

  testWidgets('value<0 被钳制为 0%', (tester) async {
    await pump(tester, value: -0.5);
    expect(findSemantics(tester).properties.value, '0%');
  });

  testWidgets('value 为非有限值(NaN)回退为 0%', (tester) async {
    await pump(tester, value: double.nan);
    expect(findSemantics(tester).properties.value, '0%');
  });

  testWidgets('提供 semanticLabel 时设置语义 label', (tester) async {
    await pump(tester, value: 0.3, semanticLabel: '播放进度');
    final s = findSemantics(tester);
    expect(s.properties.label, '播放进度');
    expect(s.properties.value, '30%');
  });

  testWidgets('自定义 height/color/trackColor 可正常渲染', (tester) async {
    await pump(
      tester,
      value: 0.75,
      color: Colors.red,
      trackColor: Colors.grey,
      height: 12,
    );
    final sized = tester.widget<SizedBox>(
      find.descendant(
        of: find.byType(MusicFlowProgressBar),
        matching: find.byType(SizedBox),
      ),
    );
    expect(sized.height, 12);
    expect(findSemantics(tester).properties.value, '75%');
  });

  testWidgets('进度条的 AnimatedFractionallySizedBox widthFactor 反映归一化值',
      (tester) async {
    await pump(tester, value: 0.4);
    final af = tester.widget<AnimatedFractionallySizedBox>(
      find.descendant(
        of: find.byType(MusicFlowProgressBar),
        matching: find.byType(AnimatedFractionallySizedBox),
      ),
    );
    expect(af.widthFactor, 0.4);
  });
}
