// b38b3 —— Route B：AppDatabase 迁移策略 onUpgrade 补测。
//
// lcov 未命中行 31-35（from<2 建提供商表 + 灌默认）与 37/39（from<5 清历史
// download_tasks）。生产里新装走 onCreate、老用户升级才走 onUpgrade，普通测试
// 建库都是全新库 → onUpgrade 从不执行。这里预置一个 `user_version=1` 的旧库
// 文件，再让 AppDatabase 打开同一路径，即触发 1→5 的升级分支。
//
// 产品代码零改动；仅新增 test/。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:musicflow_client/data/sources/database/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dirPath = '/tmp/mf_b38b3_app_database';

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

    // 预置旧库：仅声明 user_version=1，模拟「升级前」的库。
    final raw = sqlite3.open('$dirPath/db.sqlite');
    try {
      raw.execute('PRAGMA user_version = 1');
    } finally {
      raw.dispose();
    }
  });

  test('旧库(v1)打开 → onUpgrade 建提供商表、灌默认并清 download_tasks', () async {
    final db = AppDatabase();
    try {
      final lyrics = await db.select(db.lyricsProviderConfigs).get();
      final covers = await db.select(db.coverProviderConfigs).get();

      expect(
        lyrics.map((e) => e.sourceId),
        containsAll(<String>['subsonic', 'lrclib', 'netease']),
        reason: 'from<2 分支应创建并灌入歌词提供商默认行',
      );
      expect(
        covers.map((e) => e.sourceId),
        containsAll(<String>['subsonic', 'musicbrainz', 'fanart']),
        reason: 'from<2 分支应创建并灌入封面提供商默认行',
      );

      // from<5 分支：DROP TABLE IF EXISTS download_tasks 不应抛（表本就不存在）。
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='download_tasks'",
          )
          .get();
      expect(tables, isEmpty, reason: 'download_tasks 应已被清除');
    } finally {
      await db.close();
    }
  });
}
