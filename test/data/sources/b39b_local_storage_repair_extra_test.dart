// b39b —— Route B：LocalStorage.repairCorruptPreferences 兜底分支补测。
//
// 覆盖 lcov 未命中行：
//   * local_storage.dart:728  备份损坏 prefs 失败时的 catch 日志
//
// 触发链：`getPrefs()` 抛错（进入修复流程）→ `getApplicationSupportDirectory()`
// 也抛错 → 命中 line 727 的 catch → line 728。
//
// 产品代码零改动；仅新增 test/。
// 不可达（见报告）：local_storage.dart 461 / 584 / 585 —— `jsonDecode` 对对象恒返回
//   `Map<String, dynamic>`，紧随其后的 `decoded is Map`（非 Map<String,dynamic>）分支
//   永不可达，属死代码。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/local_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel prefsChannel = MethodChannel(
    'plugins.flutter.io/shared_preferences',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(prefsChannel, null);
  });

  test('repairCorruptPreferences：prefs 损坏且备份目录不可用 → 记录日志不抛（line 728）',
      () async {
    // 让 shared_preferences 平台通道强制抛错，模拟「半写/损坏 prefs 文件」。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(prefsChannel, (MethodCall call) async {
      throw MissingPluginException('corrupt prefs (b39b)');
    });

    // path_provider 未注册任何实现 → getApplicationSupportDirectory 抛错
    // → 命中 727 的 catch → 执行 line 728 的告警日志。
    await expectLater(LocalStorage.repairCorruptPreferences(), completes);
  });
}
