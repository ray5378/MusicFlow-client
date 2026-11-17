import 'dart:convert';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/repositories/lyrics_repository.dart';
import 'package:musicflow_client/data/repositories/cover_repository.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:musicflow_client/data/sources/database/database_provider.dart';
import 'package:musicflow_client/data/sources/lyrics/lyrics_source.dart';
import 'package:musicflow_client/data/sources/lyrics/subsonic_lyrics_source.dart';
import 'package:musicflow_client/data/sources/lyrics/lrclib_lyrics_source.dart';
import 'package:musicflow_client/data/sources/lyrics/netease_lyrics_source.dart';
import 'package:musicflow_client/data/sources/lyrics/custom_lyrics_source.dart';
import 'package:musicflow_client/data/sources/covers/cover_source.dart';
import 'package:musicflow_client/data/sources/covers/subsonic_cover_source.dart';
import 'package:musicflow_client/data/sources/covers/fanart_cover_source.dart';
import 'package:musicflow_client/data/sources/covers/musicbrainz_cover_source.dart';
import 'package:musicflow_client/data/sources/covers/custom_cover_source.dart';
import 'package:musicflow_client/core/utils/lrc_parser.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/api/gd_music_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

// ======== 提供商配置 Providers ========

final lyricsProviderConfigsProvider = StreamProvider<List<ProviderConfig>>((
  ref,
) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(
    db.lyricsProviderConfigs,
  )..orderBy([(t) => OrderingTerm.asc(t.priority)])).watch().map(
    (rows) => rows
        .map(
          (r) => ProviderConfig(
            id: r.id,
            sourceId: r.sourceId,
            enabled: r.enabled,
            priority: r.priority,
            config: r.config != null
                ? jsonDecode(r.config!) as Map<String, dynamic>?
                : null,
          ),
        )
        .toList(),
  );
});

final coverProviderConfigsProvider = StreamProvider<List<ProviderConfig>>((
  ref,
) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(
    db.coverProviderConfigs,
  )..orderBy([(t) => OrderingTerm.asc(t.priority)])).watch().map(
    (rows) => rows
        .map(
          (r) => ProviderConfig(
            id: r.id,
            sourceId: r.sourceId,
            enabled: r.enabled,
            priority: r.priority,
            config: r.config != null
                ? jsonDecode(r.config!) as Map<String, dynamic>?
                : null,
          ),
        )
        .toList(),
  );
});

// ======== 歌词相关 Providers ========

LyricsSource _createLyricsSource(
  String sourceId,
  Map<String, dynamic>? config,
  SubsonicLyricsSource subsonicSource,
) {
  switch (sourceId) {
    case 'subsonic':
      return subsonicSource;
    case 'lrclib':
      return LrclibLyricsSource();
    case 'netease':
      return NeteaseLyricsSource();
    case 'custom':
      final urlTemplate = config?['url'] as String? ?? '';
      return CustomLyricsSource(urlTemplate: urlTemplate);
    default:
      return LrclibLyricsSource();
  }
}

List<String> _extractOpenSubsonicExtensions(
  Map<String, dynamic>? extensionsMap,
) {
  if (extensionsMap == null || extensionsMap.isEmpty) return const [];

  // Current persisted shape: {'supported': ['songLyrics', ...], 'serverFingerprint': ...}
  final supported = extensionsMap['supported'];
  if (supported is List) {
    return supported.whereType<String>().toList();
  }

  // Backward-compat fallback: extension names stored as top-level keys.
  return extensionsMap.keys
      .where((k) => k != 'supported' && k != 'serverFingerprint')
      .toList();
}

final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  final apiClient = ref.watch(subsonicApiClientProvider);
  final activeLib = ref.watch(activeLibraryProvider);
  final configs = ref.watch(lyricsProviderConfigsProvider).valueOrNull ?? [];

  final extensions = _extractOpenSubsonicExtensions(activeLib?.extensions);
  final subsonicSource = SubsonicLyricsSource(apiClient, extensions);

  final sources = configs
      .where((c) => c.enabled)
      .map((c) => _createLyricsSource(c.sourceId, c.config, subsonicSource))
      .toList();

  return LyricsRepository(sources: sources);
});

