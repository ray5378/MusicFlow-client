/// 一条搜索历史记录。
class SearchHistoryEntry {
  const SearchHistoryEntry({
    required this.query,
    required this.timestamp,
  });

  final String query;

  /// 最后一次搜索该词的时间(本地时间)。
  final DateTime timestamp;

  factory SearchHistoryEntry.fromJson(Map<String, dynamic> json) {
    final millis = json['ts'];
    return SearchHistoryEntry(
      query: json['q'] as String? ?? '',
      timestamp: millis is int
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'q': query,
        'ts': timestamp.millisecondsSinceEpoch,
      };

  SearchHistoryEntry copyWith({String? query, DateTime? timestamp}) =>
      SearchHistoryEntry(
        query: query ?? this.query,
        timestamp: timestamp ?? this.timestamp,
      );
}

/// 搜索历史保留上限:超过后按时间淘汰最旧的。
const int kSearchHistoryMaxEntries = 30;

/// 搜索历史保留时长:超过后自动丢弃。
const Duration kSearchHistoryRetention = Duration(days: 90);

/// 搜索历史自动清理:
/// 1. 丢弃空词与超过保留期([retention])的记录;
/// 2. 按关键词去重(忽略大小写),同一词只保留最近一次;
/// 3. 按时间倒序(最近搜索在前)后截断到 [maxEntries] 条。
///
/// 纯函数,不触碰存储,便于单测覆盖清理规则。
List<SearchHistoryEntry> pruneSearchHistory(
  List<SearchHistoryEntry> entries, {
  DateTime? now,
  int maxEntries = kSearchHistoryMaxEntries,
  Duration retention = kSearchHistoryRetention,
}) {
  final reference = now ?? DateTime.now();
  final cutoff = reference.subtract(retention);
  final byQuery = <String, SearchHistoryEntry>{};

  for (final entry in entries) {
    final query = entry.query.trim();
    if (query.isEmpty) continue;
    if (entry.timestamp.isBefore(cutoff)) continue;
    final key = query.toLowerCase();
    final existing = byQuery[key];
    if (existing == null || entry.timestamp.isAfter(existing.timestamp)) {
      byQuery[key] = SearchHistoryEntry(query: query, timestamp: entry.timestamp);
    }
  }

  final pruned = byQuery.values.toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  if (pruned.length <= maxEntries) return pruned;
  return pruned.take(maxEntries).toList();
}
