import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:musicflow_client/core/services/credentials_store.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/server_config.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/models/search_history.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/data/sources/prefs_gate.dart';

/// 本地存储封装（SharedPreferences）
class LocalStorage {
  static const String _logTag = 'LOCAL_STORAGE';
  static const String _keyServerConfig = 'server_config';
  static const String _keyAutoFallback = 'auto_fallback';
  static const String _keyAudioQualitySettings = 'audio_quality_settings';
  static const String _keyPlaybackMode = 'playback_mode';
  static const String _keyAutoPlayOnLaunch = 'auto_play_on_launch';
  static const String _keyPlaybackSession = 'playback_session_v1';
  static const String _keyThemeMode = 'theme_mode';
  static const String _keyThemeSeedColor = 'theme_seed_color';
  static const String _keyAppLanguage = 'app_language';
  static const String _keyMobileCacheSavedBytesByLibrary =
      'mobile_cache_saved_bytes_by_library_v1';
  static const String _keyMaxCacheSizeBytes = 'max_cache_size_bytes';
  static const String _keyHasLaunchedBefore = 'has_launched_before';
  static const String _keyCrossfadeDurationMs = 'crossfade_duration_ms';
  static const String _keyPlayerVolume = 'player_volume';
  static const String _keyStatusLyricsEnabled = 'status_lyrics_enabled';
  static const String _keyOfflineCacheSize = 'offline_cache_size';
  static const String _keyOfflineCacheEnabled = 'offline_cache_enabled';
  static const String _keyLyricsScrollDwellSeconds = 'lyrics_scroll_dwell_seconds';
  static const String _keyLoggingEnabled = 'logging_enabled';
  static const String _keySearchHistory = 'search_history_v1';
  static const String _keyHomeSectionLayout = 'home_section_layout_v1';

  /// 是否开启日志抓取（默认关闭，需用户手动开启）。
  static Future<bool> getLoggingEnabled() async {
    final prefs = await getPrefs();
    return prefs.getBool(_keyLoggingEnabled) ?? false;
  }

  /// 设置日志抓取开关。
  static Future<void> setLoggingEnabled(bool value) async {
    final prefs = await getPrefs();
    await prefs.setBool(_keyLoggingEnabled, value);
  }

  /// 是否开启 Windows 托盘/任务栏歌词(状态栏歌词)。
  static Future<bool> getStatusLyricsEnabled() async {
    final prefs = await getPrefs();
    return prefs.getBool(_keyStatusLyricsEnabled) ?? false;
  }

  /// 设置 Windows 托盘/任务栏歌词开关。
  static Future<void> setStatusLyricsEnabled(bool value) async {
    final prefs = await getPrefs();
    await prefs.setBool(_keyStatusLyricsEnabled, value);
  }


  /// 读取离线缓存总容量档位名（未设置返回 null，由调用方回落到默认 2G）。
  static Future<String?> getOfflineCacheSizeName() async {
    final prefs = await getPrefs();
    return prefs.getString(_keyOfflineCacheSize);
  }

  /// 保存离线缓存总容量档位名（enum.name）。
  static Future<void> setOfflineCacheSizeName(String name) async {
    final prefs = await getPrefs();
    await prefs.setString(_keyOfflineCacheSize, name);
  }

  /// 读取离线缓存开关（未设置默认开启，老用户行为不变）。
  static Future<bool> getOfflineCacheEnabled() async {
    final prefs = await getPrefs();
    return prefs.getBool(_keyOfflineCacheEnabled) ?? true;
  }

  /// 保存离线缓存开关。
  static Future<void> setOfflineCacheEnabled(bool value) async {
    final prefs = await getPrefs();
    await prefs.setBool(_keyOfflineCacheEnabled, value);
  }

  /// 是否曾经启动过（用于判断是否显示开屏动画）
  static Future<bool> hasLaunchedBefore() async {
    final prefs = await getPrefs();
    return prefs.getBool(_keyHasLaunchedBefore) ?? false;
  }

