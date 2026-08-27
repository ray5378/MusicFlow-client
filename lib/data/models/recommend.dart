/// 首页固定推荐卡(来自主项目插件,如每日推荐/今日漫游/本地推荐)
class HomeCard {
  final String playlistId;
  final String name;
  final String playlistName;
  final int position;
  final bool isCombo;
  final int songCount;
  final String? coverArt;

  HomeCard({
    required this.playlistId,
    required this.name,
    required this.playlistName,
    required this.position,
    required this.isCombo,
    required this.songCount,
    this.coverArt,
  });

  factory HomeCard.fromJson(Map<String, dynamic> json) {
    return HomeCard(
      playlistId: json['playlistId'] as String,
      name: json['name'] as String? ?? '',
      playlistName: json['playlistName'] as String? ?? '',
      position: (json['position'] as int?) ?? 0,
      isCombo: json['isCombo'] as bool? ?? false,
      songCount: (json['songCount'] as int?) ?? 0,
      coverArt: json['coverArt'] as String?,
    );
  }
}

/// 平台推荐歌单(来自 recommend 能力插件,如网易云/QQ 等)
class RecommendPlaylist {
  final String id;
  final String source;
  final String name;
  final String creator;
  final String? cover;
  final String trackCount;
  final String link;
  final bool imported;

  RecommendPlaylist({
    required this.id,
    required this.source,
    required this.name,
    required this.creator,
    this.cover,
    required this.trackCount,
    required this.link,
    required this.imported,
  });

  factory RecommendPlaylist.fromJson(Map<String, dynamic> json) {
    return RecommendPlaylist(
      id: json['id'] as String,
      source: json['source'] as String? ?? '',
      name: json['name'] as String? ?? '',
      creator: json['creator'] as String? ?? '',
      cover: json['cover'] as String?,
      trackCount: json['trackCount'] as String? ?? '',
      link: json['link'] as String? ?? '',
      imported: json['imported'] as bool? ?? false,
    );
  }
}

/// /rest/api/v1/recommend 整体返回(含 providerId 与频道列表)
class RecommendResult {
  final String providerId;
  final List<RecommendChannel> channels;

  RecommendResult({required this.providerId, required this.channels});
}

/// 本地随机歌单条目:已入库的本地歌单,直接以本地 id 打开/播放(无需导入)。
class LocalRecommendPlaylist {
  final String id;
  final String name;
  final String? coverArt;
  final int songCount;

  LocalRecommendPlaylist({
    required this.id,
    required this.name,
    this.coverArt,
    required this.songCount,
  });

  factory LocalRecommendPlaylist.fromJson(Map<String, dynamic> json) {
    return LocalRecommendPlaylist(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      coverArt: json['coverArt'] as String?,
      songCount: (json['songCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 本地随机频道(一个平台一个),按平台分组展示。
/// 后端透传展示文案:subtag 为分区标题后缀(如「每日更新」,缺省回落「本地随机」),
/// tagline 为副标题说明文案(缺省回落歌单数量)。
class LocalRecommendChannel {
  final String source;
  final String name;
  final int count;
  final String? subtag;
  final String? tagline;
  final List<LocalRecommendPlaylist> playlists;

  LocalRecommendChannel({
    required this.source,
    required this.name,
    required this.count,
    this.subtag,
    this.tagline,
    required this.playlists,
  });

  factory LocalRecommendChannel.fromJson(Map<String, dynamic> json) {
    final list = json['playlists'] as List? ?? [];
    return LocalRecommendChannel(
      source: json['source'] as String? ?? '',
      name: json['name'] as String? ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      subtag: json['subtag'] as String?,
      tagline: json['tagline'] as String?,
      playlists: list
          .map((e) => LocalRecommendPlaylist.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 平台推荐频道(一个平台/插件对应一个频道)
class RecommendChannel {
  final String source;
  final String name;
  final int count;
  final List<RecommendPlaylist> playlists;

  RecommendChannel({
    required this.source,
    required this.name,
    required this.count,
    required this.playlists,
  });

  factory RecommendChannel.fromJson(Map<String, dynamic> json) {
    final list = json['playlists'] as List? ?? [];
    return RecommendChannel(
      source: json['source'] as String? ?? '',
      name: json['name'] as String? ?? json['source'] as String? ?? '',
      count: (json['count'] as int?) ?? 0,
      playlists: list
          .map((e) => RecommendPlaylist.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
