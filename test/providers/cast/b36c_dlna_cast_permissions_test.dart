// b36c —— `lib/providers/cast/dlna_cast_permissions.dart` 补测（原 12/27）。
//
// 说明：宿主为 Linux/测试环境，`Platform.isAndroid` 恒为 false，因此四个
// acquire/release 函数走**非 Android 立即返回**分支（引用计数与原生挂锁路径
// 属 Android 运行时盲区，无法在此环境触达，属平台盲区不强行覆盖）。
//
// 可测部分：requestBackgroundCastPerms 会**无条件**经 'com.musicflow.app/dlna'
// 通道查询/申请电池优化豁免，用 mock 平台通道覆盖三条分支：
//   * 已豁免 → 不发起申请；
//   * 未豁免 → 发起 requestIgnoreBatteryOptimization；
//   * 通道抛错 → 被吞不抛。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/cast/dlna_cast_permissions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.musicflow.app/dlna');
  final calls = <String>[];
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    calls.clear();
    messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('非 Android 下四个 acquire/release 立即返回且不抛', () async {
    await acquireMulticastLock();
    await releaseMulticastLock();
    await acquireCastWakeLock();
    await releaseCastWakeLock();
    expect(calls, isEmpty);
  });

  test('requestBackgroundCastPerms：已豁免电池优化时不发起申请', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isIgnoringBatteryOptimization') return true;
      return null;
    });

    await requestBackgroundCastPerms();
    expect(calls, <String>['isIgnoringBatteryOptimization']);
  });

  test('requestBackgroundCastPerms：未豁免时发起申请', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isIgnoringBatteryOptimization') return false;
      return null;
    });

    await requestBackgroundCastPerms();
    expect(
      calls,
      <String>['isIgnoringBatteryOptimization', 'requestIgnoreBatteryOptimization'],
    );
  });

  test('requestBackgroundCastPerms：通道抛错被吞，不阻断投屏', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'unavailable');
    });

    await expectLater(requestBackgroundCastPerms(), completes);
    expect(calls, <String>['isIgnoringBatteryOptimization']);
  });
}
