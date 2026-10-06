// b39b —— Route B：文件 KV 存储 + 凭据存储剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * json_file_store.dart:69   readString 内部异常 → 记日志返回 null
//   * credentials_store.dart:47 writeAll 空值字段 → delete
//   * credentials_store.dart:68 readAll 读到非空值 → 回填结果 Map
//
// 产品代码零改动；仅新增 test/。
//
// 说明（不可达，见报告）：
//   * json_file_store.dart:44-49 —— 该分支仅在 `Platform.environment['FLUTTER_TEST']`
//     为空时才进入；`flutter test` 进程恒设置该环境变量（第 41 行已覆盖即证明走的是
//     FLUTTER_TEST 早退分支），生产 `getApplicationSupportDirectory()` 路径在
//     flutter test 下永远不可达。
//   * credentials_store.dart:15 —— 私有构造 `CredentialsStore._()` 全类静态、从不实例化。

import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/core/services/credentials_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JsonFileStore.readString 内部异常兜底', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('b39b_jfs');
    });

    tearDown(() async {
      JsonFileStore.instance.debugDirectory = null;
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('注入路径指向「已存在的文件」时 _resolveDir 抛错 → 返回 null（line 69）',
        () async {
      // Directory(path) 指向一个真实文件：existsSync() 为 false → createSync 抛
      // FileSystemException → 命中 readString 的 catch → 记日志并返回 null。
      final asFile = File('${tmp.path}${Platform.pathSeparator}not_a_dir');
      await asFile.writeAsString('x');
      JsonFileStore.instance.debugDirectory = Directory(asFile.path);

      expect(await JsonFileStore.instance.readString('any-key'), isNull);
    });
  });

  group('CredentialsStore 受支持平台读写分支', () {
    const MethodChannel channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final Map<String, String> kv = <String, String>{};

    setUp(() {
      kv.clear();
      // 显式锁定到受支持平台，确保 _supported 为 true（不依赖测试默认平台）。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        final Map<Object?, Object?> args =
            (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
        final String? key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            kv[key!] = args['value'] as String;
            return null;
          case 'read':
            return kv[key];
          case 'delete':
            kv.remove(key);
            return null;
          case 'containsKey':
            return kv.containsKey(key);
          default:
            return null;
        }
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('writeAll 空串值走 delete（line 47），readAll 非空值回填（line 68）',
        () async {
      await CredentialsStore.writeAll(
        CredentialsStore.scopeServerConfig,
        'id-9',
        <String, String?>{'password': 'secret', 'apiKey': '', 'token': null},
      );

      // 空串 / null 字段被删除：不应写入键值对。
      expect(kv.containsKey('cred_server_config_id-9_apiKey'), isFalse);
      expect(kv.containsKey('cred_server_config_id-9_token'), isFalse);
      expect(kv['cred_server_config_id-9_password'], 'secret');

      final Map<String, String> out = await CredentialsStore.readAll(
        CredentialsStore.scopeServerConfig,
        'id-9',
        const <String>['password', 'apiKey'],
      );
      expect(out['password'], 'secret');
      expect(out.containsKey('apiKey'), isFalse);
    });
  });
}
