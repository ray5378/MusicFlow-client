// b38b3 —— Route B：ensureMediaNotificationPermission 未授予分支补测。
//
// lcov 未命中行 22-25：Android 上 POST_NOTIFICATIONS 请求返回「未授予」时应记日志
// （幂等、静默降级）。Linux 测试机上 defaultTargetPlatform 不是 android 会整体
// 短路，故切到 android 并 mock permission_handler 的平台通道返回 denied。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/notification_permission_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android 上请求被拒 → 记录日志、不抛（22-25）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (MethodCall call) async {
        if (call.method == 'requestPermissions') {
          final requested = (call.arguments as List).cast<int>();
          // PermissionStatus.denied == 0 → 非授予。
          return <int, int>{for (final v in requested) v: 0};
        }
        return null;
      },
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await ensureMediaNotificationPermission();
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        null,
      );
    }
  });
}
