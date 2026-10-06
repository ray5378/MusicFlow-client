// batch40 E3 补测：D-052 修复锁定用例。
//
// sleep_timer_sheet 的步进 Row 已用 FittedBox(scaleDown) 包裹，
// 窄视口下 Dialog 压缩宽度不再 RenderFlex overflow（修复前溢出约 6.8px）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/sleep_timer_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

late Future<dynamic> dialogResult;

/// 窄视口打开 sheet：容器宽 [sheetWidth] 小于步进 Row 固有宽度。
Future<AppLocalizations> _openNarrow(
  WidgetTester tester, {
  required double sheetWidth,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(sheetWidth, 1400);
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
                      width: sheetWidth,
                      child: const SleepTimerSheet(
                        hasExisting: false,
                        initialMinutes: 0,
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
  // 有界 pump：允许渲染多帧，逐帧吸收一次异常。
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 33));
  }
  return AppLocalizations.of(tester.element(find.byType(SleepTimerSheet)));
}

void main() {
  for (final width in <double>[260, 246, 240, 230, 220]) {
    testWidgets('窄视口(sheetWidth=' + width.toString() + ')步进 Row 无溢出(D-052)',
        (tester) async {
      final loc = await _openNarrow(tester, sheetWidth: width);

      expect(find.text(loc.player_sleep_timer_dialog_title), findsOneWidget,
          reason: 'sheet 正常渲染');
      // 修复前：步进 Row 在窄视口溢出约 6.8px（RenderFlex overflow 告警）。
      expect(tester.takeException(), isNull,
          reason: '[D-052 已修复] 窄视口下步进 Row 不再 RenderFlex overflow');
    });
  }
}
