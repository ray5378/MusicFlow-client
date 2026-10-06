int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// 歌手模型
class Artist {
  final String id;
  final String name;
  final String? coverArt;
  final int? albumCount;
  final int? songCount;
  final bool starred;

  Artist({
    required this.id,
    required this.name,
    this.coverArt,
    this.albumCount,
    this.songCount,
    this.starred = false,
  });

  /// 从 JSON 反序列化
  factory Artist.fromJson(Map<String, dynamic> json) {
    return Artist(
      id: json['id'] as String,
      name: json['name'] as String,
      coverArt: json['coverArt'] as String?,
      albumCount: _toInt(json['albumCount']),
      songCount: _toInt(json['songCount']),
      starred: json['starred'] != null,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'coverArt': coverArt,
      'albumCount': albumCount,
      'songCount': songCount,
      'starred': starred,
    };
  }
}
