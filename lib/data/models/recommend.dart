import 'package:musicflow_client/data/models/playlist.dart';

/// 首页固定推荐卡(来自主项目插件,如每日推荐/今日漫游/本地推荐)
class HomeCard {
  final String playlistId;
  final String name;
  final String playlistName;
  final int position;
  final bool isCombo;
  final int songCount;
  final String? coverArt;

  /// 服务端标记:该固定卡指向的歌单已不存在(仅 **异常卡** 才带此键,
  /// 健康卡的服务端响应里根本没有 `missing` 字段)。仅用于日志与降级判断,
  /// 不影响展示 —— 展示口径由 `HomeRecommendSection.degraded` 统一表达。
  final bool missing;

  HomeCard({
    required this.playlistId,
    required this.name,
    required this.playlistName,
    required this.position,
    required this.isCombo,
    required this.songCount,
    this.coverArt,
    this.missing = false,
  });

  factory HomeCard.fromJson(Map<String, dynamic> json) {
    return HomeCard(
      // 容错:服务端/插件数据缺 id 时不能用硬 cast(`as String` 会抛 CastError
      // 把整批固定卡拖崩)。空串由 `homeRecommendSectionProvider` 过滤并告警。
      playlistId: (json['playlistId'] as String?) ?? '',
      name: json['name'] as String? ?? '',
      playlistName: json['playlistName'] as String? ?? '',
      position: (json['position'] as num?)?.toInt() ?? 0,
      isCombo: json['isCombo'] as bool? ?? false,
      songCount: (json['songCount'] as num?)?.toInt() ?? 0,
      coverArt: json['coverArt'] as String?,
      missing: json['missing'] as bool? ?? false,
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
        if (missing) 'missing': true,
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

/// 首页「为你推荐」区块:服务端一次算好的固定卡 + 随机补位组合。
///
/// 来自 `GET /rest/api/v1/home/recommend-section`。与旧实现的本质差别:
/// - **固定卡零门槛**:服务端不再按 songCount 过滤,客户端也不许再过滤
///   (旧实现在客户端做 `songCount > 30`,把 30 首的卡全误杀);
/// - **随机补位由服务端按小时确定性洗牌 + 快照冻结**(`hourBucket` 标识所属小时),
///   同一小时内三端拿到同一份,不再是各端自己 `shuffle(Random())`;
/// - `homeCount` 由服务端下发,客户端不再单独请求 `/home/playlist-count`;
/// - `degraded` 表示有固定卡失效(此时 `fixed` 里的异常卡带 `missing: true`)。
class HomeRecommendSection {
  /// 快照所属小时桶(服务端小时级轮换标识),0 表示未知/空结果。
  final int hourBucket;

  /// 服务端下发的首页卡片总数(固定卡 + 随机补位)。
  final int homeCount;

  /// 有固定卡失效(服务端判定)。
  final bool degraded;

  /// 固定推荐卡(已按 position 排好序,客户端原样展示,不过滤)。
  final List<HomeCard> fixed;

  /// 服务端随机补位的本地歌单(已按小时确定性洗好牌,客户端不得再洗)。
  final List<Playlist> random;

  const HomeRecommendSection({
    this.hourBucket = 0,
    this.homeCount = 0,
    this.degraded = false,
    required this.fixed,
    required this.random,
  });

  /// 空结果(加载失败/仓库未就绪时的回落值)。
  const HomeRecommendSection.empty()
      : hourBucket = 0,
        homeCount = 0,
        degraded = false,
        fixed = const <HomeCard>[],
        random = const <Playlist>[];

  factory HomeRecommendSection.fromJson(Map<String, dynamic> json) {
    final fixedRaw = json['fixed'] as List? ?? const <dynamic>[];
    final randomRaw = json['random'] as List? ?? const <dynamic>[];
    return HomeRecommendSection(
      hourBucket: (json['hourBucket'] as num?)?.toInt() ?? 0,
      homeCount: (json['homeCount'] as num?)?.toInt() ?? 0,
      degraded: json['degraded'] as bool? ?? false,
      fixed: fixedRaw
          .whereType<Map<String, dynamic>>()
          .map(HomeCard.fromJson)
          .toList(),
      random: randomRaw
          .whereType<Map<String, dynamic>>()
          .map((e) => Playlist.fromJson(_normalizeRandomPlaylistJson(e)))
          .toList(),
    );
  }

  /// 随机补位项服务端只给 `{id,name,songCount,coverArt}` 四个字段,
  /// 而 [Playlist.fromJson] 要求 `id`/`name` 为 null 安全 —— 归一化补默认值,
  /// 避免个别条目缺字段时整批解析崩掉。
  static Map<String, dynamic> _normalizeRandomPlaylistJson(
    Map<String, dynamic> raw,
  ) {
    return <String, dynamic>{
      ...raw,
      'id': (raw['id'] as String?) ?? '',
      'name': (raw['name'] as String?) ?? '',
      'songCount': (raw['songCount'] as num?)?.toInt() ?? 0,
      'duration': (raw['duration'] as num?)?.toInt() ?? 0,
    };
  }

  bool get isEmpty => fixed.isEmpty && random.isEmpty;
}
