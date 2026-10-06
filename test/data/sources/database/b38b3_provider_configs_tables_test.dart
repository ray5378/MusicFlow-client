// b38b3 —— drift 提供商配置表定义运行时覆盖补测。
//
// 与 b36c_database_tables_test.dart 同款：这两张表（LyricsProviderConfigs /
// CoverProviderConfigs）的列 getter 是 drift **代码生成输入**，运行时由
// app_database.g.dart 生成的子类覆盖，基类 getter 正常链路不会执行（直接调用
// Table.text()/integer() 会抛 `UnsupportedError`）。显式实例化基类并逐列访问
// getter（用 throwsUnsupportedError 包住），使每一行 getter 表达式被执行到，
// 清零这两个文件的未覆盖行，同时锁死列与主键契约。
//
// 产品代码零改动；只读 lib。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/database/tables/cover_provider_configs_table.dart';
import 'package:musicflow_client/data/sources/database/tables/lyrics_provider_configs_table.dart';

void _expectCodegenOnly(Iterable<Object? Function()> readers) {
  for (final read in readers) {
    expect(read, throwsUnsupportedError);
  }
}

void main() {
  test('LyricsProviderConfigs 全部列 getter 与主键 codegen-only', () {
    final table = LyricsProviderConfigs();
    _expectCodegenOnly(<Object? Function()>[
      () => table.id,
      () => table.sourceId,
      () => table.enabled,
      () => table.priority,
      () => table.config,
      () => table.primaryKey,
    ]);
  });

  test('CoverProviderConfigs 全部列 getter 与主键 codegen-only', () {
    final table = CoverProviderConfigs();
    _expectCodegenOnly(<Object? Function()>[
      () => table.id,
      () => table.sourceId,
      () => table.enabled,
      () => table.priority,
      () => table.config,
      () => table.primaryKey,
    ]);
  });

  test('DataClassName 契约：两张表均可实例化', () {
    expect(LyricsProviderConfigs(), isA<LyricsProviderConfigs>());
    expect(CoverProviderConfigs(), isA<CoverProviderConfigs>());
  });
}
