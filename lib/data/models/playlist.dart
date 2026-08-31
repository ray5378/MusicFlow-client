import 'song.dart';

/// 歌单模型
class Playlist {
  final String id;
  final String name;
  final String? comment;
  final String? owner;
  final bool public;
  final int songCount;
  final int duration; // 秒
  final DateTime? created;
  final DateTime? changed;
  final String? coverArt;
  final bool isImported; // 来自平台导入/插件同步(非本地自建)
  final String? sourcePlatform; // 来源平台,如 netease / qq / mixed
  final bool favorite; // 当前用户是否收藏该歌单(服务端 /rest/api/v1/playlists 返回)
  final List<Song>? songs; // 歌单详情时才有

  Playlist({
    required this.id,
    required this.name,
    this.comment,
    this.owner,
    this.public = false,
    required this.songCount,
    required this.duration,
    this.created,
    this.changed,
    this.coverArt,
    this.isImported = false,
    this.sourcePlatform,
    this.favorite = false,
    this.songs,
  });

  /// 从 JSON 反序列化
  factory Playlist.fromJson(Map<String, dynamic> json) {
    List<Song>? songsList;
    if (json['entry'] != null) {
      songsList = (json['entry'] as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      comment: json['comment'] as String?,
      owner: json['owner'] as String?,
      public: json['public'] as bool? ?? false,
      songCount: (json['songCount'] as num?)?.toInt() ?? 0,
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      created: _parseDate(json['created']),
      changed: _parseDate(json['changed']),
      coverArt: json['coverArt'] as String?,
      isImported: json['isImported'] as bool? ?? false,
      sourcePlatform: json['sourcePlatform'] as String?,
      favorite: json['favorite'] as bool? ?? false,
      songs: songsList,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'comment': comment,
      'owner': owner,
      'public': public,
      'songCount': songCount,
      'duration': duration,
      'created': created?.toIso8601String(),
      'changed': changed?.toIso8601String(),
      'coverArt': coverArt,
      'isImported': isImported,
      'favorite': favorite,
      if (sourcePlatform != null) 'sourcePlatform': sourcePlatform,
      if (songs != null) 'entry': songs!.map((s) => s.toJson()).toList(),
    };
  }

  /// 获取时长字符串(对齐主项目前端:xx时xx分 / xx分)。
  String get durationString {
    final hours = duration ~/ 3600;
    final minutes = (duration % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) return '$hours时$minutes分';
    if (hours > 0) return '$hours时';
    return '$minutes分';
  }
}

/// 容错日期解析：支持 ISO 8601 字符串、epoch 毫秒/秒数值、以及各种
/// 后端可能返回的格式。解析失败返回 null 而不是抛出 FormatException。
DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is num) {
    final ms = value.abs() > 1e12 ? value.toInt() : (value * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  // 标准 ISO 8601
  try {
    return DateTime.parse(s);
  } catch (_) {}
  // 去掉尾部时区缩写 (e.g. "2024-01-01T00:00:00Z" 已OK,
  // 但 "2024-01-01 00:00:00" 需要 T)
  if (!s.contains('T') && s.contains(' ')) {
    try {
      return DateTime.parse(s.replaceFirst(' ', 'T'));
    } catch (_) {}
  }
  return null;
}
