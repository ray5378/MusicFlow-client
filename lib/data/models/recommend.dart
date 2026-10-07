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

  Map<String, dynamic> toJson() => <String, dynamic>{
        'playlistId': playlistId,
        'name': name,
        'playlistName': playlistName,
        'position': position,
        'isCombo': isCombo,
        'songCount': songCount,
        if (coverArt != null) 'coverArt': coverArt,
      };
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

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'source': source,
        'name': name,
        'creator': creator,
        if (cover != null) 'cover': cover,
        'trackCount': trackCount,
        'link': link,
        'imported': imported,
      };
}

/// /rest/api/v1/recommend 整体返回(含 providerId 与频道列表)
class RecommendResult {
  final String providerId;
  final List<RecommendChannel> channels;

  RecommendResult({required this.providerId, required this.channels});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'providerId': providerId,
        'channels': channels.map((e) => e.toJson()).toList(),
      };
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

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        if (coverArt != null) 'coverArt': coverArt,
        'songCount': songCount,
      };
}

/// 本地随机频道(一个平台一个),按平台分组展示。
/// 后端透传展示文案:subtag 为分区标题后缀(如「每日更新」,缺省回落「平台推荐」),
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

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'name': name,
        'count': count,
        if (subtag != null) 'subtag': subtag,
        if (tagline != null) 'tagline': tagline,
        'playlists': playlists.map((e) => e.toJson()).toList(),
      };
}

/// 首页分区清单条目(来自 /rest/api/v1/home/sections)。
/// 服务端决定某个分区是否存在(key)、标题、展示顺序(sortOrder 越小越靠前)
/// 与可见性(visible);客户端据此按顺序渲染首页各分区,实现客户端与服务端解耦。
class HomeSection {
  final String key;
  final String title;
  final int sortOrder;
  final bool visible;

  const HomeSection({
    required this.key,
    required this.title,
    required this.sortOrder,
    required this.visible,
  });

  factory HomeSection.fromJson(Map<String, dynamic> json) {
    return HomeSection(
      key: json['key'] as String? ?? '',
      title: json['title'] as String? ?? '',
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      visible: json['visible'] as bool? ?? true,
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
      // [D-040] 缺陷：count 用 as int?，服务端返回浮点时会 CastError；
      //   同文件 LocalRecommendChannel.fromJson 用的是 (json['count'] as num?)?.toInt()，两处写法不一致。
      //   建议：统一为 as num? 再 toInt()。
      //   守卫用例：test/data/repositories/b30p_recommend_repository_cov_test.dart 模型解析用例。
      count: (json['count'] as int?) ?? 0,
      playlists: list
          .map((e) => RecommendPlaylist.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'name': name,
        'count': count,
        'playlists': playlists.map((e) => e.toJson()).toList(),
      };
}
