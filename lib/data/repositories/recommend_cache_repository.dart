import 'dart:convert';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';

/// 推荐类首页数据缓存仓库（基于 drift 的 recommend_caches KV-JSON 表）。
///
/// 供发现页三个慢数据源（homeCards / recommendChannels / localRecommend）的
/// 「远程优先 + 缓存兜底」使用（见 fetchWithCacheFallback）：以
/// `<kind>:<libraryId>` 为 scope 键整份存取 JSON；读取时容忍性解析
/// （跳过损坏/不兼容的单个条目），写入失败由调用方吞掉、不反噬本次结果。
class RecommendCacheRepository {
  static const _tag = 'RECOMMEND_CACHE';

  /// 缓存 kind 常量 —— **必须全局唯一**（scope 的格式是 `<kind>:<libraryId>`，
  /// 两个业务键撞在一起就是两份数据互相覆盖）。
  static const String kindHomeCards = 'home_cards';
  static const String kindRecommend = 'recommend';
  static const String kindLocalRecommend = 'local_recommend';
  static const String kindHomeRecommendSection = 'homeRecommendSection';
  static const String kindHomeSections = 'homeSections';
  static const String kindHomePlaylistCount = 'homePlaylistCount';

  final AppDatabase _db;

  RecommendCacheRepository(this._db);

  String _scope(String kind, String libraryId) => '$kind:$libraryId';

  Future<void> _write(
    String kind,
    String libraryId,
    Map<String, dynamic> payload,
  ) async {
    await _db.into(_db.recommendCaches).insertOnConflictUpdate(
          RecommendCachesCompanion.insert(
            scope: _scope(kind, libraryId),
            payload: jsonEncode(payload),
            cachedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  Future<Map<String, dynamic>?> _read(String kind, String libraryId) async {
    final row = await (_db.select(_db.recommendCaches)
          ..where((t) => t.scope.equals(_scope(kind, libraryId))))
        .getSingleOrNull();
    if (row == null || row.payload.isEmpty) return null;
    try {
      return jsonDecode(row.payload) as Map<String, dynamic>;
    } catch (e) {
      Logger.warnWithTag(_tag, 'cache parse failed kind=$kind', e);
      return null;
    }
  }

  /// 容忍性解析：跳过损坏/不兼容的单个条目，一条坏数据不阻断整组读取。
  List<T> _parseList<T>(
    List? rawList,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final out = <T>[];
    for (final e in rawList ?? const []) {
      if (e is! Map || e.isEmpty) continue;
      try {
        out.add(fromJson(Map<String, dynamic>.from(e)));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Home cards
  // -------------------------------------------------------------------------

  Future<void> saveHomeCards(String libraryId, List<HomeCard> cards) {
    return _write(kindHomeCards, libraryId, {
      'cards': cards.map((e) => e.toJson()).toList(),
    });
  }

  Future<List<HomeCard>?> getHomeCards(String libraryId) async {
    final map = await _read(kindHomeCards, libraryId);
    if (map == null) return null;
    return _parseList<HomeCard>(map['cards'] as List?, HomeCard.fromJson);
  }

  // -------------------------------------------------------------------------
  // Recommend channels（整体含 providerId）
  // -------------------------------------------------------------------------

  Future<void> saveRecommendResult(
    String libraryId,
    RecommendResult result,
  ) {
    return _write(kindRecommend, libraryId, result.toJson());
  }

  Future<RecommendResult?> getRecommendResult(String libraryId) async {
    final map = await _read(kindRecommend, libraryId);
    if (map == null) return null;
    final providerId = map['providerId'] as String? ?? '';
    final channels = _parseList<RecommendChannel>(
      map['channels'] as List?,
      RecommendChannel.fromJson,
    );
    return RecommendResult(providerId: providerId, channels: channels);
  }

  // -------------------------------------------------------------------------
  // Local recommend channels
  // -------------------------------------------------------------------------

  Future<void> saveLocalRecommendChannels(
    String libraryId,
    List<LocalRecommendChannel> channels,
  ) {
    return _write(kindLocalRecommend, libraryId, {
      'channels': channels.map((e) => e.toJson()).toList(),
    });
  }

  Future<List<LocalRecommendChannel>?> getLocalRecommendChannels(
    String libraryId,
  ) async {
    final map = await _read(kindLocalRecommend, libraryId);
    if (map == null) return null;
    return _parseList<LocalRecommendChannel>(
      map['channels'] as List?,
      LocalRecommendChannel.fromJson,
    );
  }

  // -------------------------------------------------------------------------
  // Home recommend section（「为你推荐」聚合快照：固定卡 + 随机补位）
  // -------------------------------------------------------------------------

  Future<void> saveHomeRecommendSection(
    String libraryId,
    HomeRecommendSection section,
  ) {
    return _write(kindHomeRecommendSection, libraryId, section.toJson());
  }

  /// 读取「为你推荐」快照。
  ///
  /// 坏数据不炸：`HomeRecommendSection.fromJson` 内部已按字段容错解析
  /// （`whereType` 过滤非 Map 条目、`_normalizeRandomPlaylistJson` 补默认值），
  /// 这里再兜一层 —— 整份解析失败就降级成「无缓存」（返回 null），让调用方
  /// 走远程重拉，而不是让一条脏数据把整块打成永久错误态。
  Future<HomeRecommendSection?> getHomeRecommendSection(
    String libraryId,
  ) async {
    final map = await _read(kindHomeRecommendSection, libraryId);
    if (map == null) return null;
    try {
      return HomeRecommendSection.fromJson(map);
    } catch (e) {
      Logger.warnWithTag(
        _tag,
        'cache parse failed kind=$kindHomeRecommendSection',
        e,
      );
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Home sections（分区清单）
  // -------------------------------------------------------------------------

  Future<void> saveHomeSections(String libraryId, List<HomeSection> sections) {
    return _write(kindHomeSections, libraryId, {
      'sections': sections.map((e) => e.toJson()).toList(),
    });
  }

  Future<List<HomeSection>?> getHomeSections(String libraryId) async {
    final map = await _read(kindHomeSections, libraryId);
    if (map == null) return null;
    return _parseList<HomeSection>(
      map['sections'] as List?,
      HomeSection.fromJson,
    );
  }

  // -------------------------------------------------------------------------
  // Home playlist count（每日推荐插件控制的首页歌单数）
  // -------------------------------------------------------------------------

  Future<void> saveHomePlaylistCount(String libraryId, int count) {
    return _write(kindHomePlaylistCount, libraryId, {'count': count});
  }

  Future<int?> getHomePlaylistCount(String libraryId) async {
    final map = await _read(kindHomePlaylistCount, libraryId);
    return (map?['count'] as num?)?.toInt();
  }
}
