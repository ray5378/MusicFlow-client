// AndroidPlatformInfo 的读取路径锁（版本分叉的上游）。
//
// 为什么值得单独测：
//   通知栏的两种布局（两行 / 三行）和两条按钮通路（槽位 / action 列表）全靠
//   这一个 sdkInt。它读不到或读错时**不会报错**，只会静默走错分支：
//   30+ 上把歌词写进 displayDescription（零消费方）、或 33+ 上多发一个上一首
//   把收藏挤出折叠态。两种都是「看起来正常、真机上少东西」。
//
// 覆盖点：
//   · 桌面平台直接短路（不同通道、sdkInt 保持 0）
//   · Android 读到值 → 缓存
//   · 已读过就幂等（不重复打通道）
//   · 通道抛错 → 降级为 0（未知），不影响启动

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/android_platform_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.musicflow.app/platform_info');
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    AndroidPlatformInfo.debugSetSdkInt(0);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AndroidPlatformInfo.debugSetSdkInt(0);
    debugDefaultTargetPlatformOverride = null;
  });

  void mockSdk(int? value, {bool throwError = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (throwError) {
        throw PlatformException(code: 'unavailable');
      }
      return value;
    });
  }

  test('桌面平台不碰通道，sdkInt 保持未知', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    mockSdk(34);

    await AndroidPlatformInfo.load();

    expect(calls, isEmpty, reason: '桌面没有 audio_service 通知，读版本纯属浪费');
    expect(AndroidPlatformInfo.sdkInt, 0);
  });

  test('Android 上读到 API level 并缓存', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockSdk(34);

    await AndroidPlatformInfo.load();

    expect(calls, ['androidSdkInt']);
    expect(AndroidPlatformInfo.sdkInt, 34);
    expect(AndroidPlatformInfo.useLegacyThreeLineNotification, isFalse);
    expect(AndroidPlatformInfo.usesNotificationActionSlots, isFalse);
  });

  test('已读过就幂等，不再打通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockSdk(32);

    await AndroidPlatformInfo.load();
    await AndroidPlatformInfo.load();

    expect(calls, ['androidSdkInt'], reason: '启动链路多处 await load，必须只读一次');
    expect(AndroidPlatformInfo.sdkInt, 32);
    expect(AndroidPlatformInfo.usesNotificationActionSlots, isTrue);
  });

  test('通道抛错降级为未知，不阻断启动', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockSdk(null, throwError: true);

    await AndroidPlatformInfo.load();

    expect(AndroidPlatformInfo.sdkInt, 0);
    // 未知一律按新布局：宁可少一行/少一个上一首，也不要走错分支。
    expect(AndroidPlatformInfo.useLegacyThreeLineNotification, isFalse);
    expect(AndroidPlatformInfo.usesNotificationActionSlots, isFalse);
  });

  test('通道返回 0 / null 时按未知处理', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockSdk(0);

    await AndroidPlatformInfo.load();

    expect(AndroidPlatformInfo.sdkInt, 0);
    expect(calls, ['androidSdkInt']);
  });
}
