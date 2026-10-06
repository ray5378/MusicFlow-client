// batch35 C 路 —— `lib/widgets/windows_title_bar.dart` 补测。
//
// 覆盖点：
//   * WindowsWindowChrome 非 Windows 平台 → SizedBox.shrink；
//   * Windows 平台渲染最小化/最大化/关闭按钮；
//   * 按钮点击/拖拽/双击 → kWindowsWindowChannel 对应 method 被调用；
//   * setTrayTooltip / setDesktopLyric* 全家桶的 method 与参数；
//   * MissingPluginException / PlatformException 被静默吞掉。
//
// 踩坑记录：
// #W1 isWindowsDesktop 依赖 defaultTargetPlatform，测试里用
//     debugDefaultTargetPlatformOverride = TargetPlatform.windows（tearDown 复位）。
// #W2 通道 mock 用 TestDefaultBinaryMessenger 对 kWindowsWindowChannel
//     ('com.musicflow.app/window') 注册 handler；不注册 handler 时 invokeMethod
//     抛 MissingPluginException —— 正好用来测「静默忽略」分支。
// #W3 组件自带 Overlay（Tooltip 需要），挂在 Scaffold body 即可，无需额外
//     Overlay 祖先；拖拽区是树中第一个 GestureDetector（opaque）。
// #W4 双击用 tapAt 两次 + kDoubleTapMinTime 间隔；拖拽用 startGesture/moveBy。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

late AppLocalizations loc;
final List<MethodCall> channelCalls = <MethodCall>[];

void mockWindowChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(kWindowsWindowChannel, (call) async {
    channelCalls.add(call);
    return null;
  });
}

void clearWindowChannelHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(kWindowsWindowChannel, null);
}

/// Windows 平台用例包装：debugDefaultTargetPlatformOverride 必须在用例体内
/// 复位（flutter_test 在 body 结束后、tearDown 之前就检查 foundation 变量）。
void windowsTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Widget host({Widget? body}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    theme: AppTheme.light(),
    builder: (context, child) {
      loc = AppLocalizations.of(context);
      return child!;
    },
    home: Scaffold(body: body ?? const WindowsWindowChrome()),
  );
}

