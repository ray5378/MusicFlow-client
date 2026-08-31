import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/logger.dart';
import '../../data/models/search_history.dart';
import '../../data/sources/local_storage.dart';

/// 搜索历史控制器:持久化到 SharedPreferences,跨启动保留。
///
/// 自动清理规则(见 [pruneSearchHistory]):
/// - 超过 90 天的记录自动丢弃;
/// - 同一关键词(忽略大小写)只保留最近一次;
/// - 最多保留 30 条,超出部分淘汰最旧的。
/// 清理在每次读取与每次写入时各执行一次,长期不打开也不会无限堆积。
class SearchHistoryController
    extends StateNotifier<AsyncValue<List<SearchHistoryEntry>>> {
  SearchHistoryController()
      : super(const AsyncValue<List<SearchHistoryEntry>>.loading()) {
    unawaited(refresh());
  }

  static const String _logTag = 'SEARCH_HISTORY';

  /// 重新读取(并顺带执行一次过期清理)。
  Future<void> refresh() async {
    try {
      final stored = await LocalStorage.getSearchHistory();
      final pruned = pruneSearchHistory(stored);
      if (!mounted) return;
      state = AsyncValue<List<SearchHistoryEntry>>.data(pruned);
      if (pruned.length != stored.length) {
        await LocalStorage.saveSearchHistory(pruned);
      }
    } catch (e) {
      Logger.warnWithTag(_logTag, 'load search history failed', e);
      if (!mounted) return;
      state = const AsyncValue<List<SearchHistoryEntry>>.data(
        <SearchHistoryEntry>[],
      );
    }
  }

  /// 记录一次搜索(同词更新到最前,并触发清理后回写)。
  Future<void> record(String query) async {
    final term = query.trim();
    if (term.isEmpty) return;
    try {
      final stored = await LocalStorage.getSearchHistory();
      final entry = SearchHistoryEntry(query: term, timestamp: DateTime.now());
      final pruned = pruneSearchHistory(<SearchHistoryEntry>[entry, ...stored]);
      if (!mounted) return;
      state = AsyncValue<List<SearchHistoryEntry>>.data(pruned);
      await LocalStorage.saveSearchHistory(pruned);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'record search history failed', e);
    }
  }

  /// 删除单条历史。
  Future<void> remove(String query) async {
    final term = query.trim();
    if (term.isEmpty) return;
    try {
      final current = state.valueOrNull ?? const <SearchHistoryEntry>[];
      final next = <SearchHistoryEntry>[
        for (final entry in current)
          if (entry.query.toLowerCase() != term.toLowerCase()) entry,
      ];
      if (!mounted) return;
      state = AsyncValue<List<SearchHistoryEntry>>.data(next);
      await LocalStorage.saveSearchHistory(next);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'remove search history failed', e);
    }
  }

  /// 清空全部历史。
  Future<void> clear() async {
    try {
      if (!mounted) return;
      state = const AsyncValue<List<SearchHistoryEntry>>.data(
        <SearchHistoryEntry>[],
      );
      await LocalStorage.clearSearchHistory();
    } catch (e) {
      Logger.warnWithTag(_logTag, 'clear search history failed', e);
    }
  }
}

final searchHistoryProvider = StateNotifierProvider.autoDispose<
    SearchHistoryController, AsyncValue<List<SearchHistoryEntry>>>((ref) {
  return SearchHistoryController();
});
