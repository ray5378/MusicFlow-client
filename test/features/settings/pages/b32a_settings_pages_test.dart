// batch32 A 路：设置子页补测 —— 主题设置页 ThemeSettingsPage（约 406 行）、
// 音质设置页 AudioQualityPage（约 183 行）、语言设置页 LanguageSettingsPage（约 65 行）。
// 主设置页 app_settings_page 已有覆盖（app_settings_page_cov_test.dart），此处补齐
// 三个子页的渲染与交互分支。
//
// 说明：三个设置 provider（themeSettingsProvider / audioQualitySettingsProvider /
// appLanguageProvider）走真实实现 —— LocalStorage 底层是 SharedPreferences，
// 用 setMockInitialValues 提供内存版，setters 立即改 state 再异步落盘，可在
// container 上回读断言。connectivityMonitorProvider 换真实实例（不 start），
// currentNetworkTypeProvider 首帧同步 yield none。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/theme/color_scheme.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/features/settings/pages/audio_quality_page.dart';
import 'package:musicflow_client/features/settings/pages/language_settings_page.dart';
import 'package:musicflow_client/features/settings/pages/theme_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/ui/locale_provider.dart';
import 'package:musicflow_client/providers/ui/theme_provider.dart';

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

String _toHex(Color color) {
  final value = color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
  return '#${value.substring(2)}';
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

  group('主题设置页', () {
    testWidgets('初始渲染三个模式行、当前主题色与 9 个预设色、微调与恢复默认按钮', (tester) async {
      final container = await _pump(tester, const ThemeSettingsPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(ThemeSettingsPage)),
      );

      expect(find.text(loc.settings_theme_follow_system), findsOneWidget);
      expect(find.text(loc.settings_theme_light), findsOneWidget);
      expect(find.text(loc.settings_theme_dark), findsOneWidget);
      expect(find.text(loc.settings_theme_current_accent), findsOneWidget);
      expect(find.text(loc.settings_theme_fine_tune), findsOneWidget);
      expect(find.text(loc.settings_theme_reset_default), findsOneWidget);
      // UI 与 provider 状态一致：当前主题色 hex 文本 + 选中态预设色按钮。
      final seed = container.read(themeSettingsProvider).seedColor;
      expect(find.text(_toHex(seed)), findsOneWidget);
      // 9 个预设色按钮都带含 #RRGGBB 的语义标签。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is MusicFlowPressable &&
              w.semanticLabel != null &&
              RegExp(r'#[0-9A-F]{6}').hasMatch(w.semanticLabel!),
        ),
        findsNWidgets(9),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「深色」切换 ThemeMode.dark 并持久选中', (tester) async {
      final container = await _pump(tester, const ThemeSettingsPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(ThemeSettingsPage)),
      );

      await tester.tap(find.text(loc.settings_theme_dark));
      await _settle(tester);

      expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点非当前预设色切换主题色,hex 文本随状态更新', (tester) async {
      final container = await _pump(tester, const ThemeSettingsPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(ThemeSettingsPage)),
      );

      const picked = Color(0xFF3D7188);
      final pickedHex = _toHex(picked);
      await tester.tap(find.byWidgetPredicate(
        (w) =>
            w is MusicFlowPressable &&
            w.semanticLabel == loc.settings_theme_color(pickedHex),
      ));
      await _settle(tester);

      expect(container.read(themeSettingsProvider).seedColor, picked);
      expect(find.text(_toHex(picked)), findsOneWidget);
      // 该预设色切换为选中态文案，原默认色恢复未选中态文案。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is MusicFlowPressable &&
              w.semanticLabel == loc.settings_theme_color_selected(pickedHex),
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is MusicFlowPressable &&
              w.semanticLabel ==
                  loc.settings_theme_color_selected(
                    _toHex(AppColorScheme.defaultSeedColor),
                  ),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('改色后点「恢复默认」回到默认种子色', (tester) async {
      final container = await _pump(tester, const ThemeSettingsPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(ThemeSettingsPage)),
      );

      await tester.tap(find.byWidgetPredicate(
        (w) =>
            w is MusicFlowPressable &&
            w.semanticLabel ==
                loc.settings_theme_color(_toHex(const Color(0xFF3D7188))),
      ));
      await _settle(tester);
      expect(container.read(themeSettingsProvider).seedColor,
          const Color(0xFF3D7188));

      await tester.tap(find.text(loc.settings_theme_reset_default));
      await _settle(tester);
      expect(
        container.read(themeSettingsProvider).seedColor,
        AppColorScheme.defaultSeedColor,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('「微调」打开颜色选择器面板,取消不改色', (tester) async {
      await _pump(tester, const ThemeSettingsPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(ThemeSettingsPage)),
      );

      await tester.tap(find.text(loc.settings_theme_fine_tune));
      await _settle(tester);

      expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
      expect(find.text(loc.settings_theme_color_picker_title), findsOneWidget);
      expect(find.text(loc.settings_theme_hue), findsOneWidget);
      expect(find.text(loc.settings_theme_saturation), findsOneWidget);
      expect(find.text(loc.settings_theme_brightness), findsOneWidget);

      await tester.ensureVisible(find.text(loc.settings_cancel));
      await tester.tap(find.text(loc.settings_cancel));
      await _settle(tester, frames: 12);
      expect(find.byType(MusicFlowBottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('音质设置页', () {
    testWidgets('初始渲染策略卡与双分区音质选项(默认自动切换开启)', (tester) async {
      final container = await _pump(tester, const AudioQualityPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(AudioQualityPage)),
      );

      expect(find.text(loc.settings_audio_current_strategy), findsOneWidget);
      expect(find.text(loc.settings_audio_network), findsOneWidget);
      expect(find.text(loc.settings_audio_network_none), findsOneWidget);
      // 默认 wifiQuality = original：生效音质 + Wi-Fi 行 + 移动行共 3 处。
      expect(find.text(AudioQualityLevel.original.displayName),
          findsNWidgets(3));
      // 自动切换默认开：Wi-Fi 与移动网络两个分区都在。
      expect(find.text(loc.settings_audio_wifi_section), findsOneWidget);
      expect(find.text(loc.settings_audio_mobile_section), findsOneWidget);
      expect(container.read(audioQualitySettingsProvider).autoSwitch, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点 Wi-Fi 音质选项更新 wifiQuality', (tester) async {
      final container = await _pump(tester, const AudioQualityPage());

      await tester.tap(find.text(AudioQualityLevel.dataSaver.displayName).first);
      await _settle(tester);

      expect(
        container.read(audioQualitySettingsProvider).wifiQuality,
        AudioQualityLevel.dataSaver,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭自动切换后移动分区隐藏、分区标题切换为全局', (tester) async {
      final container = await _pump(tester, const AudioQualityPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(AudioQualityPage)),
      );

      await tester.tap(find.text(loc.settings_audio_auto_switch));
      await _settle(tester);

      expect(container.read(audioQualitySettingsProvider).autoSwitch, isFalse);
      expect(find.text(loc.settings_audio_mobile_section), findsNothing);
      expect(find.text(loc.settings_audio_global_section), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('自动切换开启时点移动网络音质选项更新 mobileQuality', (tester) async {
      final container = await _pump(tester, const AudioQualityPage());

      // 默认 mobileQuality = standard，点击 high。
      await tester.tap(find.text(AudioQualityLevel.high.displayName).last);
      await _settle(tester);

      expect(
        container.read(audioQualitySettingsProvider).mobileQuality,
        AudioQualityLevel.high,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('语言设置页', () {
    testWidgets('初始渲染三个语言选项,默认跟随系统', (tester) async {
      final container = await _pump(tester, const LanguageSettingsPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(LanguageSettingsPage)),
      );

      expect(find.text(loc.language_follow_system), findsOneWidget);
      expect(find.text(loc.language_zh), findsOneWidget);
      expect(find.text(loc.language_en), findsOneWidget);
      expect(
        container.read(appLanguageProvider).preference,
        AppLanguagePreference.zh,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「English」切换偏好,再点「中文」切回', (tester) async {
      final container = await _pump(tester, const LanguageSettingsPage());
      final loc = AppLocalizations.of(
        tester.element(find.byType(LanguageSettingsPage)),
      );

      await tester.tap(find.text(loc.language_en));
      await _settle(tester);
      expect(
        container.read(appLanguageProvider).preference,
        AppLanguagePreference.en,
      );

      await tester.tap(find.text(loc.language_zh));
      await _settle(tester);
      expect(
        container.read(appLanguageProvider).preference,
        AppLanguagePreference.zh,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
