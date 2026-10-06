// b38c3 —— Route C 补测：`lib/features/settings/pages/theme_settings_page.dart`
// 剩余缺口（既有 b32a_settings_pages_test 已覆盖「深色 / 预设色 / 恢复默认 /
// 打开取色面板后取消」）。
//
// 覆盖点：
//   * 41：点「跟随系统」→ setThemeMode(ThemeMode.system)。
//   * 48：点「浅色」→ setThemeMode(ThemeMode.light)。
//   * 225/226、235/236、245/246：取色面板三个滑块的 onChanged（色相/饱和度/明度）。
//   * 261：取色面板「应用」按钮 → pop(color)。
//   * 149：面板返回非 null 颜色 → setSeedColor(selected)。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/pages/theme_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/ui/theme_provider.dart';

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget page,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 1400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final container = ProviderContainer(
    overrides: <Override>[
      connectivityMonitorProvider.overrideWithValue(
        ConnectivityMonitor(AddressPool(Dio())),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.light(),
        home: Scaffold(body: page),
      ),
    ),
  );
  await _settle(tester);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点「跟随系统」→ ThemeMode.system（41）', (tester) async {
    final container = await _pump(tester, const ThemeSettingsPage());
    final loc =
        AppLocalizations.of(tester.element(find.byType(ThemeSettingsPage)));

    // 先把模式切到浅色，再点跟随系统，确保确实发生状态翻转。
    await tester.tap(find.text(loc.settings_theme_light));
    await _settle(tester);
    expect(container.read(themeSettingsProvider).mode, ThemeMode.light);

    await tester.tap(find.text(loc.settings_theme_follow_system));
    await _settle(tester);
    expect(container.read(themeSettingsProvider).mode, ThemeMode.system);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点「浅色」→ ThemeMode.light（48）', (tester) async {
    final container = await _pump(tester, const ThemeSettingsPage());
    final loc =
        AppLocalizations.of(tester.element(find.byType(ThemeSettingsPage)));

    await tester.tap(find.text(loc.settings_theme_light));
    await _settle(tester);
    expect(container.read(themeSettingsProvider).mode, ThemeMode.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取色面板：拖动三个滑块并「应用」回写主题色（149/225/235/245/261）',
      (tester) async {
    final container = await _pump(tester, const ThemeSettingsPage());
    final loc =
        AppLocalizations.of(tester.element(find.byType(ThemeSettingsPage)));

    final before = container.read(themeSettingsProvider).seedColor;

    await tester.tap(find.text(loc.settings_theme_fine_tune));
    await _settle(tester);
    expect(find.byType(MusicFlowSlider), findsNWidgets(3));

    // 在滑块轨道 15% 处 tapDown → onChanged 以新比例回写 _hsv（色相/饱和度/明度）。
    for (final i in <int>[0, 1, 2]) {
      final rect = tester.getRect(find.byType(MusicFlowSlider).at(i));
      await tester.tapAt(
        Offset(rect.left + rect.width * 0.15, rect.center.dy),
      );
      await _settle(tester, frames: 3);
    }
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text(loc.settings_theme_apply));
    await tester.tap(find.text(loc.settings_theme_apply));
    await _settle(tester, frames: 12);

    expect(find.byType(MusicFlowBottomSheet), findsNothing);
    expect(container.read(themeSettingsProvider).seedColor, isNot(before),
        reason: '应用取色面板选中的颜色后应回写 seedColor');
    expect(tester.takeException(), isNull);
  });
}
