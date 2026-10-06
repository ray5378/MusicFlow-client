// b37b2 —— `lib/widgets/windows_title_bar.dart` 残余分支补测。
//
// b35c / b36a 已覆盖：按钮渲染、各 method 正常调用、MissingPluginException、
// setTrayTooltip 的 PlatformException、WindowsOuterBorder、app.dll 分支。
// 本文件补：
//   * `_invoke`（窗口按钮）的 PlatformException / MissingPluginException 分支；
//   * 每个 setDesktopLyric* 的 PlatformException 分支；
//   * 每个 setDesktopLyric* 的「非 Windows 直接短路」（不触达通道）；
//   * `isWindowsDesktop` 判定真假两态。
// 产品代码零改动；仅新增 test/。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

final List<MethodCall> channelCalls = <MethodCall>[];

void mockChannel({Future<Object?> Function(MethodCall)? handler}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(kWindowsWindowChannel, (call) async {
    channelCalls.add(call);
    if (handler != null) return handler(call);
    return null;
  });
}

void clearChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(kWindowsWindowChannel, null);
}

Widget host() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      home: const Scaffold(body: WindowsWindowChrome()),
    );

Future<void> settle(WidgetTester tester, [int frames = 4]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> callAllDesktopLyricHelpers() async {
  await setDesktopLyricState(
    song: 's',
    artist: 'a',
    lyric: 'l',
    playing: true,
    liked: true,
    mode: 'order',
    volume: 0.5,
    lyricColor: 0xFFFFFFFF,
  );
  await setDesktopLyricQueue(items: const <String>['一'], index: 0);
  await setDesktopLyricSwitchList(items: const <Map<String, Object>>[]);
  await setDesktopLyricVisible(true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => channelCalls.clear());
  tearDown(clearChannel);

  test('isWindowsDesktop：仅 Windows 桌面为 true', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(isWindowsDesktop, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isWindowsDesktop, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  test('非 Windows：setTrayTooltip / setDesktopLyric* 全量短路不触达通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      mockChannel();
      await setTrayTooltip('t');
      await setDesktopLyricText('x');
      await callAllDesktopLyricHelpers();
      expect(channelCalls, isEmpty, reason: '非 Windows 平台应全部短路返回');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows：窗口按钮 _invoke 抛 PlatformException 被吞', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      mockChannel(handler: (call) async {
        throw PlatformException(code: 'win_ctrl', message: '窗口控制挂了');
      });
      await tester.pumpWidget(host());
      await settle(tester);

      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: '_invoke 的 PlatformException 分支应静默');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows：无原生 handler 时窗口按钮 _invoke 的 MissingPlugin 被吞',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      // 不注册 handler → invokeMethod 抛 MissingPluginException。
      clearChannel();
      await tester.pumpWidget(host());
      await settle(tester);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.takeException(), isNull,
          reason: '_invoke 的 MissingPluginException 分支应静默');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows：setTrayTooltip / setDesktopLyric* 抛 PlatformException 被吞',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      mockChannel(handler: (call) async {
        throw PlatformException(code: 'lyric');
      });
      await setTrayTooltip('t');
      await setDesktopLyricText('x');
      await callAllDesktopLyricHelpers();
      expect(tester.takeException(), isNull,
          reason: '各 helper 的 PlatformException 分支都应被吞');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows：各 helper 正常走通道并携带参数', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      mockChannel();
      await setDesktopLyricQueue(items: const <String>['甲', '乙'], index: 1);
      await setDesktopLyricSwitchList(
        items: const <Map<String, Object>>[
          <String, Object>{'title': '设备', 'subtitle': '在线', 'current': true},
        ],
        loading: true,
      );
      await setDesktopLyricVisible(true);

      final q = channelCalls.singleWhere(
        (c) => c.method == 'update_desktop_lyric_queue',
      );
      expect((q.arguments as Map)['index'], 1);
      final s = channelCalls.singleWhere(
        (c) => c.method == 'update_desktop_lyric_switch_list',
      );
      expect((s.arguments as Map)['loading'], true);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
