// b38b2 —— `lib/data/sources/local_storage.dart` 解析失败分支补测。
//
// `getServerConfig` 的成功/迁移路径已有其它用例覆盖；这里补两条「prefs 里的
// server_config 无法解析」的降级分支：坏 JSON 与「JSON 合法但不是对象」。
// 两者都必须返回 null 而不是抛出 —— 登录页依赖这个语义做「重新配置」引导。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/sources/local_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('server_config 是坏 JSON → 降级返回 null，不抛', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_config': '{oops',
    });

    expect(await LocalStorage.getServerConfig(), isNull);
  });

  test('server_config 是合法 JSON 但不是对象 → 降级返回 null，不抛', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_config': '[1,2,3]',
    });

    expect(await LocalStorage.getServerConfig(), isNull);
  });
}