Future<void> settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUp(() => channelCalls.clear());
  tearDown(clearWindowChannelHandler);

  testWidgets('非 Windows 平台：Chrome 不渲染任何窗口控制按钮', (tester) async {
    // 测试环境默认非 Windows（android），不设 override。
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.byIcon(Icons.remove), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(tester.takeException(), isNull);
  });

  windowsTest('Windows 平台：渲染最小化/最大化/关闭三个按钮', (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.crop_square), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    // Tooltip 文案来自本地化。
    expect(find.byTooltip(loc.widgets_window_minimize), findsOneWidget);
    expect(find.byTooltip(loc.widgets_window_close), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  windowsTest('点最小化按钮 → 通道收到 minimize', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump();

    expect(
      channelCalls.where((c) => c.method == 'minimize'),
      isNotEmpty,
      reason: '最小化按钮应调用窗口通道 minimize',
    );
    expect(tester.takeException(), isNull);
  });

  windowsTest('点最大化按钮 → 通道收到 maximize_toggle', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pump();

    expect(
      channelCalls.where((c) => c.method == 'maximize_toggle'),
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  windowsTest('点关闭按钮 → 通道收到 close', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(channelCalls.where((c) => c.method == 'close'), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  windowsTest('拖拽顶部区域 → 通道收到 start_move', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());
    await settle(tester);

    // 顶部拖拽区避开右上角按钮：取 chrome 左上角偏右下的点。
    final origin = tester.getTopLeft(find.byType(WindowsWindowChrome));
    final point = origin + const Offset(60, 20);
    final gesture = await tester.startGesture(point);
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pump();
    // 排空手势/velocity 相关 pending timer。
    await tester.pump(const Duration(milliseconds: 400));

    expect(channelCalls.where((c) => c.method == 'start_move'), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  windowsTest('双击顶部区域 → 通道收到 maximize_toggle', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());
    await settle(tester);

    final origin = tester.getTopLeft(find.byType(WindowsWindowChrome));
    final point = origin + const Offset(60, 20);
    await tester.tapAt(point);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(point);
    await tester.pump();
    // 排空 doubleTap 超时 timer。
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      channelCalls.where((c) => c.method == 'maximize_toggle'),
      isNotEmpty,
      reason: '双击拖拽区应触发最大化切换',
    );
    expect(tester.takeException(), isNull);
  });

  windowsTest('setTrayTooltip 在 Windows 下走通道并携带文本', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());

    await setTrayTooltip('正在播放 · 测试歌曲');
    await tester.pump();

    final call = channelCalls.singleWhere((c) => c.method == 'set_tray_tooltip');
    expect(call.arguments as Map, containsPair('text', '正在播放 · 测试歌曲'));
    expect(tester.takeException(), isNull);
  });

  windowsTest('setDesktopLyricText / setDesktopLyricVisible 走通道', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());

    await setDesktopLyricText('歌词行一');
    await setDesktopLyricVisible(false);
    await tester.pump();

    expect(
      channelCalls.map((c) => c.method),
      containsAll(<String>['set_desktop_lyric_text', 'set_desktop_lyric_visible']),
    );
    expect(
      channelCalls.singleWhere((c) => c.method == 'set_desktop_lyric_text')
          .arguments as Map,
      containsPair('text', '歌词行一'),
    );
    expect(
      channelCalls.singleWhere((c) => c.method == 'set_desktop_lyric_visible')
          .arguments as Map,
      containsPair('visible', false),
    );
    expect(tester.takeException(), isNull);
  });

  windowsTest('setDesktopLyricState 推送完整显示状态', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());

    await setDesktopLyricState(
      song: '歌名',
      artist: '歌手',
      lyric: '歌词',
      playing: true,
      liked: false,
      mode: 'order',
      volume: 0.5,
      lyricColor: 0xFFFFFFFF,
    );
    await tester.pump();

    final call = channelCalls.singleWhere(
      (c) => c.method == 'update_desktop_lyric_state',
    );
    final args = call.arguments as Map;
    expect(args, containsPair('song', '歌名'));
    expect(args, containsPair('playing', true));
    expect(args, containsPair('volume', 0.5));
    expect(tester.takeException(), isNull);
  });

  windowsTest('setDesktopLyricQueue / setDesktopLyricSwitchList 推送队列数据', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());

    await setDesktopLyricQueue(items: <String>['一', '二'], index: 1);
    await setDesktopLyricSwitchList(
      items: <Map<String, Object>>[
        <String, Object>{'title': '设备A', 'subtitle': '在线', 'current': true},
      ],
      loading: false,
    );
    await tester.pump();

    final queue = channelCalls.singleWhere(
      (c) => c.method == 'update_desktop_lyric_queue',
    );
    expect((queue.arguments as Map)['items'], <String>['一', '二']);
    expect((queue.arguments as Map)['index'], 1);

    final switchList = channelCalls.singleWhere(
      (c) => c.method == 'update_desktop_lyric_switch_list',
    );
    expect((switchList.arguments as Map)['loading'], false);
    final items = (switchList.arguments as Map)['items'] as List;
    expect(items.first['title'], '设备A');
    expect(items.first['current'], true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非 Windows 平台：setTrayTooltip 直接跳过不触达通道', (tester) async {
    mockWindowChannel();
    await tester.pumpWidget(host());

    await setTrayTooltip('不应发送');
    await tester.pump();

    expect(channelCalls, isEmpty, reason: '非 Windows 平台应短路返回');
    expect(tester.takeException(), isNull);
  });

  windowsTest('Windows 平台但无原生 handler：MissingPluginException 被吞', (tester) async {
    // 不注册 handler → 平台侧无响应，invokeMethod 的 future 不会完成；
    // 用 unawaited 发起验证「异常/挂起都不会冒泡到调用方」。
    await tester.pumpWidget(host());

    unawaited(setTrayTooltip('无 handler'));
    unawaited(setDesktopLyricText('无 handler'));
    unawaited(setDesktopLyricVisible(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull, reason: 'MissingPluginException 应被静默忽略');
  });

  windowsTest('Windows 平台通道抛 PlatformException：被吞不影响调用方', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kWindowsWindowChannel, (call) async {
      throw PlatformException(code: 'tray_error', message: '托盘挂了');
    });
    await tester.pumpWidget(host());

    await setTrayTooltip('会失败');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
