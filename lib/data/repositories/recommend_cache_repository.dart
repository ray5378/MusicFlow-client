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
    return _write('home_cards', libraryId, {
      'cards': cards.map((e) => e.toJson()).toList(),
    });
  }

  Future<List<HomeCard>?> getHomeCards(String libraryId) async {
    final map = await _read('home_cards', libraryId);
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
    return _write('recommend', libraryId, result.toJson());
  }

  Future<RecommendResult?> getRecommendResult(String libraryId) async {
    final map = await _read('recommend', libraryId);
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
    return _write('local_recommend', libraryId, {
      'channels': channels.map((e) => e.toJson()).toList(),
    });
  }

  Future<List<LocalRecommendChannel>?> getLocalRecommendChannels(
    String libraryId,
  ) async {
    final map = await _read('local_recommend', libraryId);
    if (map == null) return null;
    return _parseList<LocalRecommendChannel>(
      map['channels'] as List?,
      LocalRecommendChannel.fromJson,
    );
  }
}
