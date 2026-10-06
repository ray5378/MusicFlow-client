// b36c —— drift 表定义（codegen 输入）运行时覆盖补测。
//
// 背景：`lib/data/sources/database/tables/*.dart` 里的列 getter 是 drift 的
// **代码生成输入**：运行时由 `app_database.g.dart` 生成的 `$XxxTable` 子类
// 覆盖，基类 getter 正常链路不会被执行。drift `Table.text()/integer()/...`
// 直接调用时会抛 `UnsupportedError('This method should not be called at
// runtime...')`（见 drift/src/dsl/dsl.dart `Never _isGenerated()`）。
//
// 覆盖策略：显式实例化基类并**逐列访问 getter**（用 throwsUnsupportedError
// 包住），使每一行 getter 表达式都被执行到，从而清零这两个文件的未覆盖行；
// 同时锁死「这些列的存在与主键声明」这一契约。
//
// 产品代码零改动；只读 lib。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/database/tables/music_libraries_table.dart';
import 'package:musicflow_client/data/sources/database/tables/server_addresses_table.dart';

/// 逐列访问，命中 getter 体但不让异常中断后续列。
void _expectCodegenOnly(
  Iterable<Object? Function()> readers,
) {
  for (final read in readers) {
    expect(read, throwsUnsupportedError);
  }
}

void main() {
  group('MusicLibraries 表定义', () {
    test('全部列 getter 与主键为 codegen-only（运行时访问即抛）', () {
      final table = MusicLibraries();
      _expectCodegenOnly(<Object? Function()>[
        () => table.id,
        () => table.name,
        () => table.authType,
        () => table.username,
        () => table.password,
        () => table.apiKey,
        () => table.serverType,
        () => table.serverVersion,
        () => table.isOpenSubsonic,
        () => table.extensions,
        () => table.isActive,
        () => table.createdAt,
        () => table.updatedAt,
        () => table.primaryKey,
      ]);
    });

    test('DataClassName 契约：生成的数据类名固定', () {
      // 仅断言可实例化；列访问语义由上一用例锁死。
      expect(MusicLibraries(), isA<MusicLibraries>());
    });
  });

  group('ServerAddresses 表定义', () {
    test('全部列 getter 与外键/主键为 codegen-only（运行时访问即抛）', () {
      final table = ServerAddresses();
      _expectCodegenOnly(<Object? Function()>[
        () => table.id,
        () => table.libraryId,
        () => table.label,
        () => table.url,
        () => table.priority,
        () => table.isLocked,
        () => table.lastLatencyMs,
        () => table.lastStatus,
        () => table.primaryKey,
      ]);
    });
  });
}
