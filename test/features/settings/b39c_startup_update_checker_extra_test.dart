// b39c —— Route C 补测：`lib/features/settings/services/startup_update_checker.dart` 剩余缺口。
//
// 既有 startup_update_checker_test.dart 覆盖了成功弹窗 / 已最新 / 不支持平台。
// 这里补：
//   * 77：更新检查抛错 → 打日志、静默返回 false。
//   * 116/117/119/120：默认「系统浏览器打开链接」实现 _launchInBrowser
//     （既有用例都注入了 launcher，默认实现从未跑到）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/services/startup_update_checker.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  const hostKey = Key('b39c-startup-update-host');

  UpdateCheckResult updateResult() => const UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '3.4.29',
        latestVersion: '3.5.0',
        releaseUrl: 'https://example.test/release',
        assets: <ReleaseAsset>[
          ReleaseAsset(
            name: 'MusicFlow-v350-windows-setup.exe',
            downloadUrl: 'https://example.test/windows-setup.exe',
            size: 1024,
          ),
        ],
      );

  Widget app(Widget child) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.dark(),
      home: Scaffold(body: child),
    );
  }

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('更新检查抛错 → 静默返回 false（77）', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    await tester.pumpWidget(app(const SizedBox(key: hostKey)));

    final shown = await runStartupUpdateCheck(
      tester.element(find.byKey(hostKey)),
      checker: () async => throw StateError('offline'),
      launcher: (_) async {},
      platform: TargetPlatform.windows,
      delay: Duration.zero,
    );

    expect(shown, isFalse);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('默认 launcher 用系统浏览器打开下载链接（116/117/119/120）',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    const MethodChannel launcherChannel =
        MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final launched = <String>[];
    messenger.setMockMethodCallHandler(launcherChannel, (call) async {
      if (call.method == 'launch' || call.method == 'launchUrl') {
        final args = call.arguments;
        if (args is Map) {
          launched.add('${args['url']}');
        } else {
          launched.add('$args');
        }
        return true;
      }
      // canLaunch / canLaunchUrl 一律视为可打开。
      if (call.method == 'canLaunch' || call.method == 'canLaunchUrl') {
        return true;
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(launcherChannel, null));

    await tester.pumpWidget(app(const SizedBox(key: hostKey)));

    final shown = await runStartupUpdateCheck(
      tester.element(find.byKey(hostKey)),
      checker: () async => updateResult(),
      // 不注入 launcher ⇒ 走默认 _launchInBrowser。
      platform: TargetPlatform.windows,
      delay: Duration.zero,
    );
    await tester.pumpAndSettle();
    expect(shown, isTrue);

    await tester.tap(find.text('前往下载'));
    await tester.pumpAndSettle();

    expect(launched, isNotEmpty,
        reason: '默认 launcher 应把下载链接交给系统浏览器');
    debugDefaultTargetPlatformOverride = null;
  });
}
