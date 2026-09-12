import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/player_scrubber.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps a 48dp target and expands only while seeking', (
    tester,
  ) async {
    double value = 25;
    var startCount = 0;
    var endCount = 0;
    var cancelCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              body: Center(
                child: SizedBox(
                  width: 240,
                  child: MusicFlowPlayerScrubber(
                    value: value,
                    min: 0,
                    max: 100,
                    secondaryValue: 60,
                    semanticLabel: '播放进度',
                    semanticValue: '${value.round()}%',
                    onChangeStart: (_) => startCount += 1,
                    onChangeEnd: (_) => endCount += 1,
                    onChangeCancel: (_) => cancelCount += 1,
                    onChanged: (next) => setState(() => value = next),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    final scrubber = find.byKey(const ValueKey<String>('musicflow-player-scrubber'));
    expect(tester.getSize(scrubber).height, 48);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('musicflow-player-scrubber-thumb')),
          )
          .width,
      6,
    );

    final gesture = await tester.startGesture(tester.getCenter(scrubber));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('musicflow-player-scrubber-thumb')),
          )
          .width,
      14,
    );

    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(value, greaterThan(50));
    expect((startCount, endCount, cancelCount), (1, 1, 0));
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('musicflow-player-scrubber-thumb')),
          )
          .width,
      6,
    );
  });

  testWidgets('tap and canceled gestures close exactly one seek session', (
    tester,
  ) async {
    double value = 20;
    var startCount = 0;
    var endCount = 0;
    var cancelCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 240,
                child: MusicFlowPlayerScrubber(
                  value: value,
                  min: 0,
                  max: 100,
                  semanticLabel: '播放进度',
                  onChangeStart: (_) => startCount += 1,
                  onChangeEnd: (_) => endCount += 1,
                  onChangeCancel: (_) => cancelCount += 1,
                  onChanged: (next) => setState(() => value = next),
                ),
              ),
            );
          },
        ),
      ),
    );

    final scrubber = find.byKey(const ValueKey<String>('musicflow-player-scrubber'));
    await tester.tapAt(tester.getCenter(scrubber));
    await tester.pump();
    expect((startCount, endCount, cancelCount), (1, 1, 0));

    final canceledGesture = await tester.startGesture(
      tester.getCenter(scrubber),
    );
    await tester.pumpAndSettle();
    await canceledGesture.cancel();
    await tester.pump();

    expect((startCount, endCount, cancelCount), (2, 1, 1));
  });

  testWidgets('mouse press-and-hold still completes as a seek (regression)', (
    tester,
    ) async {
    // 回归:按住 >= kPressTimeout(100ms) 时,drag 识别器在竞技场中败给 tap,
    // Flutter 会回调 onHorizontalDragCancel。旧实现把它无条件接到 _cancel,
    // 杀死进行中的 tap 会话 → onChangeEnd 不触发 → 点击进度条无法跳转
    // (Windows 鼠标长按必现)。修复后必须以 onChangeEnd 收尾。
    double value = 20;
    var startCount = 0;
    var endCount = 0;
    var cancelCount = 0;
    double? endedValue;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 400,
                child: MusicFlowPlayerScrubber(
                  value: value,
                  min: 0,
                  max: 100,
                  semanticLabel: '播放进度',
                  onChangeStart: (_) => startCount += 1,
                  onChangeEnd: (next) {
                    endCount += 1;
                    endedValue = next;
                  },
                  onChangeCancel: (_) => cancelCount += 1,
                  onChanged: (next) => setState(() => value = next),
                ),
              ),
            );
          },
        ),
      ),
    );

    final scrubber = find.byKey(
      const ValueKey<String>('musicflow-player-scrubber'),
    );
    // 按住 700ms 不动再松开(真实鼠标长按节奏,90% 处)。
    final gesture = await tester.startGesture(
      tester.getCenter(scrubber) + const Offset(160, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pump();

    expect((startCount, endCount, cancelCount), (1, 1, 0));
    expect(endedValue, closeTo(90, 6));
  });

  testWidgets('exposes adjustable slider semantics', (tester) async {
    double value = 50;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) {
            return MusicFlowPlayerScrubber(
              value: value,
              min: 0,
              max: 100,
              semanticLabel: '播放进度',
              semanticValue: '${value.round()}%',
              semanticStep: 10,
              semanticValueFormatter: (next) => '${next.round()}%',
              onChanged: (next) => setState(() => value = next),
            );
          },
        ),
      ),
    );

    final finder = find.bySemanticsLabel('播放进度');
    final semantics = tester.getSemantics(finder).getSemanticsData();
    expect(semantics.hasAction(SemanticsAction.increase), isTrue);
    expect(semantics.hasAction(SemanticsAction.decrease), isTrue);
    expect(semantics.increasedValue, '60%');
    expect(semantics.decreasedValue, '40%');
    tester.semantics.increase(find.semantics.byLabel('播放进度'));
    await tester.pump();
    expect(value, 60);
    expect(tester.getSemantics(finder).getSemanticsData().value, '60%');
  });
}
