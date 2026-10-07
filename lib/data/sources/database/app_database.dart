import 'package:drift/drift.dart';

import 'package:musicflow_client/data/sources/database/connection/connection.dart';
import 'package:musicflow_client/data/sources/database/tables/music_libraries_table.dart';
import 'package:musicflow_client/data/sources/database/tables/server_addresses_table.dart';
import 'package:musicflow_client/data/sources/database/tables/lyrics_provider_configs_table.dart';
import 'package:musicflow_client/data/sources/database/tables/cover_provider_configs_table.dart';
import 'package:musicflow_client/data/sources/database/tables/recommend_cache_table.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    MusicLibraries,
    ServerAddresses,
    LyricsProviderConfigs,
    CoverProviderConfigs,
    RecommendCaches,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(openConnection());

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _insertDefaultProviderConfigs();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(lyricsProviderConfigs);
        await m.createTable(coverProviderConfigs);
        await _insertDefaultProviderConfigs();
      }
      if (from < 5) {
        // 下载功能已整体移除：清理历史遗留的 download_tasks 表及其列。
        await customStatement('DROP TABLE IF EXISTS download_tasks');
      }
      if (from < 6) {
        // v6：新增推荐类首页数据缓存表（home cards / recommend /
        // local-recommend 的 KV-JSON 缓存）。
        await m.createTable(recommendCaches);
      }
    },
  );

  Future<void> _insertDefaultProviderConfigs() async {
    final lyricsDefaults = [
      LyricsProviderConfigsCompanion.insert(
        id: 'lyrics_subsonic',
        sourceId: 'subsonic',
        priority: 0,
      ),
      LyricsProviderConfigsCompanion.insert(
        id: 'lyrics_lrclib',
        sourceId: 'lrclib',
        priority: 1,
      ),
      LyricsProviderConfigsCompanion.insert(
        id: 'lyrics_netease',
        sourceId: 'netease',
        priority: 2,
      ),
    ];

    for (final config in lyricsDefaults) {
      await into(lyricsProviderConfigs).insertOnConflictUpdate(config);
    }

    final coverDefaults = [
      CoverProviderConfigsCompanion.insert(
        id: 'cover_subsonic',
        sourceId: 'subsonic',
        priority: 0,
      ),
      CoverProviderConfigsCompanion.insert(
        id: 'cover_musicbrainz',
        sourceId: 'musicbrainz',
        priority: 1,
      ),
      CoverProviderConfigsCompanion.insert(
        id: 'cover_fanart',
        sourceId: 'fanart',
        priority: 2,
      ),
    ];

    for (final config in coverDefaults) {
      await into(coverProviderConfigs).insertOnConflictUpdate(config);
    }
  }
}
