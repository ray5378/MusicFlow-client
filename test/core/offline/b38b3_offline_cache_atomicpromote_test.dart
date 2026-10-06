// b38b3 —— `lib/core/offline/offline_cache_manager.dart` 补测。
//
// 未覆盖行（230 lcov）：288 / 291 —— `_atomicPromote` 的「rename 失败 → copy 兜底」
// 分支（288 `tmp.copy(target.path)`）与 `finally` 里清理 `.part` 临时文件（291）。
//
// 确定性触发：先正常写入创建目标文件，再删掉它并在**同一路径**建目录，
// 于是 `tmp.rename(target)`（文件→已存在目录）必失败、`tmp.copy(target)` 亦必失败，
// 从而进入 288 并在 finally 中执行 291 清理 tmp。用 rootForTest 注入临时根目录。
// 产品代码零改动；只读 lib。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';

void main() {
  late Directory base;
  late OfflineCacheManager m;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('ofc_b38b3');
    m = OfflineCacheManager(rootForTest: base);
    await m.init();
  });

  tearDown(() async {
    m.dispose();
    if (await base.exists()) await base.delete(recursive: true);
  });

  test('[D-061] rename 失败 → copy 兜底亦失败：降级不外抛，.part 仍被清理（291）', () async {
    final bytes = Uint8List.fromList(List.filled(16, 7));
    await m.putCover('c1', bytes, owners: ['s1']);

    final targetPath = m.coverFile('c1')!.path;
    // 把目标路径改成目录：rename(文件→目录) 与 copy(→目录) 都必然失败。
    await File(targetPath).delete();
    await Directory(targetPath).create();

    final partPath = '$targetPath.part';
    final partFile = File(partPath);

    // [D-061] 修复前：copy 亦失败时 FileSystemException 上抛（b38b3 实测），
    // 与「保证可用性」语义相悖。修复后：降级记日志、不外抛，putCover 正常完成。
    await m.putCover(
        'c1', Uint8List.fromList(List.filled(16, 8)), owners: ['s1']);

    // 291：finally 里清理了临时 .part 文件。
    expect(await partFile.exists(), isFalse,
        reason: 'promote 失败后应删除 .part 临时文件（291）');
  });
}
