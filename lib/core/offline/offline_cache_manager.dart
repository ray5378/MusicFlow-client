import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 缓存条目类型。
enum OfflineCacheKind { song, cover, lyric, playlistCover }

/// 一条缓存索引记录。
class _CacheEntry {
  final OfflineCacheKind kind;
  final String key;
  final int size;
  int lastAccessMs;
  /// 归属的歌曲 id 集合（仅 cover 使用）：歌曲被清时，仅归属它的封面一并删除。
  final List<String> owners;

  _CacheEntry({
    required this.kind,
    required this.key,
    required this.size,
    required this.lastAccessMs,
    List<String>? owners,
  }) : owners = owners ?? const [];

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'key': key,
        'size': size,
        'lastAccessMs': lastAccessMs,
        if (owners.isNotEmpty) 'owners': owners,
      };

  factory _CacheEntry.fromJson(Map<String, dynamic> json) => _CacheEntry(
        kind: OfflineCacheKind.values.asNameMap()[json['kind']] ??
            OfflineCacheKind.song,
        key: json['key'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        lastAccessMs: json['lastAccessMs'] as int? ?? 0,
        owners: (json['owners'] as List?)?.cast<String>() ?? const [],
      );

  String get compositeKey => '${kind.name}:$key';
}

/// 离线缓存管理器：歌曲/封面/歌词/歌单封面，共用单一总容量，LRU 轮转。
///
/// 缓存索引为 `<appSupport>/offline_cache/index.json`，数据文件按类分目录存放。
/// 缓存属可丢弃的临时态，不并入 drift。
///
/// 归属规则：歌词、单曲封面「以歌曲为准」——歌曲存在才保留；`evictSong`
/// 会连同该歌的歌词、以及**仅归属该歌**的封面一并删除，不留孤儿文件。
class OfflineCacheManager {
  static const String _indexName = 'index.json';
  static const int _defaultMaxBytes = 2 * 1024 * 1024 * 1024; // 2G 默认
  static const Duration _indexDebounce = Duration(seconds: 1);

  Directory? _root;
  final Map<String, _CacheEntry> _entries = {};
  final Map<OfflineCacheKind, Directory> _kindDirs = {};
  int _totalBytes = 0;
  int _maxBytes = _defaultMaxBytes;
  bool _init = false;
  Timer? _flushTimer;
  bool _flushScheduled = false;
  // 串行化磁盘写与索引更新（Dart 单线程内避免多段 await 交错）。
  Future<void> _opTail = Future.value();

  OfflineCacheManager();

  int get maxBytes => _maxBytes;
  int get totalBytes => _totalBytes;

  /// 子目录名。
  static String _subdirOf(OfflineCacheKind kind) => switch (kind) {
        OfflineCacheKind.song => 'songs',
        OfflineCacheKind.cover => 'covers',
        OfflineCacheKind.lyric => 'lyrics',
        OfflineCacheKind.playlistCover => 'playlist_covers',
      };

  /// 将任意 key 安全化为文件名。
  static String _safeName(String key) {
    final cleaned = key
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (cleaned.isEmpty) return '_';
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  File _fileFor(OfflineCacheKind kind, String key) {
    return File(p.join(_kindDirs[kind]!.path, _safeName(key)));
  }

  /// 把所有异步写操作串行化。
  Future<void> _synchronized(Future<void> Function() op) {
    final next = _opTail.then((_) => op());
    // 出错不阻断后续操作。
    _opTail = next.catchError((_) {});
    return next;
  }

  /// 初始化：创建目录、载入索引。
  Future<void> init() async {
    if (_init) return;
    final support = await getApplicationSupportDirectory();
    _root = Directory(p.join(support.path, 'offline_cache'));
    if (!await _root!.exists()) await _root!.create(recursive: true);
    for (final kind in OfflineCacheKind.values) {
      final dir = Directory(p.join(_root!.path, _subdirOf(kind)));
      if (!await dir.exists()) await dir.create(recursive: true);
      _kindDirs[kind] = dir;
    }
    await _loadIndex();
    await _evictToFit();
    _init = true;
  }

  Future<void> _loadIndex() async {
    final indexFile = File(p.join(_root!.path, _indexName));
    if (!await indexFile.exists()) return;
    try {
      final raw =
          jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
      final list = (raw['entries'] as List?) ?? const [];
      for (final item in list) {
        final entry = _CacheEntry.fromJson(item as Map<String, dynamic>);
        if (entry.key.isEmpty) continue;
        final file = _fileFor(entry.kind, entry.key);
        if (!await file.exists()) continue; // 文件缺失：跳过
        _entries[entry.compositeKey] = entry;
        _totalBytes += entry.size;
      }
    } catch (_) {
      // 索引损坏：清空重建（缓存可丢弃）。
      _entries.clear();
      _totalBytes = 0;
    }
  }

  void _scheduleIndexFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(_indexDebounce, () {
      _flushScheduled = false;
      unawaited(_flushIndex());
    });
  }

