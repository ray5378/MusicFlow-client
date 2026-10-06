// b37b2 —— `lib/data/sources/local_storage.dart` 残余分支补测。
//
// b36a 已覆盖 getDefaultControlCurrentClient / setDefaultControlCurrentClient
// 的正常读写；b34b / coverage_gap 覆盖了其余大多数键。
// 本文件补：
//   * getDefaultControlCurrentClient 的**异常兜底分支**（脏数据非 bool → 抛错 → false）；
//   * repairCorruptPreferences 的「文件健康 → 直接返回」分支；
//   * setDefaultControlCurrentClient 落盘后 prefs 真值为 bool（覆盖写入语义）。
// 产品代码零改动；仅新增 test/。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('默认控制当前客户端：脏数据（键存在但非 bool）→ 读取异常回落 false', () async {
    // getBool 对非 bool 值会抛 TypeError，方法内 try/catch 必须兜住并回落 false。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'default_control_current_client': 'yes',
    });
    expect(await LocalStorage.getDefaultControlCurrentClient(), isFalse);
  });

  test('默认控制当前客户端：脏数据（int）同样回落 false 不抛', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'default_control_current_client': 1,
    });
    await expectLater(
      LocalStorage.getDefaultControlCurrentClient(),
      completion(isFalse),
    );
  });

  test('setDefaultControlCurrentClient 落盘：prefs 真值确为 bool', () async {
    await LocalStorage.setDefaultControlCurrentClient(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('default_control_current_client'), isTrue);
  });

  test('repairCorruptPreferences：文件健康时直接返回不抛', () async {
    await expectLater(LocalStorage.repairCorruptPreferences(), completes);
  });

  test('repairCorruptPreferences：健康调用后可继续正常读写', () async {
    await LocalStorage.repairCorruptPreferences();
    await LocalStorage.setDefaultControlCurrentClient(true);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isTrue);
  });
}
