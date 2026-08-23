import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/logger.dart';
import '../data/models/recommend.dart';
import '../data/repositories/recommend_repository.dart';
import 'api_provider.dart';
import 'library_provider.dart';

final recommendRepositoryProvider = Provider<RecommendRepository?>((ref) {
  final activeLib = ref.watch(activeLibraryProvider);
  if (activeLib == null) return null;
  final apiClient = ref.watch(subsonicApiClientProvider);
  return RecommendRepository(apiClient);
});

final homeCardsLoadFailedProvider = StateProvider<bool>((ref) => false);
final recommendChannelsLoadFailedProvider = StateProvider<bool>((ref) => false);

/// 正在导入的平台推荐歌单 id(导入即播放流程中显示 loading)
final recommendImportingProvider = StateProvider<String?>((ref) => null);

/// 首页固定推荐卡(每日推荐/今日漫游/本地推荐等)
final homeCardsProvider =
    FutureProvider.autoDispose<List<HomeCard>>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  if (repository == null) return [];
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final cards = await repository.getHomeCards();
    ref.read(homeCardsLoadFailedProvider.notifier).state = false;
    Logger.infoWithTag('RECOMMEND', 'home cards loaded, count=${cards.length}');
    return cards;
  } catch (e, stackTrace) {
    Logger.warnWithTag('RECOMMEND', 'home cards load failed', e);
    Logger.debugWithTag('RECOMMEND', 'home cards stackTrace', null, stackTrace);
    ref.read(homeCardsLoadFailedProvider.notifier).state = true;
    return [];
  }
});

/// 不同插件的平台推荐频道(网易云/QQ 等),整体返回含 providerId。
final recommendChannelsProvider =
    FutureProvider.autoDispose<RecommendResult>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  if (repository == null) {
    return RecommendResult(providerId: '', channels: []);
  }
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final result = await repository.getRecommend();
    ref.read(recommendChannelsLoadFailedProvider.notifier).state = false;
    Logger.infoWithTag(
      'RECOMMEND',
      'recommend channels loaded, providerId=${result.providerId}, count=${result.channels.length}',
    );
    return result;
  } catch (e, stackTrace) {
    Logger.warnWithTag('RECOMMEND', 'recommend channels load failed', e);
    Logger.debugWithTag(
      'RECOMMEND',
      'recommend channels stackTrace',
      null,
      stackTrace,
    );
    ref.read(recommendChannelsLoadFailedProvider.notifier).state = true;
    return RecommendResult(providerId: '', channels: []);
  }
});

/// 平台推荐所属插件 providerId(导入歌单时拼接 /v1/online/:providerId/recommend/import)
final recommendProviderIdProvider = Provider<AsyncValue<String>>((ref) {
  return ref
      .watch(recommendChannelsProvider)
      .whenData((r) => r.providerId);
});

/// 每日推荐插件控制的首页歌单数(含今日漫游+随机歌单,默认 8,范围 1~24)。
final homePlaylistCountProvider = FutureProvider<int>((ref) async {
  final client = ref.watch(subsonicApiClientProvider);
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final data = await client.getRaw('/rest/api/v1/home/playlist-count');
    return (data['count'] as num?)?.toInt() ?? 8;
  } catch (_) {
    return 8;
  }
});
