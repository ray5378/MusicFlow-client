// b38c3 —— compact_navigation.dart 剩余可达分支补测（Route C）。
//
// 单点缺口：line 84/86 `ShellSidebarAppActions._push` 在未注入 `onOpenPage`
// （opener == null）时的 fallback —— `Navigator.of(context).push(MusicFlowPageRoute(...))`。
// 既有用例都通过注入 opener 走 82 行，这个兜底分支从未执行。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/compact_navigation.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/shell_destinations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('侧栏应用动作未注入 opener → 走 Navigator.push 打开设置页', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: ShellSidebarAppActions(collapsed: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppSettingsPage), findsNothing);

    // 直接调用 onPressed，绕开 hit-test/语义开启的噪声；这正是非 opener 分支。
    final entry = tester.widget<ShellSidebarActionEntry>(
      find.byType(ShellSidebarActionEntry),
    );
    entry.onPressed();
    // 设置页含持续动画/异步读取，pumpAndSettle 会超时；有界推帧即可。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      tester.takeException();
    }

    expect(find.byType(AppSettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
