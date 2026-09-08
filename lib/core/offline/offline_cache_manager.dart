import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 缓存条目类型。
enum OfflineCacheKind { song, cover, lyric, playlistCover }

/// 已缓存歌曲的展示元数据（「已缓存音乐」页使用）。
class CachedSongInfo {
  final String songId;
  final String title;
  final String artist;
  final String? album;
  final int? durationSeconds;
  final String? coverArt;
  final int size;

  const CachedSongInfo({
    required this.songId,
    required this.title,
    required this.artist,
    this.album,
    this.durationSeconds,
    this.coverArt,
    required this.size,
  });

  static const _kSong = 'songId';
  static const _kTitle = 'title';
  static const _kArtist = 'artist';
  static const _kAlbum = 'album';
  static const _kDuration = 'duration';
  static const _kCover = 'coverArt';

  Map<String, dynamic> toJson() => {
        _kSong: songId,
        _kTitle: title,
        _kArtist: artist,
        if (album != null) _kAlbum: album,
        if (durationSeconds != null) _kDuration: durationSeconds,
        if (coverArt != null) _kCover: coverArt,
      };

  factory CachedSongInfo.fromMeta(String songId, Map<String, dynamic> meta) =>
      CachedSongInfo(
        songId: songId,
        title: meta[_kTitle] as String? ?? songId,
        artist: meta[_kArtist] as String? ?? '',
        album: meta[_kAlbum] as String?,
        durationSeconds: meta[_kDuration] as int?,
        coverArt: meta[_kCover] as String?,
        size: 0, // 大小由条目读取时回填
      );

  CachedSongInfo copyWithSize(int size) => CachedSongInfo(
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
        coverArt: coverArt,
        size: size,
      );
}

/// 一条缓存索引记录。
class _CacheEntry {
  final OfflineCacheKind kind;
  final String key;
  final int size;
  int lastAccessMs;
  /// 归属的歌曲 id 集合（仅 cover 使用）：歌曲被清时，仅归属它的封面一并删除。
  final List<String> owners;
  /// 歌曲条目的展示元数据（仅 kind==song）。
  Map<String, dynamic>? meta;

