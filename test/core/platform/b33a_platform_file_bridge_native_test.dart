import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/platform/platform_file_bridge_native.dart';

/// 覆盖 platform_file_bridge_native.dart：对 dart:io File 的简单封装。
/// 在 native 测试环境下用真实临时文件验证各函数。
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('b33a_pfb_');
    file = File('${dir.path}/sample.txt');
    file.writeAsStringSync('hello');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('fileForPath 返回指向该路径的 File', () {
    final f = fileForPath(file.path) as File;
    expect(f.path, file.path);
  });

  test('fileExistsSync 对不存在路径返回 false', () {
    expect(fileExistsSync('${dir.path}/nope.txt'), isFalse);
  });

  test('fileExistsSync 对真实文件返回 true', () {
    expect(fileExistsSync(file.path), isTrue);
  });

  test('fileExists 异步版本对真实文件返回 true', () async {
    expect(await fileExists(file.path), isTrue);
  });

  test('fileLength 返回文件字节数', () async {
    expect(await fileLength(file.path), 5);
  });
}
