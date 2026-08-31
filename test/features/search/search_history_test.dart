import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/search_history.dart';

void main() {
  SearchHistoryEntry entry(String query, DateTime timestamp) =>
      SearchHistoryEntry(query: query, timestamp: timestamp);

  test('去重(忽略大小写)并保留最近一次,按最近搜索排序', () {
    final base = DateTime(2026, 9, 1);
    final pruned = pruneSearchHistory(<SearchHistoryEntry>[
      entry('晨光', base),
      entry('Night', base.subtract(const Duration(hours: 2))),
      entry('night', base.subtract(const Duration(hours: 1))),
    ]);
    expect(pruned.map((e) => e.query), <String>['晨光', 'night']);
  });

  test('超过保留期(90 天)的记录自动丢弃', () {
    final now = DateTime(2026, 9, 1);
    final pruned = pruneSearchHistory(<SearchHistoryEntry>[
      entry('新词', now),
      entry('过期词', now.subtract(const Duration(days: 91))),
      entry('将过期', now.subtract(const Duration(days: 89))),
    ], now: now);
    expect(pruned.map((e) => e.query), <String>['新词', '将过期']);
  });

  test('超过上限(30 条)时淘汰最旧的', () {
    final now = DateTime(2026, 9, 1);
    final entries = <SearchHistoryEntry>[
      for (var i = 0; i < 35; i++)
        entry('词$i', now.subtract(Duration(minutes: 35 - i))),
    ];
    final pruned = pruneSearchHistory(entries, now: now);
    expect(pruned, hasLength(kSearchHistoryMaxEntries));
    expect(pruned.first.query, '词34');
    expect(pruned.last.query, '词5');
  });

  test('空词丢弃', () {
    final now = DateTime(2026, 9, 1);
    final pruned = pruneSearchHistory(<SearchHistoryEntry>[
      entry('  ', now),
      entry('有效', now),
    ], now: now);
    expect(pruned.map((e) => e.query), <String>['有效']);
  });
}