  _CacheEntry({
    required this.kind,
    required this.key,
    required this.size,
    required this.lastAccessMs,
    List<String>? owners,
    this.meta,
  }) : owners = owners ?? const [];

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'key': key,
        'size': size,
        'lastAccessMs': lastAccessMs,
        if (owners.isNotEmpty) 'owners': owners,
        if (meta != null) 'meta': meta,
      };

  factory _CacheEntry.fromJson(Map<String, dynamic> json) => _CacheEntry(
        kind: OfflineCacheKind.values.asNameMap()[json['kind']] ??
            OfflineCacheKind.song,
        key: json['key'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        lastAccessMs: json['lastAccessMs'] as int? ?? 0,
        owners: (json['owners'] as List?)?.cast<String>() ?? const [],
        meta: (json['meta'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
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
  // 离线缓存总开关：关闭后所有写入 no-op（不落任何缓存）。
  // 由设置层持久化并同步（见 OfflineCacheSettingsNotifier），manager 只负责执行。
  bool _enabled = true;
  bool _init = false;
  Timer? _flushTimer;
  bool _flushScheduled = false;
  // 测试注入的根目录；为空时回退到真实的应用数据目录。仅供单测脱离
  // path_provider 使用，生产路径不带参行为完全一致。
  final Directory? _rootForTest;
  // 串行化磁盘写与索引更新（Dart 单线程内避免多段 await 交错）。
  Future<void> _opTail = Future.value();

  OfflineCacheManager({Directory? rootForTest}) : _rootForTest = rootForTest;

  int get maxBytes => _maxBytes;
  int get totalBytes => _totalBytes;

  /// 子目录名。
  static String _subdirOf(OfflineCacheKind kind) => switch (kind) {
        OfflineCacheKind.song => 'songs',
        OfflineCacheKind.cover => 'covers',
        OfflineCacheKind.lyric => 'lyrics',
        OfflineCacheKind.playlistCover => 'playlist_covers',
      };

  /// 将任意 key 安全化为文件名（公开静态：下载 daemon 等外部写盘也必须走它，
  /// 防止原始 id 拼路径造成路径穿越/非法字符）。
  static String safeName(String key) {
    final cleaned = key
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (cleaned.isEmpty) return '_';
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  static String _safeName(String key) => safeName(key);

  /// 歌词缓存键：拼接 libraryId 隔离多库——不同媒体库可能存在相同 songId
  /// （不同服务端自增/uuid 独立），不隔离会串库返回错误歌词。
  /// [evictSong] 的歌词清理已兼容 `<libId>:<songId>` 与裸 `<songId>` 两种格式。
  static String lyricsKey(String libraryId, String songId) =>
      libraryId.isEmpty ? songId : '$libraryId:$songId';

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
    final support = _rootForTest ?? await getApplicationSupportDirectory();
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
      // 索引本身也走原子写：写一半被杀的 index.json 会触发"清空重建"，
      // 导致全部缓存变孤儿（下次启动被 _sweepOrphans 清掉）。
      final tmp = File('${indexFile.path}.part');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await _atomicPromote(tmp, indexFile);
    });
  }

  /// 原子写：先落 `.part` 再 rename 到目标（rename 同目录内原子替换，
  /// Windows/Android 均成立）。rename 失败时退化为直接覆盖写，保证可用性。
  Future<void> _atomicWrite(File file, List<int> bytes) async {
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await _atomicPromote(tmp, file);
  }

  Future<void> _atomicPromote(File tmp, File target) async {
    try {
      await tmp.rename(target.path);
    } catch (_) {
      try {
        await tmp.copy(target.path);
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    }
  }

  /// 立即落盘索引（App 退出/切后台时调用）：绕过 1s debounce，
  /// 避免"写入后 1s 内进程被杀"留下有文件无索引的孤儿。
  Future<void> flushIndexNow() => _flushIndex();

  /// 设置总容量（字节）。超容量时立即轮转。
  Future<void> setMaxBytes(int bytes) async {
    _maxBytes = bytes > 0 ? bytes : _defaultMaxBytes;
    await _evictToFit();
    _scheduleIndexFlush();
  }

  bool get enabled => _enabled;

  /// 打开/关闭缓存写入。关闭后所有 `put*` 直接 no-op，磁盘不再新增任何文件；
  /// 已有内容是否清除由调用方决定（设置层在关闭时另行调用 [clearAll]）。
  void setEnabled(bool value) => _enabled = value;

  void _touchEntry(_CacheEntry entry) {
    entry.lastAccessMs = DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> _writeBytes(
    OfflineCacheKind kind,
    String key,
    List<int> bytes, {
    List<String> owners = const [],
    Map<String, dynamic>? meta,
  }) async {
    if (!_enabled) return;
    await _synchronized(() async {
      if (bytes.isEmpty) return;
      final composite = '${kind.name}:$key';
      final existing = _entries[composite];
      if (existing != null) {
        _totalBytes -= existing.size;
      }
      final file = _fileFor(kind, key);
      await _atomicWrite(file, bytes);
      final entry = _CacheEntry(
        kind: kind,
        key: key,
        size: bytes.length,
        lastAccessMs: DateTime.now().millisecondsSinceEpoch,
        meta: kind == OfflineCacheKind.song ? meta : null,
        // 封面在构造时直接传入可变归属列表；切勿在 const [] 默认值上调 addAll
        // （会抛 UnsupportedError），那样会把封面条目挡在 _entries 之外，导致
        // 封面计数永远为 0、并让 _cacheSongCover 提前抛错连带阻塞歌曲缓存。
        owners: kind == OfflineCacheKind.cover
            ? owners.where((o) => o.isNotEmpty).toSet().toList()
            : const [],
      );
      _entries[composite] = entry;
      _totalBytes += bytes.length;
      await _evictToFit();
    });
    _scheduleIndexFlush();
  }

  // ---- 歌曲 ----
  Future<void> putSong(String songId, List<int> bytes,
      {Map<String, dynamic>? meta}) {
    if (songId.isEmpty) return Future.value();
    return _writeBytes(OfflineCacheKind.song, songId, bytes, meta: meta);
  }

  bool hasSong(String songId) {
    return _entries.containsKey('${OfflineCacheKind.song.name}:$songId');
  }

  /// 直接把磁盘源文件拷入缓存（流式落盘，避免大文件整体进内存）。
  Future<void> putSongFromFile(String songId, File src,
      {Map<String, dynamic>? meta}) {
    if (songId.isEmpty || !_enabled) return Future.value();
    return _synchronized(() async {
      if (!src.existsSync()) return;
      final length = await src.length();
      if (length <= 0) return;
      final composite = '${OfflineCacheKind.song.name}:$songId';
      final existing = _entries[composite];
      if (existing != null) _totalBytes -= existing.size;
      final file = _fileFor(OfflineCacheKind.song, songId);
      // 原子拷贝：先写 .part 再 rename，弱网/强退不会留下损坏的目标文件。
      final tmp = File('${file.path}.part');
      await src.copy(tmp.path);
      await _atomicPromote(tmp, file);
      _entries[composite] = _CacheEntry(
        kind: OfflineCacheKind.song,
        key: songId,
        size: length,
        lastAccessMs: DateTime.now().millisecondsSinceEpoch,
        meta: meta,
      );
      _totalBytes += length;
      await _evictToFit();
      _scheduleIndexFlush();
    });
  }

  /// 已缓存歌曲列表（展示元数据），按缓存时间新→旧。「已缓存音乐」页数据源。
  List<CachedSongInfo> get cachedSongs {
    final list = _entries.values
        .where((e) => e.kind == OfflineCacheKind.song)
        .toList()
      ..sort((a, b) => b.lastAccessMs.compareTo(a.lastAccessMs));
    return [
      for (final e in list)
        CachedSongInfo.fromMeta(e.key, e.meta ?? const {})
            .copyWithSize(e.size),
    ];
  }

  /// 单条歌曲展示元数据；未缓存返回 null。
  CachedSongInfo? cachedSong(String songId) {
    final e = _entries['${OfflineCacheKind.song.name}:$songId'];
    if (e == null) return null;
    _touchEntry(e);
    return CachedSongInfo.fromMeta(e.key, e.meta ?? const {}).copyWithSize(e.size);
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

  bool lyricsCached(String songId) {
    return _entries.containsKey('${OfflineCacheKind.lyric.name}:$songId');
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
    await _synchronized(() => _evictSongInternal(songId));
    _scheduleIndexFlush();
  }

  /// 删除一首歌的内部实现，**不加 `_synchronized`**。
  ///
  /// 同时供公开 [evictSong]（自会包一层 serializer）与 `_evictToFit` 复用。
  /// 关键约束：`_evictToFit` 会出现在已处于 `_synchronized` 的上下文（例如
  /// `_writeBytes` 的串行化操作内）被调用，此刻若再包一层 `_synchronized`，
  /// 新操作会排在 `_opTail` 链尾等待当前操作结束，而当前操作又在等它返回，
  /// 造成自锁死锁。故这里做纯删除，绝不再排队。
  Future<void> _evictSongInternal(String songId) async {
    await _removeEntry(OfflineCacheKind.song, songId);
    await _removeEntry(OfflineCacheKind.lyric, songId);
    // 兼容带 libraryId 前缀的歌词键（OfflineCacheManager.lyricsKey）。
    final lyricKeys = _entries.values
        .where((e) =>
            e.kind == OfflineCacheKind.lyric && e.key.endsWith(':$songId'))
        .map((e) => e.key)
        .toList();
    for (final key in lyricKeys) {
      await _removeEntry(OfflineCacheKind.lyric, key);
    }
    final coverKeys = _entries.values
        .where((e) =>
            e.kind == OfflineCacheKind.cover && e.owners.contains(songId))
        .where((e) => e.owners.every((o) => o == songId))
        .map((e) => e.key)
        .toList();
    for (final key in coverKeys) {
      await _removeEntry(OfflineCacheKind.cover, key);
    }
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
        // 直接用内部实现，不再经 evictSong 包一层 _synchronized，避免在
        // 已串行化上下文(_writeBytes/putSongFromFile)内嵌套自锁死锁。
        await _evictSongInternal(entry.key);
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