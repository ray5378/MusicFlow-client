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

/// 不同插件的平台推荐频道(网易云/QQ 等)
final recommendChannelsProvider =
    FutureProvider.autoDispose<List<RecommendChannel>>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  if (repository == null) return [];
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final channels = await repository.getRecommendChannels();
    ref.read(recommendChannelsLoadFailedProvider.notifier).state = false;
    Logger.infoWithTag(
      'RECOMMEND',
      'recommend channels loaded, count=${channels.length}',
    );
    return channels;
  } catch (e, stackTrace) {
    Logger.warnWithTag('RECOMMEND', 'recommend channels load failed', e);
    Logger.debugWithTag(
      'RECOMMEND',
      'recommend channels stackTrace',
      null,
      stackTrace,
    );
    ref.read(recommendChannelsLoadFailedProvider.notifier).state = true;
    return [];
  }
});
