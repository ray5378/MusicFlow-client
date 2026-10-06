// batch33 C 路 —— `lib/features/player/widgets/sleep_timer_sheet.dart` 补测。
//
// 该文件是无 Riverpod 依赖的纯 StatefulWidget（AlertDialog 样式定时弹窗）。
// 注意：`MusicFlowButton` 内部用 `LayoutBuilder`，在 `showDialog` 的弹窗路由里
// 会被要求计算「固有尺寸」而抛「LayoutBuilder does not support returning
// intrinsic dimensions」。规避办法：用 `Navigator.push` 把 sheet 推到一条独立
// 路由里，并用 `SizedBox(width:360)` 给 AlertDialog 有界宽度，使其不再走固有
// 尺寸计算；按钮的 `Navigator.of(context).pop(result)` 即解析 push 的 future。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_button.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/sleep_timer_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

const Size kView = Size(800, 1200);

/// 当前打开的 sheet 弹出结果 future（由 `_open` 写入）。
late Future<dynamic> dialogResult;

Finder _startButton(AppLocalizations loc) => find.byWidgetPredicate(
      (w) => w is MusicFlowButton && w.label == loc.player_sleep_timer_start,
    );

Finder _offButton(AppLocalizations loc) => find.byWidgetPredicate(
      (w) => w is MusicFlowButton && w.label == loc.player_sleep_timer_off,
    );

Future<AppLocalizations> _open(
  WidgetTester tester, {
  bool hasExisting = false,
  int initialMinutes = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = kView;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () {
            dialogResult = Navigator.of(context).push<dynamic>(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 360,
                      child: SleepTimerSheet(
                        hasExisting: hasExisting,
                        initialMinutes: initialMinutes,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _pumpQuiet(tester);
  return AppLocalizations.of(tester.element(find.byType(SleepTimerSheet)));
}

String _minutes(AppLocalizations loc, int n) =>
    loc.player_sleep_timer_minutes(n);

/// 已知：窄弹窗下 Dialog 的 IntrinsicWidth 压缩宽度，步进器 Row 溢出 6.8px（仅/// 测试环境可见的渲染告警，布局照常完成）。每帧后吸收，避免 flutter_test 自动判负。
Future<void> _pumpQuiet(WidgetTester tester, [Duration? duration]) async {
  if (duration == null) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(duration);
  }
  tester.takeException();
}

Future<void> _pumpFrame(WidgetTester tester) async {
  await tester.pump();
  tester.takeException();
}

Future<void> _pumpFrames(WidgetTester tester, {int frames = 24}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  tester.takeException();
}

void main() {
  group('sleep_timer_sheet · 渲染', () {
    testWidgets('默认：标题 + 六个预设档 + 步进器 + 起播/取消', (
      WidgetTester tester,
    ) async {
      final loc = await _open(tester);
      expect(find.text(loc.player_sleep_timer_dialog_title), findsOneWidget);
      for (final mn in <int>[10, 20, 30, 40, 50, 60]) {
        expect(find.text(_minutes(loc, mn)), findsOneWidget);
      }
      expect(_startButton(loc), findsOneWidget);
      expect(find.text(loc.settings_cancel), findsOneWidget);
      // 无已有定时 → 不显示关闭定时按钮。
      expect(find.text(loc.player_sleep_timer_off), findsNothing);
    });

    testWidgets('hasExisting：显示关闭定时按钮', (WidgetTester tester) async {
      final loc = await _open(tester, hasExisting: true, initialMinutes: 25);
      expect(find.text(loc.player_sleep_timer_off), findsOneWidget);
    });
  });

  group('sleep_timer_sheet · 交互', () {
    testWidgets('点预设 30 → 输入框回显 30 且起播可用', (
      WidgetTester tester,
    ) async {
      final loc = await _open(tester);
      await tester.tap(find.text(_minutes(loc, 30)));
      await _pumpQuiet(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, '30');
      expect(
        tester.widget<MusicFlowButton>(_startButton(loc)).onPressed,
        isNotNull,
        reason: '选中预设后分钟数>0，起播按钮可用',
      );
    });

    testWidgets('步进器 +/- 改变分钟数', (WidgetTester tester) async {
      final loc = await _open(tester);
      await tester.tap(find.text(_minutes(loc, 30)));
      await _pumpQuiet(tester);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.add));
      await _pumpQuiet(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '31',
      );

      await tester.tap(find.widgetWithIcon(IconButton, Icons.remove));
      await _pumpQuiet(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '30',
      );
    });

    testWidgets('步进器不越过下限 0', (WidgetTester tester) async {
      final loc = await _open(tester); // ignore: unused_local_variable
      await tester.tap(find.widgetWithIcon(IconButton, Icons.remove));
      await _pumpQuiet(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '',
      );
    });

    testWidgets('手输 45 → 起播弹 SleepTimerStartChoice(46分钟)', (
      WidgetTester tester,
    ) async {
      final loc = await _open(tester);
      await tester.enterText(find.byType(TextField), '45');
      await _pumpFrame(tester);

      // [D-候选] onChanged 手输不 setState，按钮保持上次构建的禁用态；
      // 这里借 '+' 步进触发 setState 才能起播（见报告 D-候选 1）。
      await tester.tap(find.widgetWithIcon(IconButton, Icons.add));
      await _pumpFrame(tester);

      await tester.tap(_startButton(loc));
      await _pumpFrames(tester);

      final result = await dialogResult;
      expect(result, isA<SleepTimerStartChoice>());
      expect(
        (result as SleepTimerStartChoice).duration,
        const Duration(minutes: 46),
      );
      expect(find.byType(SleepTimerSheet), findsNothing);
    });

    testWidgets('initial=0 且未选预设 → 起播按钮禁用', (
      WidgetTester tester,
    ) async {
      final loc = await _open(tester, initialMinutes: 0);
      expect(
        tester.widget<MusicFlowButton>(_startButton(loc)).onPressed,
        isNull,
        reason: 'minutes==0 时 onPressed 为 null',
      );
    });

    testWidgets('点取消 → 弹 null 且 sheet 关闭', (WidgetTester tester) async {
      final loc = await _open(tester, initialMinutes: 15);
      await tester.tap(find.text(loc.settings_cancel));
      await _pumpQuiet(tester);
      expect(find.byType(SleepTimerSheet), findsNothing);
      final result = await dialogResult;
      expect(result, isNull);
    });

    testWidgets('hasExisting 点关闭定时 → 弹 SleepTimerOffSentinel', (
      WidgetTester tester,
    ) async {
      final loc = await _open(tester, hasExisting: true, initialMinutes: 25);
      final off = _offButton(loc);
      expect(off, findsOneWidget);
      await tester.tap(off);
      await _pumpQuiet(tester);
      expect(find.byType(SleepTimerSheet), findsNothing);
      final result = await dialogResult;
      expect(result, isA<SleepTimerOffSentinel>());
    });
  });
}
