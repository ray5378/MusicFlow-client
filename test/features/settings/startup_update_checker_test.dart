import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/services/startup_update_checker.dart';

void main() {
  const assets = <ReleaseAsset>[
    ReleaseAsset(
      name: 'MusicFlow-v350-windows.zip',
      downloadUrl: 'https://example.test/windows.zip',
      size: 1024,
    ),
    ReleaseAsset(
      name: 'MusicFlow-v350-android.apk',
      downloadUrl: 'https://example.test/android.apk',
      size: 2048,
    ),
  ];

  UpdateCheckResult updateResult({bool hasUpdate = true}) => UpdateCheckResult(
    hasUpdate: hasUpdate,
    currentVersion: '3.4.29',
    latestVersion: '3.5.0',
    releaseUrl: 'https://example.test/release',
    releaseNotes: '### 修复\n- 更新检查',
    assets: assets,
  );

  const hostKey = Key('startup-update-check-host');

  Widget app(Widget child) {
    return MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));
  }

  group('startupUpdateCheckSupported', () {
    test('only Windows and Android run the silent check', () {
      expect(
        startupUpdateCheckSupported(
          platform: TargetPlatform.windows,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        startupUpdateCheckSupported(
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isTrue,
      );
      for (final platform in <TargetPlatform>[
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.iOS,
      ]) {
        expect(
          startupUpdateCheckSupported(platform: platform, isWeb: false),
          isFalse,
        );
      }
      expect(
        startupUpdateCheckSupported(
          platform: TargetPlatform.windows,
          isWeb: true,
        ),
        isFalse,
      );
    });
  });

  group('pickPlatformUpdateAsset', () {
    test('Android prefers apk, others prefer zip', () {
      expect(
        pickPlatformUpdateAsset(
          updateResult(),
          platform: TargetPlatform.android,
        )!.downloadUrl,
        'https://example.test/android.apk',
      );
      expect(
        pickPlatformUpdateAsset(
          updateResult(),
          platform: TargetPlatform.windows,
        )!.downloadUrl,
        'https://example.test/windows.zip',
      );
    });

    test('falls back to first asset when no preferred suffix', () {
      final result = UpdateCheckResult(
        hasUpdate: true,
        currentVersion: '1',
        latestVersion: '2',
        assets: const <ReleaseAsset>[
          ReleaseAsset(
            name: 'notes.txt',
            downloadUrl: 'https://example.test/notes.txt',
            size: 1,
          ),
        ],
      );
      expect(
        pickPlatformUpdateAsset(result, platform: TargetPlatform.android)!
            .downloadUrl,
        'https://example.test/notes.txt',
      );
    });

    test('returns null when the release has no assets', () {
      expect(
        pickPlatformUpdateAsset(
          UpdateCheckResult(
            hasUpdate: true,
            currentVersion: '1',
            latestVersion: '2',
          ),
          platform: TargetPlatform.android,
        ),
        isNull,
      );
    });
  });

  group('runStartupUpdateCheck', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows dialog and launches the platform download URL', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final launched = <String>[];
      await tester.pumpWidget(app(const SizedBox(key: hostKey)));

      final shown = await runStartupUpdateCheck(
        tester.element(find.byKey(hostKey)),
        checker: () async => updateResult(),
        launcher: (url) async => launched.add(url),
        platform: TargetPlatform.windows,
        delay: Duration.zero,
      );
      await tester.pumpAndSettle();

      expect(shown, isTrue);
      expect(find.text('发现新版本 3.5.0'), findsOneWidget);
      // Windows 平台挑 zip 资源。
      await tester.tap(find.text('前往下载'));
      await tester.pumpAndSettle();
      expect(launched, <String>['https://example.test/windows.zip']);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Android picks the apk asset', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final launched = <String>[];
      await tester.pumpWidget(app(const SizedBox(key: hostKey)));

      await runStartupUpdateCheck(
        tester.element(find.byKey(hostKey)),
        checker: () async => updateResult(),
        launcher: (url) async => launched.add(url),
        platform: TargetPlatform.android,
        delay: Duration.zero,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('前往下载'));
      await tester.pumpAndSettle();
      expect(launched, <String>['https://example.test/android.apk']);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('「稍后再说」closes without downloading', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final launched = <String>[];
      await tester.pumpWidget(app(const SizedBox(key: hostKey)));

      await runStartupUpdateCheck(
        tester.element(find.byKey(hostKey)),
        checker: () async => updateResult(),
        launcher: (url) async => launched.add(url),
        platform: TargetPlatform.windows,
        delay: Duration.zero,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('稍后再说'));
      await tester.pumpAndSettle();
      expect(launched, isEmpty);
      expect(find.text('发现新版本 3.5.0'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('stays silent when already up to date', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(app(const SizedBox(key: hostKey)));
      final shown = await runStartupUpdateCheck(
        tester.element(find.byKey(hostKey)),
        checker: () async => updateResult(hasUpdate: false),
        launcher: (_) async {},
        platform: TargetPlatform.windows,
        delay: Duration.zero,
      );
      await tester.pumpAndSettle();

      expect(shown, isFalse);
      expect(find.text('发现新版本 3.5.0'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('does nothing on unsupported platforms', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var checked = 0;
      await tester.pumpWidget(app(const SizedBox(key: hostKey)));
      final shown = await runStartupUpdateCheck(
        tester.element(find.byKey(hostKey)),
        checker: () async {
          checked++;
          return updateResult();
        },
        launcher: (_) async {},
        platform: TargetPlatform.linux,
        delay: Duration.zero,
      );

      expect(shown, isFalse);
      expect(checked, 0);
    });
  });

  group('StartupUpdateCheckScope', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('runs the check once after the first frame', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      var checks = 0;
      await tester.pumpWidget(
        app(
          StartupUpdateCheckScope(
            delay: Duration.zero,
            checker: () async {
              checks++;
              return updateResult();
            },
            launcher: (_) async {},
            child: const Text('home'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(checks, 1);
      expect(find.text('发现新版本 3.5.0'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
