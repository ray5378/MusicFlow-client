// b36a —— 「默认控制当前客户端」设置的持久化补测
// （`lib/data/sources/local_storage.dart` 新增的
//  getDefaultControlCurrentClient / setDefaultControlCurrentClient）。
//
// 产品代码零改动；仅新增 test/。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('未设置 → 默认 false（关闭 = 沿用启动自动接管在播播放器）', () async {
    expect(await LocalStorage.getDefaultControlCurrentClient(), isFalse);
  });

  test('设为 true → 读回 true', () async {
    await LocalStorage.setDefaultControlCurrentClient(true);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isTrue);
  });

  test('true → false 往返一致', () async {
    await LocalStorage.setDefaultControlCurrentClient(true);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isTrue);

    await LocalStorage.setDefaultControlCurrentClient(false);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isFalse);
  });

  test('持久化的 bool 值 true 直接读回', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'default_control_current_client': true,
    });
    expect(await LocalStorage.getDefaultControlCurrentClient(), isTrue);
  });
}
