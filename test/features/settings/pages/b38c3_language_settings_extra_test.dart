// b38c3 —— language_settings_page.dart 剩余分支补测（Route C）。
//
// 该页三行「跟随系统 / 中文 / English」中，只有「跟随系统」行的 onPressed 闭包体
// （line 41 `notifier.setPreference(AppLanguagePreference.system)`）从未被执行：
// 既有用例默认语言就是 zh，另外两行（zh/en）被点过，system 那行没人点。
//
// 不 seed prefs：LocalStorage.getAppLanguage() 缺省返回 'zh'，因此初始偏好即 zh，
// 点「跟随系统」能真正走 setPreference 的「值变了」分支。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/pages/language_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('点「跟随系统」→ 语言偏好切到 system', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    late AppLocalizations loc;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) {
            loc = AppLocalizations.of(context);
            return child!;
          },
          home: const LanguageSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 缺省为 zh（getAppLanguage 无值回退 'zh'）。
    expect(
      container.read(appLanguageProvider).preference,
      AppLanguagePreference.zh,
    );

    await tester.tap(find.text(loc.language_follow_system));
    await tester.pumpAndSettle();

    expect(
      container.read(appLanguageProvider).preference,
      AppLanguagePreference.system,
    );
    expect(tester.takeException(), isNull);
  });
}
