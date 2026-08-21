import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/logger.dart';
import '../data/models/search.dart';
import '../data/repositories/search_repository.dart';
import 'api_provider.dart';

final searchRepositoryProvider = Provider<SearchRepository?>((ref) {
  final apiClient = ref.watch(subsonicApiClientProvider);
  return SearchRepository(apiClient);
});

/// 已启用且声明对应能力的插件(搜索来源下拉)
final searchProvidersProvider =
    FutureProvider.autoDispose.family<List<SearchProvider>, SearchEntityKind>(
  (ref, kind) async {
    final repo = ref.watch(searchRepositoryProvider);
    if (repo == null) return [];
    try {
      await ref.read(ensureActiveAddressProvider.future);
      return await repo.getProviders(kind);
    } catch (e) {
      Logger.warnWithTag('SEARCH', 'getProviders failed kind=$kind', e);
      return [];
    }
  },
);

/// 聚合/插件远程搜索结果(本地搜索由页面自身列表过滤承担,这里返回空)。
final searchResultsProvider =
    FutureProvider.autoDispose.family<SearchOutcome, SearchRequest>(
  (ref, req) async {
    final repo = ref.watch(searchRepositoryProvider);
    if (repo == null) return SearchOutcome();
    if (req.mode == SearchMode.local || req.query.trim().isEmpty) {
      return SearchOutcome();
    }
    try {
      await ref.read(ensureActiveAddressProvider.future);
      return await repo.searchRemote(
        req.kind,
        req.query,
        providerId: req.providerId,
      );
    } catch (e) {
      Logger.warnWithTag('SEARCH', 'searchRemote failed $req', e);
      rethrow;
    }
  },
);
