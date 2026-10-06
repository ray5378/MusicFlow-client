// b38b3 —— Route B：CredentialsStore 在受支持平台上的读写分支补测。
//
// lcov 未命中行 47（value 为空 → delete）与 68（读到非空值回填）。
// 在 Linux 测试机上 `_supported` 为 false 会整体短路，故用
// `debugDefaultTargetPlatformOverride` 切到 windows 让分支可达；底层
// FlutterSecureStorage 无原生实现会抛 MissingPluginException，被产品代码
// 的 catch 静默吞掉，不影响断言（只关心分支被执行）。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/credentials_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('受支持平台上 writeAll/readAll/deleteAll 逐字段分支可达', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    // value 为空串 / null 走 delete，非空走 write。
    await CredentialsStore.writeAll(
      CredentialsStore.scopeServerConfig,
      'id-1',
      <String, String?>{'password': 'secret', 'apiKey': null, 'token': ''},
    );

    final read = await CredentialsStore.readAll(
      CredentialsStore.scopeServerConfig,
      'id-1',
      const <String>['password', 'apiKey'],
    );
    expect(read, isA<Map<String, String>>());

    await CredentialsStore.deleteAll(
      CredentialsStore.scopeServerConfig,
      'id-1',
      const <String>['password'],
    );

    debugDefaultTargetPlatformOverride = null;
  });

  test('不受支持平台直接短路返回空', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await CredentialsStore.writeAll('s', 'i', <String, String?>{'a': 'b'});
    final read = await CredentialsStore.readAll('s', 'i', const <String>['a']);
    expect(read, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });
}