  Future<void> _flushIndex() async {
    await _synchronized(() async {
      if (_root == null) return;
      final payload = {
        'version': 1,
        'maxBytes': _maxBytes,
        'entries': _entries.values.map((e) => e.toJson()).toList(),
      };
      final indexFile = File(p.join(_root!.path, _indexName));
      await indexFile.writeAsString(jsonEncode(payload), flush: true);
    });
  }

  /// 设置总容量（字节）。超容量时立即轮转。
  Future<void> setMaxBytes(int bytes) async {
    _maxBytes = bytes > 0 ? bytes : _defaultMaxBytes;
    await _evictToFit();
    _scheduleIndexFlush();
  }

  void _touchEntry(_CacheEntry entry) {
    entry.lastAccessMs = DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> _writeBytes(
    OfflineCacheKind kind,
    String key,
    List<int> bytes, {
    List<String> owners = const [],
  }) async {
    await _synchronized(() async {
      if (bytes.isEmpty) return;
      final composite = '${kind.name}:$key';
      final existing = _entries[composite];
      if (existing != null) {
        _totalBytes -= existing.size;
      }
      final file = _fileFor(kind, key);
      await file.writeAsBytes(bytes, flush: true);
      final entry = _CacheEntry(
        kind: kind,
        key: key,
        size: bytes.length,
        lastAccessMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (kind == OfflineCacheKind.cover && owners.isNotEmpty) {
        entry.owners.addAll(owners.where((o) => o.isNotEmpty).toSet());
      }
      _entries[composite] = entry;
      _totalBytes += bytes.length;
      await _evictToFit();
    });
    _scheduleIndexFlush();
  }

  // ---- 歌曲 ----
  Future<void> putSong(String songId, List<int> bytes) {
    if (songId.isEmpty) return Future.value();
    return _writeBytes(OfflineCacheKind.song, songId, bytes);
  }

  bool hasSong(String songId) {
    return _entries.containsKey('${OfflineCacheKind.song.name}:$songId');
  }

  /// 直接把磁盘源文件拷入缓存（流式落盘，避免大文件整体进内存）。
  Future<void> putSongFromFile(String songId, File src) {
    if (songId.isEmpty) return Future.value();
    return _synchronized(() async {
      if (!await src.exists()) return;
      final length = await src.length();
      if (length <= 0) return;
      final composite = '${OfflineCacheKind.song.name}:$songId';
      final existing = _entries[composite];
      if (existing != null) _totalBytes -= existing.size;
      final file = _fileFor(OfflineCacheKind.song, songId);
      await src.copy(file.path);
      _entries[composite] = _CacheEntry(
        kind: OfflineCacheKind.song,
        key: songId,
        size: length,
        lastAccessMs: DateTime.now().millisecondsSinceEpoch,
      );
      _totalBytes += length;
      await _evictToFit();
      _scheduleIndexFlush();
    });
  }

  File? songFile(String songId) {
    final e = _entries['${OfflineCacheKind.song.name}:$songId'];
    if (e == null) return null;
    _touchEntry(e);
    return _fileFor(e.kind, e.key);
  }

  // ---- 歌词 ----
  Future<void> putLyrics(String songId, String text) {
    if (songId.isEmpty || text.isEmpty) return Future.value();
    return _writeBytes(OfflineCacheKind.lyric, songId, utf8.encode(text));
  }

  Future<String?> lyrics(String songId) async {
    final e = _entries['${OfflineCacheKind.lyric.name}:$songId'];
    if (e == null) return null;
    _touchEntry(e);
    final file = _fileFor(e.kind, e.key);
    if (!await file.exists()) return null;
    return utf8.decode(await file.readAsBytes());
  }

  // ---- 封面（可带归属 songId 集合） ----
  Future<void> putCover(String coverKey, List<int> bytes,
      {List<String> owners = const []}) {
    if (coverKey.isEmpty) return Future.value();
    return _writeBytes(OfflineCacheKind.cover, coverKey, bytes, owners: owners);
  }

  bool hasCover(String coverKey) {
    return _entries.containsKey('${OfflineCacheKind.cover.name}:$coverKey');
  }

  File? coverFile(String coverKey) {
    final e = _entries['${OfflineCacheKind.cover.name}:$coverKey'];
    if (e == null) return null;
    _touchEntry(e);
    return _fileFor(e.kind, e.key);
  }

  // ---- 歌单封面 ----
  Future<void> putPlaylistCover(String coverKey, List<int> bytes) {
    if (coverKey.isEmpty) return Future.value();
    return _writeBytes(OfflineCacheKind.playlistCover, coverKey, bytes);
  }

  bool hasPlaylistCover(String coverKey) {
    return _entries
        .containsKey('${OfflineCacheKind.playlistCover.name}:$coverKey');
  }

  File? playlistCoverFile(String coverKey) {
    final e = _entries['${OfflineCacheKind.playlistCover.name}:$coverKey'];
    if (e == null) return null;
    _touchEntry(e);
    return _fileFor(e.kind, e.key);
  }

  /// 删除一首歌：歌曲文件 + 其歌词 + 仅归属该歌的封面。
  Future<void> evictSong(String songId) async {
    await _synchronized(() async {
      await _removeEntry(OfflineCacheKind.song, songId);
      await _removeEntry(OfflineCacheKind.lyric, songId);
      final coverKeys = _entries.values
          .where((e) =>
              e.kind == OfflineCacheKind.cover && e.owners.contains(songId))
          .where((e) => e.owners.every((o) => o == songId))
          .map((e) => e.key)
          .toList();
      for (final key in coverKeys) {
        await _removeEntry(OfflineCacheKind.cover, key);
      }
    });
    _scheduleIndexFlush();
  }

  Future<void> _removeEntry(OfflineCacheKind kind, String key) async {
    final composite = '${kind.name}:$key';
    final entry = _entries.remove(composite);
    if (entry == null) return;
    _totalBytes -= entry.size;
    final file = _fileFor(kind, key);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// LRU 轮转：总量超容量时，从最久未访问开始删除。
  Future<void> _evictToFit() async {
    if (_totalBytes <= _maxBytes) return;
    final sorted = _entries.values.toList()
      ..sort((a, b) => a.lastAccessMs.compareTo(b.lastAccessMs));
    for (final entry in sorted) {
      if (_totalBytes <= _maxBytes) break;
      if (entry.kind == OfflineCacheKind.song || entry.kind == OfflineCacheKind.lyric) {
        await evictSong(entry.key);
      } else {
        await _removeEntry(entry.kind, entry.key);
      }
    }
    _scheduleIndexFlush();
  }

  /// 一键清空。
  Future<void> clearAll() async {
    await _synchronized(() async {
      for (final kind in OfflineCacheKind.values) {
        final dir = _kindDirs[kind];
        if (dir == null || !await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
      _entries.clear();
      _totalBytes = 0;
    });
    _scheduleIndexFlush();
  }

  /// 各类型缓存条目数（设置页展示）。
  Map<OfflineCacheKind, int> countByKind() {
    final map = {for (final k in OfflineCacheKind.values) k: 0};
    for (final e in _entries.values) {
      map[e.kind] = (map[e.kind] ?? 0) + 1;
    }
    return map;
  }
}