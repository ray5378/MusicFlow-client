// b36c —— `lib/data/sources/json_file_store.dart` 补测（原 15 miss）。
//
// 覆盖：debugDirectory 注入 / 键→文件名安全化 / readString 未命中返回 null /
// 写入-读取-删除闭环 / 同键并发写入串行化（后写覆盖前写）/ 把目标名占用为
// 目录后读失败被吞返回 null（容错不抛）。
//
// 产品代码零改动；只读 lib。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/json_file_store.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('b36c_json_store');
    JsonFileStore.instance.debugDirectory = dir;
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    JsonFileStore.instance.debugDirectory = null;
  });

  test('写入后可读取，内容一致', () async {
    await JsonFileStore.instance.writeString('key.a', '{"v":1}');
    expect(await JsonFileStore.instance.readString('key.a'), '{"v":1}');
  });

  test('读取未写入的键返回 null', () async {
    expect(await JsonFileStore.instance.readString('missing'), isNull);
  });

  test('键中的非法字符被安全化为下划线文件名', () async {
    await JsonFileStore.instance.writeString('lib/1:2 3', 'x');
    final files = dir.listSync().whereType<File>().map((f) => f.path).toList();
    expect(files.length, 1);
    expect(files.single.endsWith('lib_1_2_3.json'), isTrue);
    // 通过同一键仍可读回。
    expect(await JsonFileStore.instance.readString('lib/1:2 3'), 'x');
  });

  test('同键并发写入串行化，最终值为最后一次写入', () async {
    final futures = <Future<void>>[
      for (var i = 0; i < 8; i++)
        JsonFileStore.instance.writeString('race', 'v$i'),
    ];
    await Future.wait(futures);
    expect(await JsonFileStore.instance.readString('race'), 'v7');
    // 不留 .tmp 残留。
    expect(
      dir.listSync().whereType<File>().any((f) => f.path.endsWith('.tmp')),
      isFalse,
    );
  });

  test('remove 删除已写入键；不存在时静默', () async {
    await JsonFileStore.instance.writeString('gone', '1');
    expect(await JsonFileStore.instance.readString('gone'), '1');
    await JsonFileStore.instance.remove('gone');
    expect(await JsonFileStore.instance.readString('gone'), isNull);
    // 再次删除不抛。
    await JsonFileStore.instance.remove('gone');
  });

  test('目标名被目录占用时读取失败被吞，返回 null', () async {
    // 'boom' -> 'boom.json'；把该名字建成目录，readAsString 会抛，
    // 由 readString 的 catch 吞掉并返回 null。
    Directory('${dir.path}${Platform.pathSeparator}boom.json')
        .createSync(recursive: true);
    expect(await JsonFileStore.instance.readString('boom'), isNull);
  });
}
