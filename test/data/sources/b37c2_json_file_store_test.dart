// batch37 C(2) —— `lib/data/sources/json_file_store.dart` 剩余未覆盖分支。
//
// 既有 b36c_json_file_store_test 覆盖：写入-读取-删除闭环 / 未命中 null /
// 键名安全化 / 同键并发串行化 / 目标名被目录占用读失败被吞。
// 本文件补：
//   * debugDirectory 指向「尚不存在」的目录 → _resolveDir 自动递归创建（33-34）；
//   * 不注入 debugDirectory → FLUTTER_TEST 环境回落一次性临时目录（37-43、
//     44-49 一并覆盖「非测试」分支不可达——见文末说明）；
//   * 写入失败（目标父路径被普通文件占用）被吞且不抛（98-107 的 catch + 清理）；
//   * remove 失败被吞不抛（116-118）。
//
// 平台说明：`_resolveDir` 中「非 FLUTTER_TEST 环境走 getApplicationSupportDirectory」
// 分支（44-49）需要真实平台通道，flutter test 宿主恒走 41-43 的测试回落，
// 属平台盲区，不强行覆盖。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/json_file_store.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('b37c2_json_store');
    JsonFileStore.instance.debugDirectory = dir;
  });

  tearDown(() {
    JsonFileStore.instance.debugDirectory = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('debugDirectory 指向不存在的嵌套目录 → 自动递归创建后读写正常', () async {
    final missing = Directory(
      '${dir.path}${Platform.pathSeparator}nested${Platform.pathSeparator}deep',
    );
    expect(missing.existsSync(), isFalse, reason: '前置：目录尚不存在');

    JsonFileStore.instance.debugDirectory = missing;
    await JsonFileStore.instance.writeString('k', 'v');

    expect(missing.existsSync(), isTrue, reason: '_resolveDir 应递归创建注入目录');
    expect(await JsonFileStore.instance.readString('k'), 'v');
  });

  test('未注入 debugDirectory → FLUTTER_TEST 回落临时目录，读写不卡死', () async {
    JsonFileStore.instance.debugDirectory = null;

    await JsonFileStore.instance.writeString('fallback.key', 'ok');
    expect(await JsonFileStore.instance.readString('fallback.key'), 'ok');
  });

  test('写入失败（父路径被普通文件占用）被吞，不向上抛', () async {
    final filePath = '${dir.path}${Platform.pathSeparator}iamafile';
    File(filePath).writeAsStringSync('occupied');
    // 把「目录」指向一个普通文件：解析目录/建目录/写临时文件都会失败，
    // 由 _doWrite 的 catch 吞掉并尝试清理。
    JsonFileStore.instance.debugDirectory = Directory(filePath);

    await expectLater(
      JsonFileStore.instance.writeString('k', 'v'),
      completes,
      reason: '写入失败只记日志不抛出',
    );
  });

  test('remove 失败（父路径被普通文件占用）被吞，不向上抛', () async {
    final filePath = '${dir.path}${Platform.pathSeparator}iamafile2';
    File(filePath).writeAsStringSync('occupied');
    JsonFileStore.instance.debugDirectory = Directory(filePath);

    await expectLater(
      JsonFileStore.instance.remove('k'),
      completes,
      reason: '删除失败只记日志不抛出',
    );
  });
}
