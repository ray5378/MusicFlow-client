// ============================================================================
// b37b2 —— `lib/providers/cast/dlna_cast_permissions.dart` 补测（补充 b36c）。
//
// 基线 lcov 里该文件仍标 0 的行全部落在「Android 专属分支」之下：
//   15        `_keepalive` 顶层单例首次访问
//   20,23,26  acquireMulticastLock 的引用计数 + 原生挂锁 + 失败日志
//   33,36,38  releaseMulticastLock
//   47,50,52  acquireCastWakeLock
//   59,62,64  releaseCastWakeLock
//   以上每一处都在 `if (!Platform.isAndroid) return;` 之后 —— 宿主（Linux 测试
//   机）`Platform.isAndroid` 恒为 false，且 dart:io 的 Platform 无
//   debugDefaultTargetPlatformOverride 之类的注入口 ⇒ **平台盲区**，
//   无法在不改 lib 的前提下覆盖（b36c 已确认并记录）。
//
// 本文件在可覆盖范围内把 b36c 的电池优化豁免契约再收紧三条边界：
//   * isIgnoringBatteryOptimization 返回 **null**（非 true）→ 仍发起申请；
//   * isIgnoring 返回 false 且 requestIgnoreBatteryOptimization **本身抛错**
//     → 被吞、不向上抛；
//   * 连续调用两次 requestBackgroundCastPerms 均不抛（幂等 + 全静默降级）。
//
// 只读 lib，零产品代码改动。
// ============================================================================

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
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('非 Android 下 acquire/release 全部立即返回且不触碰原生通道', () async {
    await acquireMulticastLock();
    await releaseMulticastLock();
    await acquireCastWakeLock();
    await releaseCastWakeLock();
    expect(calls, isEmpty);
  });

  test('requestBackgroundCastPerms：isIgnoring 返回 null（非 true）仍发起申请', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isIgnoringBatteryOptimization') return null;
      return null;
    });

    await requestBackgroundCastPerms();
    expect(
      calls,
      <String>['isIgnoringBatteryOptimization', 'requestIgnoreBatteryOptimization'],
    );
  });

  test('requestBackgroundCastPerms：申请动作本身抛错被吞，不阻断投屏', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isIgnoringBatteryOptimization') return false;
      throw PlatformException(code: 'unavailable');
    });

    await expectLater(requestBackgroundCastPerms(), completes);
    expect(
      calls,
      <String>['isIgnoringBatteryOptimization', 'requestIgnoreBatteryOptimization'],
    );
  });

  test('requestBackgroundCastPerms：连续调用幂等且均不抛', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isIgnoringBatteryOptimization') return true;
      return null;
    });

    await expectLater(requestBackgroundCastPerms(), completes);
    await expectLater(requestBackgroundCastPerms(), completes);
    // 已豁免 ⇒ 每次只查一次，都不发起申请。
    expect(calls, <String>[
      'isIgnoringBatteryOptimization',
      'isIgnoringBatteryOptimization',
    ]);
  });
}
