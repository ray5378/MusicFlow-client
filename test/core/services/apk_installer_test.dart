import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/apk_installer.dart';

/// 原生「安装未知应用」通道的契约钉子。
///
/// 为什么要自建通道：`permission_handler` **没有**「安装未知应用」这一项 ——
/// 它不是普通运行时权限，而是 `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`
/// 对应的特殊应用访问权限。所以这里逐字钉住 Dart 侧发出的方法与参数，
/// 防止 `MainActivity._apkInstallHandler` 与 Dart 侧悄悄漂移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final installer = ApkInstaller();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void mock(Future<Object?> Function(MethodCall call) handler) {
    calls.clear();
    messenger.setMockMethodCallHandler(ApkInstaller.channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(ApkInstaller.channel, null);
  });

  test('通道名与 MainActivity 常量逐字一致', () {
    expect(ApkInstaller.channel.name, 'com.musicflow.app/apk_install');
  });

  group('非 Android 平台一个通道都不打', () {
    test('canRequestPackageInstalls', () async {
      mock((_) async => true);
      final ok = await installer.canRequestPackageInstalls(
        platform: TargetPlatform.windows,
        isWeb: false,
      );
      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('openUnknownSourcesSettings', () async {
      mock((_) async => true);
      final ok = await installer.openUnknownSourcesSettings(
        platform: TargetPlatform.windows,
        isWeb: false,
      );
      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('installApk', () async {
      mock((_) async => true);
      final ok = await installer.installApk(
        '/tmp/a.apk',
        platform: TargetPlatform.windows,
        isWeb: false,
      );
      expect(ok, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('Android 上的三个方法', () {
    test('canRequestPackageInstalls 透传原生布尔值', () async {
      mock((call) async {
        expect(call.method, 'canRequestPackageInstalls');
        expect(call.arguments, isNull);
        return true;
      });
      expect(
        await installer.canRequestPackageInstalls(
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isTrue,
      );
      expect(calls, hasLength(1));
    });

    test('openUnknownSourcesSettings 透传原生布尔值', () async {
      mock((call) async {
        expect(call.method, 'openUnknownSourcesSettings');
        return true;
      });
      expect(
        await installer.openUnknownSourcesSettings(
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isTrue,
      );
    });

    test('installApk 把路径原样放进 path 参数', () async {
      mock((call) async {
        expect(call.method, 'installApk');
        expect(call.arguments, isA<Map<Object?, Object?>>());
        final args = call.arguments as Map<Object?, Object?>;
        expect(args['path'], '/data/user/0/com.musicflow.app/Download/a.apk');
        return true;
      });
      final ok = await installer.installApk(
        '/data/user/0/com.musicflow.app/Download/a.apk',
        platform: TargetPlatform.android,
        isWeb: false,
      );
      expect(ok, isTrue);
    });
  });

  group('失败一律降级成 false，绝不向上抛', () {
    test('原生抛 PlatformException（未授权 / 文件不存在）→ false', () async {
      mock(
        (call) async => throw PlatformException(
          code: 'INSTALL_PERMISSION_REQUIRED',
          message: 'not granted',
        ),
      );
      expect(
        await installer.installApk(
          '/tmp/a.apk',
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isFalse,
      );
    });

    test('原生返回 null → false', () async {
      mock((_) async => null);
      expect(
        await installer.canRequestPackageInstalls(
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isFalse,
      );
    });

    test('没有原生实现（MissingPluginException，桌面调试）→ false', () async {
      messenger.setMockMethodCallHandler(ApkInstaller.channel, null);
      expect(
        await installer.canRequestPackageInstalls(
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isFalse,
      );
      expect(
        await installer.installApk(
          '/tmp/a.apk',
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isFalse,
      );
    });
  });
}
