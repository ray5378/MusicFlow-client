import 'package:dio/dio.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

/// 学习模块 API 封装（对齐服务端 `/rest/api/v1/study/*`）。
///
/// 学习面与音乐面互相隔离：列表/搜索/歌单都只看 `kind='study'` 的源与歌曲，
/// 播放进度写 `study_progress`（不污染音乐播放历史）。

/// 学习源。
class StudySource {
  const StudySource({
    required this.id,
    required this.name,
    this.type = '',
    this.enabled = true,
    this.songCount = 0,
  });

  final String id;
  final String name;
  final String type;
  final bool enabled;
  final int songCount;

  factory StudySource.fromJson(Map<String, dynamic> json) {
    return StudySource(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      type: '${json['type'] ?? ''}',
      enabled: json['enabled'] != false,
      songCount: (json['songCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 学习目录条目（目录或音频文件）。
class StudyDirEntry {
  const StudyDirEntry({
    required this.name,
    required this.relPath,
    required this.isDir,
    this.size,
    this.songId,
    this.durationSec,
    this.positionSec,
    this.finished = false,
    this.progress = 0,
  });

  final String name;
  final String relPath;
  final bool isDir;
  final int? size;

  /// 已入库文件的歌曲 id（未点播过的文件没有）。
  final String? songId;
  final int? durationSec;
  final int? positionSec;
  final bool finished;

  /// 0~1。
  final double progress;

  factory StudyDirEntry.fromJson(Map<String, dynamic> json) {
    return StudyDirEntry(
      name: '${json['name'] ?? ''}',
      relPath: '${json['relPath'] ?? ''}',
      isDir: json['isDir'] == true,
      size: (json['size'] as num?)?.toInt(),
      songId: (json['songId'] as String?)?.trim().isEmpty == true
          ? null
          : json['songId'] as String?,
      durationSec: (json['durationSec'] as num?)?.toInt(),
      positionSec: (json['positionSec'] as num?)?.toInt(),
      finished: json['finished'] == true,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// 学习歌单摘要。
class StudyPlaylist {
  const StudyPlaylist({
    required this.id,
    required this.name,
    this.songCount = 0,
    this.duration = 0,
    this.comment = '',
    this.public = false,
    this.folder = '',
  });

  final String id;
  final String name;
  final int songCount;
  final int duration;
  final String comment;
  final bool public;

  /// 所属文件夹名;空串=根目录。
  final String folder;

  factory StudyPlaylist.fromJson(Map<String, dynamic> json) {
    return StudyPlaylist(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      songCount: (json['songCount'] as num?)?.toInt() ?? 0,
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      comment: '${json['comment'] ?? ''}',
      public: json['public'] == true,
      folder: '${json['folder'] ?? ''}',
    );
  }
}

/// 「继续学习」条目：歌曲 + 上次进度。
class StudyContinueItem {
  const StudyContinueItem({
    required this.song,
    this.positionSec = 0,
    this.progress = 0,
    this.playlistId = '',
    this.playlistName = '',
  });

  final Song song;

  /// 上次停下的位置（秒）。
  final int positionSec;

  /// 0~1。
  final double progress;

  /// 学习歌单续播条目：所属歌单 id / 名称（单条学习内容为空串）。
  final String playlistId;
  final String playlistName;

  /// 是否为「学习歌单」续播条目。
  bool get isPlaylist => playlistId.isNotEmpty;
}

/// 「继续学习」接口结果：单条学习内容 + 学习歌单续播条目。
class StudyContinueResult {
  const StudyContinueResult({
    this.items = const <StudyContinueItem>[],
    this.playlistItems = const <StudyContinueItem>[],
  });

  final List<StudyContinueItem> items;
  final List<StudyContinueItem> playlistItems;

  bool get isEmpty => items.isEmpty && playlistItems.isEmpty;
}

/// 批量入库结果：源文件相对路径 + 入库后的歌曲。
class StudyResolvedEntry {
  const StudyResolvedEntry({required this.path, required this.song});

  final String path;
  final Song song;
}

/// 学习歌单重名：服务端以 409 拒绝创建/改名。
class StudyPlaylistNameConflict implements Exception {
  const StudyPlaylistNameConflict();
}

class StudyApi {
  StudyApi(this._client);

  static const String _base = '/rest/api/v1/study';
  static const String _logTag = 'STUDY_API';

  final SubsonicApiClient _client;

  static List<Map<String, dynamic>> _mapList(dynamic raw, {String key = 'items'}) {
    if (raw is Map && raw[key] is List) {
      final list = raw[key] as List;
      return <Map<String, dynamic>>[
        for (final item in list)
          if (item is Map)
            item.map((key, value) => MapEntry(key.toString(), value)),
      ];
    }
    return const <Map<String, dynamic>>[];
  }

  /// 学习源列表（总目录的根层）。
  Future<List<StudySource>> fetchSources() async {
    final raw = await _client.getRaw('$_base/sources');
    return _mapList(raw).map(StudySource.fromJson).toList(growable: false);
  }

  /// 实时列目录。
  Future<List<StudyDirEntry>> fetchDir({
    required String sourceId,
    String path = '',
  }) async {
    final raw = await _client.getRaw(
      '$_base/dir',
      queryParameters: <String, dynamic>{'sourceId': sourceId, 'path': path},
    );
    return _mapList(raw).map(StudyDirEntry.fromJson).toList(growable: false);
  }

  /// 批量入库（「播放全部」/点某一章）：返回按入参顺序排列的歌曲，失败项跳过。
  Future<List<Song>> resolveBatch({
    required String sourceId,
    required List<String> paths,
  }) async {
    final entries = await resolveBatchEntries(sourceId: sourceId, paths: paths);
    return <Song>[for (final entry in entries) entry.song];
  }

  /// 批量入库并保留路径映射（多选加歌单需要按 relPath 精确对应 songId）。
  Future<List<StudyResolvedEntry>> resolveBatchEntries({
    required String sourceId,
    required List<String> paths,
  }) async {
    if (paths.isEmpty) return const <StudyResolvedEntry>[];
    final raw = await _client.postRaw(
      '$_base/resolve-batch',
      data: <String, dynamic>{'sourceId': sourceId, 'paths': paths},
    );
    final entries = <StudyResolvedEntry>[];
    for (final item in _mapList(raw)) {
      final song = item['song'];
      final path = item['path'];
      if (song is! Map || path is! String) continue;
      entries.add(
        StudyResolvedEntry(
          path: path,
          song: Song.fromJson(
            song.map((key, value) => MapEntry(key.toString(), value)),
          ),
        ),
      );
    }
    Logger.infoWithTag(
      _logTag,
      'resolveBatch source=$sourceId requested=${paths.length} '
      'resolved=${entries.length}',
    );
    return entries;
  }

  /// 继续学习（未听完的最近条目）。
  Future<List<StudyContinueItem>> fetchContinue({int limit = 20}) async {
    final result = await fetchContinueAll(limit: limit);
    return result.items;
  }

  /// 继续学习全部内容：单独学习的内容 + 学习歌单续播条目。
  Future<StudyContinueResult> fetchContinueAll({int limit = 20}) async {
    final raw = await _client.getRaw(
      '$_base/continue',
      queryParameters: <String, dynamic>{'limit': limit},
    );
    List<StudyContinueItem> parse(String key) => <StudyContinueItem>[
          for (final item in _mapList(raw, key: key))
            StudyContinueItem(
              song: Song.fromJson(item),
              positionSec: (item['positionSec'] as num?)?.toInt() ?? 0,
              progress: (item['progress'] as num?)?.toDouble() ?? 0,
              playlistId: '${item['playlistId'] ?? ''}'.trim(),
              playlistName: '${item['playlistName'] ?? ''}'.trim(),
            ),
        ];
    return StudyContinueResult(items: parse('items'), playlistItems: parse('playlistItems'));
  }

  Future<List<StudyPlaylist>> fetchPlaylists({String q = ''}) async {
    final raw = await _client.getRaw(
      '$_base/playlists',
      queryParameters: q.trim().isEmpty ? null : <String, dynamic>{'q': q.trim()},
    );
    return _mapList(raw).map(StudyPlaylist.fromJson).toList(growable: false);
  }

  /// 学习内容搜索（服务端按标题 / 课程 / 目录模糊匹配 kind=study 的歌曲）。
  ///
  /// 与学习歌单搜索一起构成「统一搜索」：歌单在上、内容在下。
  Future<List<Song>> searchContents(String query, {int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return const <Song>[];
    final raw = await _client.getRaw(
      '$_base/search',
      queryParameters: <String, dynamic>{'q': q, 'limit': limit},
    );
    return <Song>[
      for (final item in _mapList(raw)) Song.fromJson(item),
    ];
  }

  /// 学习歌单文件夹名列表(按课程归档;与歌单一样按用户隔离)。
  Future<List<String>> fetchPlaylistFolders() async {
    final raw = await _client.getRaw('$_base/playlist-folders');
    return _mapList(raw)
        .map((item) => '${item['name'] ?? ''}')
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> createPlaylistFolder(String name) async {
    await _client.postRaw(
      '$_base/playlist-folders',
      data: <String, dynamic>{'name': name},
    );
  }

  Future<void> renamePlaylistFolder(String name, String next) async {
    await _client.putRaw(
      '$_base/playlist-folders/${Uri.encodeComponent(name)}',
      data: <String, dynamic>{'name': next},
    );
  }

  Future<void> deletePlaylistFolder(String name) async {
    await _client.deleteRaw(
      '$_base/playlist-folders/${Uri.encodeComponent(name)}',
    );
  }

  /// 把歌单移动到文件夹(folder 传空串 = 移回根目录)。
  Future<void> movePlaylist(String playlistId, String folder) async {
    await _client.putRaw(
      '$_base/playlists/${Uri.encodeComponent(playlistId)}',
      data: <String, dynamic>{'folder': folder},
    );
  }

  /// 学习歌单曲目（按歌单顺序）。列表展示与源文件一致的文件名（含扩展名）。
  Future<List<Song>> fetchPlaylistTracks(String playlistId) async {
    final raw = await _client.getRaw(
      '$_base/playlists/${Uri.encodeComponent(playlistId)}/tracks',
    );
    final name = raw is Map ? '${raw['name'] ?? ''}'.trim() : '';
    return <Song>[
      for (final item in _mapList(raw))
        _playlistTrackFromJson(item, playlistId: playlistId, playlistName: name),
    ];
  }

  Song _playlistTrackFromJson(
    Map<String, dynamic> json, {
    String playlistId = '',
    String playlistName = '',
  }) {
    final song = Song.fromJson(json);
    final fileName = '${json['fileName'] ?? ''}'.trim();
    return song.copyWith(
      title: fileName.isEmpty ? null : fileName,
      // 记录来源歌单：播放时据此同时上报「整单续播」位置。
      playlistId: playlistId.isEmpty ? null : playlistId,
      playlistName: playlistName.isEmpty ? null : playlistName,
    );
  }

  /// 新建学习歌单，返回新歌单 id。
  Future<String> createPlaylist(String name) async {
    try {
      final raw = await _client.postRaw(
        '$_base/playlists',
        data: <String, dynamic>{'name': name},
      );
      final id = raw is Map ? '${raw['id'] ?? ''}'.trim() : '';
      if (id.isEmpty) {
        throw StateError('study playlist create returned no id');
      }
      return id;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        throw const StudyPlaylistNameConflict();
      }
      rethrow;
    }
  }

  /// 重命名学习歌单。
  Future<void> renamePlaylist(String playlistId, String name) async {
    try {
      await _client.putRaw(
        '$_base/playlists/${Uri.encodeComponent(playlistId)}',
        data: <String, dynamic>{'name': name},
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        throw const StudyPlaylistNameConflict();
      }
      rethrow;
    }
  }

  /// 删除学习歌单。
  Future<void> deletePlaylist(String playlistId) async {
    await _client.deleteRaw(
      '$_base/playlists/${Uri.encodeComponent(playlistId)}',
    );
  }

  /// 把已入库的学习歌曲加入歌单（服务端会过滤未入库 id 与重复项）。
  Future<void> addTracks(String playlistId, List<String> songIds) async {
    if (songIds.isEmpty) return;
    await _client.postRaw(
      '$_base/playlists/${Uri.encodeComponent(playlistId)}/tracks',
      data: <String, dynamic>{'add': songIds},
    );
  }

  /// 从学习歌单移出歌曲（按 songId）。
  Future<void> removeTracks(String playlistId, List<String> songIds) async {
    if (songIds.isEmpty) return;
    await _client.postRaw(
      '$_base/playlists/${Uri.encodeComponent(playlistId)}/tracks',
      data: <String, dynamic>{'remove': songIds},
    );
  }

  /// 上报学习进度（不写音乐播放历史）。
  Future<void> reportProgress({
    required String songId,
    required int positionSec,
    required int durationSec,
  }) async {
    await _client.putRaw(
      '$_base/progress',
      data: <String, dynamic>{
        'songId': songId,
        'positionSec': positionSec < 0 ? 0 : positionSec,
        'durationSec': durationSec < 0 ? 0 : durationSec,
      },
    );
  }

  /// 删除一条学习记录（只影响「继续学习」列表，不删除音频文件）。
  Future<void> deleteProgress(String songId) async {
    await _client.deleteRaw(
      '$_base/progress/${Uri.encodeComponent(songId)}',
    );
  }

  /// 清空当前用户全部学习记录（含学习歌单续播位置，不删除音频文件）。
  Future<void> clearProgress() async {
    await _client.deleteRaw('$_base/progress');
  }

  /// 上报学习歌单播放位置（整单续播用；曲目必须属于该歌单）。
  Future<void> reportPlaylistProgress({
    required String playlistId,
    required String songId,
    required int positionSec,
    required int durationSec,
  }) async {
    await _client.putRaw(
      '$_base/playlists/${Uri.encodeComponent(playlistId)}/progress',
      data: <String, dynamic>{
        'songId': songId,
        'positionSec': positionSec < 0 ? 0 : positionSec,
        'durationSec': durationSec < 0 ? 0 : durationSec,
      },
    );
  }
}
