// b38c3 —— player_scrubber.dart 剩余可达分支补测（Route C）。
//
// 单点缺口：line 202 `onDecrease: canDecrease ? () => _adjust(-1) : null`。
// 姊妹行 201（onIncrease）已被 mini_player_cov 用例通过「语义 increase 动作」点亮，
// 但 decrease 侧从未被任何用例触发过（现有 player_scrubber_test 只用
// `hasAction` 检查过存在性，没有真的 performAction）。
//
// 这里挂一个 value 落在 (min,max) 区间的 MusicFlowPlayerScrubber（onChanged 非空
// 即 enabled），直接派发 SemanticsAction.decrease。
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/player_scrubber.dart';

void main() {
  testWidgets('语义 decrease → onDecrease 闭包体执行（line 202）', (tester) async {
    final changed = <double>[];
    final starts = <double>[];
    final ends = <double>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: MusicFlowPlayerScrubber(
                value: 50,
                min: 0,
                max: 100,
                semanticLabel: 'b38c3-scrubber',
                onChanged: changed.add,
                onChangeStart: starts.add,
                onChangeEnd: ends.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final handle = tester.ensureSemantics();

    final node = tester.getSemantics(find.byType(MusicFlowPlayerScrubber));
    expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);

    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.decrease,
    );
    await tester.pump();

    // step = (max - min) / 20 = 5；decrease → 50 - 5 = 45。
    expect(changed, <double>[45]);
    expect(starts, <double>[50]);
    expect(ends, <double>[45]);
    expect(tester.takeException(), isNull);

    handle.dispose();
  });
}