final currentLyricsProvider = FutureProvider<Lyrics?>((ref) async {
  // 只监听「当前歌 id」变化，不监听播放位置等其他状态
  // 避免每次 position 更新（~200ms）都重新拉取歌词。
  //
  // 歌取 [effectiveCurrentSongProvider]：投屏/直投时就是**目标设备正在播的那首**，
  // 不依赖本机队列镜像的落地时机（镜像晚一两拍时，用本机 currentSong 会把上一首
  // 的歌词挂到设备那首歌上）。本机播放时它与 playerProvider.currentSong 等价。
  // 订阅只取 id：投屏轮询每 2s 重建一次 Song 对象，watch 整个对象会反复重拉歌词。
  final songId = ref.watch(effectiveCurrentSongProvider.select((s) => s?.id));
  if (songId == null) return null;
  final song = ref.read(effectiveCurrentSongProvider);
  if (song == null) return null;

  // 离线回退：优先读本地缓存。歌词键带 libraryId 隔离多库（同 id 不串库）。
  if (ref.read(isOfflineProvider)) {
    final cache = ref.read(offlineCacheManagerProvider);
    await ref.read(offlineCacheReadyProvider.future);
    final libId = ref.read(activeLibraryProvider)?.id ?? '';
    final cached = await cache.lyrics(
      OfflineCacheManager.lyricsKey(libId, song.id),
    );
    if (cached != null && cached.isNotEmpty) {
      try {
        return Lyrics.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      } catch (_) {
        // 缓存损坏视为无缓存。
      }
    }
  }

  if (song.isPreview) {
    final source = song.previewSource?.trim() ?? '';
    final lyricId = (song.previewLyricId ?? song.previewTrackId ?? '').trim();
    if (source.isNotEmpty && lyricId.isNotEmpty) {
      try {
        final client = ref.watch(gdMusicApiClientProvider);
        final lyric = await client.fetchLyrics(
          source: source,
          lyricId: lyricId,
        );
        if (lyric != null && lyric.lyric.trim().isNotEmpty) {
          final entries = [LrcParser.parse(lyric.lyric)];
          final tlyric = lyric.translation?.trim();
          if (tlyric != null && tlyric.isNotEmpty) {
            entries.add(LrcParser.parse(tlyric));
          }
          return Lyrics(sourceId: 'gd_$source', entries: entries);
        }
      } catch (_) {
        // 试听歌词失败后回退到常规歌词源，尽量保证可用性。
      }
    }
  }

  final repo = ref.watch(lyricsRepositoryProvider);
  final lyrics = await repo.getLyrics(
    songId: song.id,
    title: song.title,
    artist: song.artist ?? '',
    album: song.album,
    duration: song.duration != null ? Duration(seconds: song.duration!) : null,
  );

  // 在线取到歌词后写入离线缓存（以歌曲为准，键带 libraryId 隔离多库）。
  if (lyrics != null && !lyrics.isEmpty && !song.isPreview) {
    final cache = ref.read(offlineCacheManagerProvider);
    await ref.read(offlineCacheReadyProvider.future);
    final libId = ref.read(activeLibraryProvider)?.id ?? '';
    unawaited(
      cache.putLyrics(
        OfflineCacheManager.lyricsKey(libId, song.id),
        jsonEncode(lyrics.toJson()),
      ),
    );
  }

  return lyrics;
});

// ======== 封面相关 Providers ========

CoverSource _createCoverSource(
  String sourceId,
  Map<String, dynamic>? config,
  SubsonicCoverSource subsonicSource,
) {
  switch (sourceId) {
    case 'subsonic':
      return subsonicSource;
    case 'fanart':
      final apiKey = config?['apiKey'] as String? ?? '';
      return FanartCoverSource(apiKey: apiKey);
    case 'musicbrainz':
      return MusicbrainzCoverSource();
    case 'custom':
      final urlTemplate = config?['url'] as String? ?? '';
      return CustomCoverSource(urlTemplate: urlTemplate);
    default:
      return subsonicSource;
  }
}

