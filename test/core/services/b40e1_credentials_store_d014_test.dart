// b40e1 —— D-014：CredentialsStore 平台白名单补 Linux。
//
// 修复前 `_supported` 白名单只有 android/windows/iOS/macOS，Linux 桌面端
// writeAll/deleteAll 直接静默 return、readAll 返回空 {}——「记住密码」
// 勾了等于没勾，进程重启即被踢回登录页（230 上 Linux 客户端实测复现）。
//
// 测法：用 `debugDefaultTargetPlatformOverride` 逐平台驱动，并 mock
// flutter_secure_storage 的 MethodChannel，观察底层存储调用是否真正发生：
//   - 修复前 linux：0 次调用（静默降级）；
//   - 修复后 linux：与 android 等白名单内平台一样，write/delete 触达 channel。
// 每个用例用 try/finally 把 override 还原为 null（不依赖 addTearDown）。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/credentials_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final invoked = <MethodCall>[];

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      invoked.add(call);
      return null;
    });
  }

  void unmockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    unmockChannel();
  });

  Future<void> runOnPlatform(TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    mockChannel();
    await CredentialsStore.writeAll(
      CredentialsStore.scopeServerConfig,
      'u1',
      {'password': 'p1'},
    );
    await CredentialsStore.deleteAll(
      CredentialsStore.scopeServerConfig,
      'u1',
      const ['password'],
    );
    final read = await CredentialsStore.readAll(
      CredentialsStore.scopeServerConfig,
      'u1',
      const ['password'],
    );
    expect(read, isA<Map<String, String>>(),
        reason: '$platform 下 readAll 应正常降级返回 Map 而非抛异常');
  }

  test('白名单内 4 平台（android/windows/iOS/macOS）底层存储被触达', () async {
    try {
      for (final p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        invoked.clear();
        await runOnPlatform(p);
        expect(invoked, isNotEmpty,
            reason: '$p 在白名单内,应触达 flutter_secure_storage');
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('[D-014] linux 补入白名单后 write 真正触达底层存储（修复前为 0 次）', () async {
    try {
      await runOnPlatform(TargetPlatform.linux);
      expect(
        invoked.any((c) => c.method == 'write'),
        isTrue,
        reason: 'linux 下 writeAll 应真正触达 flutter_secure_storage,'
            '而不是因白名单缺失被静默跳过',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
