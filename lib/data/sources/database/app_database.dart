import 'package:drift/drift.dart';

import 'connection/connection.dart';
import 'tables/music_libraries_table.dart';
import 'tables/server_addresses_table.dart';
import 'tables/lyrics_provider_configs_table.dart';
import 'tables/cover_provider_configs_table.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    MusicLibraries,
    ServerAddresses,
    LyricsProviderConfigs,
    CoverProviderConfigs,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(openConnection());

  @override
  int get schemaVersion => 5;

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