final coverRepositoryProvider = Provider<CoverRepository>((ref) {
  final apiClient = ref.watch(subsonicApiClientProvider);
  final configs = ref.watch(coverProviderConfigsProvider).valueOrNull ?? [];

  final subsonicSource = SubsonicCoverSource(apiClient);

  final sources = configs
      .where((c) => c.enabled)
      .map((c) => _createCoverSource(c.sourceId, c.config, subsonicSource))
      .toList();

  return CoverRepository(sources: sources);
});

// ======== 提供商配置管理 ========

Future<void> updateLyricsProviderOrder(
  AppDatabase db,
  List<ProviderConfig> configs,
) async {
  for (int i = 0; i < configs.length; i++) {
    await (db.update(db.lyricsProviderConfigs)
          ..where((t) => t.id.equals(configs[i].id)))
        .write(LyricsProviderConfigsCompanion(priority: Value(i)));
  }
}

Future<void> updateCoverProviderOrder(
  AppDatabase db,
  List<ProviderConfig> configs,
) async {
  for (int i = 0; i < configs.length; i++) {
    await (db.update(db.coverProviderConfigs)
          ..where((t) => t.id.equals(configs[i].id)))
        .write(CoverProviderConfigsCompanion(priority: Value(i)));
  }
}

Future<void> toggleLyricsProvider(
  AppDatabase db,
  String id,
  bool enabled,
) async {
  await (db.update(db.lyricsProviderConfigs)..where((t) => t.id.equals(id)))
      .write(LyricsProviderConfigsCompanion(enabled: Value(enabled)));
}

Future<void> toggleCoverProvider(
  AppDatabase db,
  String id,
  bool enabled,
) async {
  await (db.update(db.coverProviderConfigs)..where((t) => t.id.equals(id)))
      .write(CoverProviderConfigsCompanion(enabled: Value(enabled)));
}

Future<void> updateCoverProviderConfig(
  AppDatabase db,
  String id,
  Map<String, dynamic>? config,
) async {
  final hasValidEntry =
      config != null &&
      config.values.any((v) {
        if (v == null) return false;
        if (v is String) return v.trim().isNotEmpty;
        return true;
      });
  await (db.update(
    db.coverProviderConfigs,
  )..where((t) => t.id.equals(id))).write(
    CoverProviderConfigsCompanion(
      config: Value(hasValidEntry ? jsonEncode(config) : null),
    ),
  );
}

/// 按播放进度在同步歌词里二分出当前行（纯函数）。
///
/// 三个消费方共用同一判据，避免各写一份二分导致「通知栏与 App 内歌词不同步」：
/// [currentLyricLineProvider]（迷你条 / 桌面歌词窗）、通知栏歌词控制器
/// （后台自持时钟推进，见 notification_lyrics_provider）。
///
/// 无歌词 / 无同步歌词 / 该行文本为空 → null，调用方自行决定回落行为。
String? lyricLineAt(Lyrics? lyrics, Duration position) {
  if (lyrics == null) return null;

  final best = lyrics.getBest();
  if (best == null || !best.synced || best.lines.isEmpty) return null;

  final lines = best.lines;
  final offset = best.offsetMs;
  final currentMs = position.inMilliseconds;
  var result = 0;
  var low = 0;
  var high = lines.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final start = (lines[middle].startMs ?? 0) + offset;
    if (currentMs >= start) {
      result = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  final value = lines[result].value.trim();
  return value.isEmpty ? null : value;
}

/// 当前播放进度的「滚动歌词」单行文本，对齐主项目前端的
/// `playerStore.currentLyricLine`（迷你播放器副标题处展示当前歌词）。
/// 无同步歌词 / 未加载完成时返回 null，调用方应回退到歌手名。
final currentLyricLineProvider = Provider<String?>((ref) {
  return lyricLineAt(
    ref.watch(currentLyricsProvider).valueOrNull,
    ref.watch(effectivePositionProvider),
  );
});
