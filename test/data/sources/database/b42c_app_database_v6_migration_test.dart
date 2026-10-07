// b42c —— drift schema v6 迁移测试：v5 旧库升级到 v6 不丢旧表数据。
//
// v6 新增 recommend_caches（推荐类首页数据 KV-JSON 缓存表）。老用户升级时走
// onUpgrade 的 from<6 分支建表；本测试预置一个 user_version=5、music_libraries
// 已有数据的旧库文件，再用 AppDatabase 打开同一路径，验证：
//   1) 旧表数据完整保留；
//   2) recommend_caches 表已创建且可正常读写。
//
// 参考范式：b38b3_app_database_migration_test.dart。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:musicflow_client/data/sources/database/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dirPath = '/tmp/mf_b42c_app_database_v6';

  // AppDatabase 的 LazyDatabase 走 getApplicationDocumentsDirectory，
  // 必须 mock path_provider 通道（名字为 'plugins.flutter.io/path_provider'）。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => dirPath,
  );

  setUpAll(() {
    final dir = Directory(dirPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);

    // 预置 v5 旧库：music_libraries 表（v5 schema）+ 一行既有数据，
    // 并把 user_version 标为 5，模拟「升级前」的真实库。
    final raw = sqlite3.open('$dirPath/db.sqlite');
    try {
      raw.execute('''
        CREATE TABLE music_libraries (
          id TEXT NOT NULL PRIMARY KEY,
          name TEXT NOT NULL,
          auth_type TEXT NOT NULL DEFAULT 'token',
          username TEXT NULL,
          password TEXT NULL,
          api_key TEXT NULL,
          server_type TEXT NULL,
          server_version TEXT NULL,
          is_open_subsonic INTEGER NOT NULL DEFAULT 0,
          extensions TEXT NULL,
          is_active INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      raw.execute(
        "INSERT INTO music_libraries (id, name, auth_type, is_active, "
        "created_at, updated_at) VALUES "
        "('lib-old', '旧库', 'token', 1, 1700000000000, 1700000000000)",
      );
      raw.execute('PRAGMA user_version = 5');
    } finally {
      raw.dispose();
    }
  });

  test('v5 旧库打开 → 升级到 v6：旧表数据保留、recommend_caches 建成可用',
      () async {
    final db = AppDatabase();
    try {
      // 1) 旧表数据不丢。
      final libs = await db.select(db.musicLibraries).get();
      expect(libs, hasLength(1), reason: 'v5→v6 升级不应清空 music_libraries');
      expect(libs.single.id, 'lib-old');
      expect(libs.single.name, '旧库');
      expect(libs.single.isActive, isTrue);

      // 2) 新表已创建：读写 roundtrip。
      await db.into(db.recommendCaches).insertOnConflictUpdate(
            RecommendCachesCompanion.insert(
              scope: 'home_cards:lib-old',
              payload: '{"cards":[]}',
              cachedAt: 1700000001000,
            ),
          );
      final row = await (db.select(db.recommendCaches)
            ..where((t) => t.scope.equals('home_cards:lib-old')))
          .getSingleOrNull();
      expect(row, isNotNull, reason: 'from<6 分支应创建 recommend_caches 表');
      expect(row!.payload, '{"cards":[]}');
    } finally {
      await db.close();
    }
  });
}