  /// 标记已完成首次启动
  static Future<void> setHasLaunchedBefore() async {
    final prefs = await getPrefs();
    await prefs.setBool(_keyHasLaunchedBefore, true);
    Logger.infoWithTag(_logTag, 'hasLaunchedBefore set to true');
  }

  /// 读取搜索历史(已按时间倒序,空词/过期项由调用方用
  /// [pruneSearchHistory] 清理后写入)。文件缺失或损坏时返回空列表。
  static Future<List<SearchHistoryEntry>> getSearchHistory() async {
    final prefs = await getPrefs();
    final raw = prefs.getString(_keySearchHistory);
    if (raw == null || raw.isEmpty) return const <SearchHistoryEntry>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        Logger.warnWithTag(_logTag, 'invalid search history payload type');
        return const <SearchHistoryEntry>[];
      }
      return <SearchHistoryEntry>[
        for (final item in decoded)
          if (item is Map)
            SearchHistoryEntry.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
      ];
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to parse search history', e);
      return const <SearchHistoryEntry>[];
    }
  }

  /// 保存搜索历史(覆盖写)。
  static Future<void> saveSearchHistory(
    List<SearchHistoryEntry> entries,
  ) async {
    final prefs = await getPrefs();
    final json = jsonEncode(
      entries.map((entry) => entry.toJson()).toList(growable: false),
    );
    await prefs.setString(_keySearchHistory, json);
  }

  /// 清除搜索历史。
  static Future<void> clearSearchHistory() async {
    final prefs = await getPrefs();
    await prefs.remove(_keySearchHistory);
  }

  /// 读取首页分区用户布局（顺序 + 显隐）。
  /// 未自定义或 payload 损坏时返回 null（回落服务端清单，等价 [HomeSectionLayout.empty]）。
  static Future<HomeSectionLayout?> getHomeSectionLayout() async {
    final prefs = await getPrefs();
    final raw = prefs.getString(_keyHomeSectionLayout);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        Logger.warnWithTag(_logTag, 'invalid home section layout payload type');
        return null;
      }
      return HomeSectionLayout.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to parse home section layout', e);
      return null;
    }
  }

  /// 保存首页分区用户布局（覆盖写，小 JSON，符合 prefs「只放小设置」约束）。
  static Future<void> saveHomeSectionLayout(HomeSectionLayout layout) async {
    final prefs = await getPrefs();
    await prefs.setString(
      _keyHomeSectionLayout,
      jsonEncode(layout.toJson()),
    );
    Logger.infoWithTag(_logTag, 'home section layout saved');
  }

  /// 清除首页分区用户布局（恢复完全遵循服务端清单）。
  static Future<void> clearHomeSectionLayout() async {
    final prefs = await getPrefs();
    await prefs.remove(_keyHomeSectionLayout);
  }

  /// 保存服务器配置。
  ///
  /// 凭据（password/apiKey）移入系统钥匙串（CredentialsStore，
  /// Windows DPAPI / Android Keystore 加密），SharedPreferences 只落非敏感配置。
  static Future<void> saveServerConfig(ServerConfig config) async {
    await CredentialsStore.writeAll(
      CredentialsStore.scopeServerConfig,
      'main',
      {'password': config.password, 'apiKey': config.apiKey},
    );
    final prefs = await getPrefs();
    final sanitized = Map<String, dynamic>.from(config.toJson())
      ..['password'] = null
      ..['apiKey'] = null;
    await prefs.setString(_keyServerConfig, jsonEncode(sanitized));
    Logger.infoWithTag(_logTag, 'server config saved');
  }

  /// 读取服务器配置（凭据从钥匙串回填；旧版本明文残留自动迁移进钥匙串）。
  static Future<ServerConfig?> getServerConfig() async {
    final prefs = await getPrefs();
    final json = prefs.getString(_keyServerConfig);
    if (json == null) {
      Logger.debugWithTag(_logTag, 'server config not found');
      return null;
    }

    try {
      final map = Map<String, dynamic>.from(jsonDecode(json) as Map);
      // 旧版本迁移：prefs 里残留的明文凭据 → 移入钥匙串并从 prefs 清除。
      if (map['password'] != null || map['apiKey'] != null) {
        await CredentialsStore.writeAll(
          CredentialsStore.scopeServerConfig,
          'main',
          {
            'password': map['password'] as String?,
            'apiKey': map['apiKey'] as String?,
          },
        );
        map['password'] = null;
        map['apiKey'] = null;
        await prefs.setString(_keyServerConfig, jsonEncode(map));
        Logger.infoWithTag(
          _logTag,
          'migrated plaintext credentials to secure storage',
        );
      }
      // 从钥匙串回填凭据。
      final creds = await CredentialsStore.readAll(
        CredentialsStore.scopeServerConfig,
        'main',
        const ['password', 'apiKey'],
      );
      map['password'] = creds['password'];
      map['apiKey'] = creds['apiKey'];
      Logger.debugWithTag(_logTag, 'server config loaded');
      return ServerConfig.fromJson(map);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to parse server config', e);
      return null;
    }
  }

  /// 删除服务器配置（登出）：连同钥匙串中的凭据一并清除。
  static Future<void> clearServerConfig() async {
    await CredentialsStore.deleteAll(
      CredentialsStore.scopeServerConfig,
      'main',
      const ['password', 'apiKey'],
    );
    final prefs = await getPrefs();
    await prefs.remove(_keyServerConfig);
    Logger.infoWithTag(_logTag, 'server config cleared');
  }

  /// 检查是否有已保存的配置
  static Future<bool> hasServerConfig() async {
    final prefs = await getPrefs();
    final result = prefs.containsKey(_keyServerConfig);
    Logger.debugWithTag(_logTag, 'hasServerConfig=$result');
    return result;
  }

  /// 读取自动回退开关（默认开启）
  static Future<bool> getAutoFallback() async {
    final prefs = await getPrefs();
    final value = prefs.getBool(_keyAutoFallback) ?? true;
    Logger.debugWithTag(_logTag, 'autoFallback=$value');
    return value;
  }

  /// 保存自动回退开关
  static Future<void> setAutoFallback(bool value) async {
    final prefs = await getPrefs();
    await prefs.setBool(_keyAutoFallback, value);
    Logger.infoWithTag(_logTag, 'autoFallback updated: $value');
  }

  /// 读取音质设置
  static Future<AudioQualitySettings> getAudioQualitySettings() async {
    final prefs = await getPrefs();
    final json = prefs.getString(_keyAudioQualitySettings);
    if (json == null) {
      Logger.debugWithTag(
        _logTag,
        'audio quality settings not found, use default',
      );
      return const AudioQualitySettings();
    }

    try {
      Logger.debugWithTag(_logTag, 'audio quality settings loaded');
      return AudioQualitySettings.fromJsonString(json);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to parse audio quality settings', e);
      return const AudioQualitySettings();
    }
  }

  /// 保存音质设置
  static Future<void> setAudioQualitySettings(
    AudioQualitySettings settings,
  ) async {
    final prefs = await getPrefs();
    await prefs.setString(_keyAudioQualitySettings, settings.toJsonString());
    Logger.infoWithTag(_logTag, 'audio quality settings saved');
  }

  /// 读取播放模式（shuffle / repeatAll / repeatOne）
  static Future<String> getPlaybackMode() async {
    final prefs = await getPrefs();
    final mode = prefs.getString(_keyPlaybackMode);
    if (mode == null) {
      Logger.debugWithTag(_logTag, 'playback mode not found, use default');
      return 'all';
    }

    switch (mode) {
      case 'shuffle':
      case 'all':
      case 'one':
      case 'order':
        Logger.debugWithTag(_logTag, 'playback mode loaded: $mode');
        return mode;
      case 'repeatAll':
      case 'repeatOne':
        // 旧版持久化枚举名(repeatAll/repeatOne)→ 线上值(all/one)。
        // 缺了这步映射,老用户升级后播放模式会被重置成默认值。
        final mapped = mode == 'repeatAll' ? 'all' : 'one';
        Logger.debugWithTag(_logTag, 'playback mode migrated: $mode -> $mapped');
        return mapped;
      default:
        Logger.warnWithTag(_logTag, 'invalid playback mode in storage: $mode');
        return 'all';
    }
  }

  /// 保存播放模式（shuffle / repeatAll / repeatOne）
  static Future<void> setPlaybackMode(String mode) async {
    final prefs = await getPrefs();
    await prefs.setString(_keyPlaybackMode, mode);
    Logger.infoWithTag(_logTag, 'playback mode saved: $mode');
  }

  /// 读取「打开时自动播放上次本机音乐」设置（默认 false）
  static Future<bool> getAutoPlayOnLaunch() async {
    final prefs = await getPrefs();
    final value = prefs.getBool(_keyAutoPlayOnLaunch) ?? false;
    Logger.debugWithTag(_logTag, 'autoPlayOnLaunch=$value');
    return value;
  }

  /// 保存「打开时自动播放上次本机音乐」设置
  static Future<void> setAutoPlayOnLaunch(bool value) async {
    final prefs = await getPrefs();
    await prefs.setBool(_keyAutoPlayOnLaunch, value);
    Logger.infoWithTag(_logTag, 'autoPlayOnLaunch updated: $value');
  }

  /// 保存播放会话（队列 + 索引 + 进度 + 播放状态）。
  ///
  /// 走 JsonFileStore（独立文件+原子写）而非 prefs：本方法每 5 秒节流调用，
  /// 若走 prefs，Windows 实现会把整个 prefs 全量序列化+同步重写——历史上一条
  /// metadata 键膨胀到 87MB 时，正是这里把平台线程持续烧满导致滚动假死。
  static Future<void> savePlaybackSession(Map<String, dynamic> session) async {
    await JsonFileStore.instance.writeString(
      _keyPlaybackSession,
      jsonEncode(session),
    );
    Logger.debugWithTag(_logTag, 'playback session saved');
  }

  /// 读取播放会话
  static Future<Map<String, dynamic>?> getPlaybackSession() async {
    final raw = await JsonFileStore.instance.readString(_keyPlaybackSession);
    if (raw == null || raw.isEmpty) {
      Logger.debugWithTag(_logTag, 'playback session not found');
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      Logger.warnWithTag(_logTag, 'invalid playback session payload type');
      return null;
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to parse playback session', e);
      return null;
    }
  }

  /// 清除播放会话
  static Future<void> clearPlaybackSession() async {
    await JsonFileStore.instance.remove(_keyPlaybackSession);
    Logger.debugWithTag(_logTag, 'playback session cleared');
  }

  /// 读取主题模式（system / light / dark）
  static Future<String> getThemeModeSetting() async {
    final prefs = await getPrefs();
    final mode = prefs.getString(_keyThemeMode) ?? 'system';
    switch (mode) {
      case 'light':
      case 'dark':
      case 'system':
        Logger.debugWithTag(_logTag, 'theme mode loaded: $mode');
        return mode;
      default:
        Logger.warnWithTag(_logTag, 'invalid theme mode in storage: $mode');
        return 'system';
    }
  }

  /// 保存主题模式（system / light / dark）
  static Future<void> setThemeModeSetting(String mode) async {
    final prefs = await getPrefs();
    await prefs.setString(_keyThemeMode, mode);
    Logger.infoWithTag(_logTag, 'theme mode saved: $mode');
  }

  /// 读取主题主色（ARGB int）
  static Future<int> getThemeSeedColorValue() async {
    final prefs = await getPrefs();
    final color = prefs.getInt(_keyThemeSeedColor) ?? 0xFF4CAF50;
    Logger.debugWithTag(
      _logTag,
      'theme seed color loaded: 0x${color.toRadixString(16)}',
    );
    return color;
  }

  /// 读取界面语言（system / zh / en，默认 zh，非法值回退 zh）。
  static Future<String> getAppLanguage() async {
    final prefs = await getPrefs();
    final lang = prefs.getString(_keyAppLanguage) ?? 'zh';
    switch (lang) {
      case 'system':
      case 'zh':
      case 'en':
        Logger.debugWithTag(_logTag, 'app language loaded: ');
        return lang;
      default:
        Logger.warnWithTag(_logTag, 'invalid app language in storage: ');
        return 'zh';
    }
  }

  /// 保存界面语言（system / zh / en）。
  static Future<void> setAppLanguage(String lang) async {
    final prefs = await getPrefs();
    await prefs.setString(_keyAppLanguage, lang);
    Logger.infoWithTag(_logTag, 'app language saved: ');
  }

  /// 保存主题主色（ARGB int）
  static Future<void> setThemeSeedColorValue(int color) async {
    final prefs = await getPrefs();
    await prefs.setInt(_keyThemeSeedColor, color);
    Logger.infoWithTag(
      _logTag,
      'theme seed color saved: 0x${color.toRadixString(16)}',
    );
  }

  /// 读取指定音乐库的“移动网络缓存命中节省流量”累计值（字节）
  static Future<int> getMobileCacheSavedBytes({
    required String libraryId,
  }) async {
    if (libraryId.trim().isEmpty) return 0;

    final prefs = await getPrefs();
    final raw = prefs.getString(_keyMobileCacheSavedBytesByLibrary);
    if (raw == null || raw.isEmpty) return 0;

    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return _parsePositiveInt(map[libraryId]);
    } catch (e) {
      Logger.warnWithTag(
        _logTag,
        'failed to parse mobile cache saved bytes map',
        e,
      );
      return 0;
    }
  }

  /// 增加指定音乐库的“移动网络缓存命中节省流量”累计值（字节）
  static Future<void> addMobileCacheSavedBytes({
    required String libraryId,
    required int bytes,
  }) async {
    final normalizedLibraryId = libraryId.trim();
    if (normalizedLibraryId.isEmpty || bytes <= 0) return;

    final prefs = await getPrefs();
    final raw = prefs.getString(_keyMobileCacheSavedBytesByLibrary);

    Map<String, dynamic> map = <String, dynamic>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          map = decoded;
        } else if (decoded is Map) {
          map = decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (e) {
        Logger.warnWithTag(
          _logTag,
          'failed to parse existing mobile cache saved bytes map',
          e,
        );
      }
    }

    final current = _parsePositiveInt(map[normalizedLibraryId]);
    final next = current + bytes;
    map[normalizedLibraryId] = next;
    await prefs.setString(_keyMobileCacheSavedBytesByLibrary, jsonEncode(map));
    Logger.infoWithTag(
      _logTag,
      'mobile cache saved bytes +$bytes library=$normalizedLibraryId total=$next',
    );
  }

  static int _parsePositiveInt(Object? value) {
    if (value is int) return value < 0 ? 0 : value;
    if (value is double) {
      final converted = value.floor();
      return converted < 0 ? 0 : converted;
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < 0) return 0;
      return parsed;
    }
    return 0;
  }

  /// 读取音频缓存上限设置（字节）
  static Future<int?> getMaxCacheSize() async {
    final prefs = await getPrefs();
    final value = prefs.getInt(_keyMaxCacheSizeBytes);
    if (value != null) {
      Logger.debugWithTag(_logTag, 'maxCacheSize loaded: $value');
    }
    return value;
  }

  /// 保存音频缓存上限设置（字节）
  static Future<void> setMaxCacheSize(int bytes) async {
    final prefs = await getPrefs();
    await prefs.setInt(_keyMaxCacheSizeBytes, bytes);
    Logger.infoWithTag(_logTag, 'maxCacheSize saved: $bytes');
  }

  /// 读取淡入淡出时长（毫秒，0 = 关闭）
  static Future<int> getCrossfadeDurationMs() async {
    final prefs = await getPrefs();
    final value = prefs.getInt(_keyCrossfadeDurationMs) ?? 0;
    Logger.debugWithTag(_logTag, 'crossfadeDurationMs loaded: $value');
    return value;
  }

  /// 保存淡入淡出时长（毫秒）
  static Future<void> setCrossfadeDurationMs(int ms) async {
    final prefs = await getPrefs();
    await prefs.setInt(_keyCrossfadeDurationMs, ms);
    Logger.infoWithTag(_logTag, 'crossfadeDurationMs saved: $ms');
  }

  /// 读取歌词停下跟随滚动的停靠时长（秒，默认 3）
  static Future<int> getLyricsScrollDwellSeconds() async {
    final prefs = await getPrefs();
    final value = prefs.getInt(_keyLyricsScrollDwellSeconds) ?? 3;
    Logger.debugWithTag(_logTag, 'lyricsScrollDwellSeconds loaded: $value');
    return value;
  }

  /// 保存歌词停靠时长（秒）
  static Future<void> setLyricsScrollDwellSeconds(int seconds) async {
    final prefs = await getPrefs();
    await prefs.setInt(_keyLyricsScrollDwellSeconds, seconds);
    Logger.infoWithTag(
      _logTag,
      'lyricsScrollDwellSeconds saved: $seconds',
    );
  }

  /// 读取本机播放音量（0.0~1.0，默认 0.8）。
  /// 走 JsonFileStore：随播放会话周期反复落盘，不应触发 prefs 全量重写。
  static Future<double> getPlayerVolume() async {
    final raw = await JsonFileStore.instance.readString(_keyPlayerVolume);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final value = decoded['v'];
          if (value is num) {
            final volume = value.toDouble().clamp(0.0, 1.0).toDouble();
            Logger.debugWithTag(_logTag, 'playerVolume loaded: $volume');
            return volume;
          }
        }
      } catch (e) {
        Logger.warnWithTag(_logTag, 'failed to parse player volume', e);
      }
    }
    return 0.8;
  }

  /// 保存本机播放音量（0.0~1.0）
  static Future<void> setPlayerVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0).toDouble();
    await JsonFileStore.instance.writeString(
      _keyPlayerVolume,
      jsonEncode(<String, Object?>{'v': clamped}),
    );
    Logger.infoWithTag(_logTag, 'playerVolume saved: $clamped');
  }

  /// 修复损坏的 SharedPreferences 文件。
  ///
  /// 进程被强杀/崩溃时 shared_preferences.json 可能处于半写状态(全 NUL 或截断),
  /// 之后 `getInstance()` 抛错 → 所有设置(服务器配置/播放进度/音量等)全部读
  /// 默认值,表现为「关闭后全部清空」。这里把损坏文件备份为 `.corrupt-*` 后
  /// 重建干净起点。必须在 runApp 之后调用(平台通道已注册,runApp 前 await
  /// 会永久挂起)。
  static Future<void> repairCorruptPreferences() async {
    try {
      await getPrefs();
      return; // 文件健康
    } catch (e) {
      Logger.warnWithTag(_logTag, 'preferences broken, repairing: $e');
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}shared_preferences.json',
      );
      if (file.existsSync()) {
        final backup =
            '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
        await file.rename(backup);
        Logger.warnWithTag(_logTag, 'corrupt preferences backed up: $backup');
      }
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to back up corrupt preferences', e);
    }
    // 删除损坏文件后重试一次:应能正常初始化空配置。
    try {
      await getPrefs();
    } catch (e) {
      Logger.warnWithTag(_logTag, 'preferences still broken after repair', e);
    }
  }
}
