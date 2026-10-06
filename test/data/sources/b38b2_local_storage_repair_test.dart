// b38b2 —— `LocalStorage.repairCorruptPreferences()` 补测。
//
// 该方法是「进程被强杀 → shared_preferences.json 半写 → getInstance() 抛错」
// 的自愈路径：把损坏文件改名备份为 `.corrupt-<ts>`，再重建干净起点。
// 正常测试环境里 prefs 永远是健康的，走不到这条分支，所以这里用平台通道替身
// 让 `getPrefs()` 抛错、`getApplicationSupportDirectory()` 指向临时目录。
//
// 注意：本文件**刻意不调用** `SharedPreferences.setMockInitialValues` ——
// 它会把平台实现换成内存实现，之后就再也造不出「prefs 损坏」了。
//
// 产品代码零改动；仅新增 test/。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/local_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel prefsChannel =
      MethodChannel('plugins.flutter.io/shared_preferences');
  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('b38b2_repair');
    messenger.setMockMethodCallHandler(prefsChannel, (call) async {
      // 模拟损坏的 shared_preferences.json：读也读不出来。
      throw PlatformException(
        code: 'corrupt',
        message: 'shared_preferences.json is half-written',
      );
    });
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method.contains('ApplicationSupport')) return tmp.path;
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(prefsChannel, null);
    messenger.setMockMethodCallHandler(pathChannel, null);
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('prefs 损坏且文件存在 → 备份为 .corrupt-* 后重试重建', () async {
    final file = File(
      '${tmp.path}${Platform.pathSeparator}shared_preferences.json',
    );
    await file.writeAsString('{corrupt', flush: true);

    await LocalStorage.repairCorruptPreferences();

    expect(
      await file.exists(),
      isFalse,
      reason: '损坏文件必须被挪走，否则下次启动依旧读不出来',
    );
    final backups = tmp
        .listSync()
        .where((e) => e.path.contains('.corrupt-'))
        .toList();
    expect(
      backups.length,
      1,
      reason: '损坏文件应被改名备份而不是直接删除（保留现场可复盘）',
    );
    expect(
      await File(backups.single.path).readAsString(),
      '{corrupt',
      reason: '备份内容应与损坏文件一致',
    );
  });

  test('prefs 损坏且文件不存在 → 跳过备份，直接重试（仍失败也不抛）', () async {
    await LocalStorage.repairCorruptPreferences();

    expect(
      tmp.listSync().where((e) => e.path.contains('.corrupt-')).toList(),
      isEmpty,
      reason: '没有损坏文件就不该凭空产生备份',
    );
  });
}
