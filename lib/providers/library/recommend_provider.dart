import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/repositories/recommend_cache_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/data/sources/database/database_provider.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

final recommendRepositoryProvider = Provider<RecommendRepository?>((ref) {
  final activeLib = ref.watch(activeLibraryProvider);
  if (activeLib == null) return null;
  final apiClient = ref.watch(subsonicApiClientProvider);
  return RecommendRepository(apiClient);
});

/// 推荐类首页数据缓存仓库 Provider（drift KV-JSON 表）。
final recommendCacheRepositoryProvider = Provider<RecommendCacheRepository>((
  ref,
) {
  return RecommendCacheRepository(ref.watch(appDatabaseProvider));
});

final homeCardsLoadFailedProvider = StateProvider<bool>((ref) => false);
final recommendChannelsLoadFailedProvider = StateProvider<bool>((ref) => false);
final localRecommendChannelsLoadFailedProvider = StateProvider<bool>(
  (ref) => false,
);

/// 首页分区清单:由服务端决定首页展示哪些分区及其顺序(sortOrder 升序)。
/// 客户端按此清单逐区渲染,服务端增删分区/调序即生效,实现客户端与服务端解耦。
/// 失败时返回空清单,由首页回落默认分区顺序,仅保留失败标记供重试。
///
/// 与 randomSongsProvider 对齐 —— **保持数据,不自动释放**:离开发现页再回来
/// 不重拉;watch 的依赖(活跃库/客户端)变化时 Riverpod 会自动失效重建重拉。
final homeSectionsProvider = FutureProvider<List<HomeSection>>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  if (repository == null) return const <HomeSection>[];
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final sections = await repository.getHomeSections();
    Logger.infoWithTag(
      'RECOMMEND',
      'home sections loaded, count=${sections.length}',
    );
    return sections;
  } catch (e, stackTrace) {
    Logger.warnWithTag('RECOMMEND', 'home sections load failed', e);
    Logger.debugWithTag('RECOMMEND', 'home sections stackTrace', null, stackTrace);
    return const <HomeSection>[];
  }
});

/// 正在导入的平台推荐歌单 id(导入即播放流程中显示 loading)
final recommendImportingProvider = StateProvider<String?>((ref) => null);

/// 首页固定推荐卡(每日推荐/今日漫游/本地推荐等)。
///
/// 与 randomSongsProvider 对齐 —— **保持数据,不自动释放**:离开发现页再回来
/// 不重拉;watch 的依赖(活跃库/客户端)变化时 Riverpod 会自动失效重建重拉,
/// 无需手动 invalidate。走 fetchWithCacheFallback:远程成功写缓存(下次秒出),
/// 远程失败静默回落缓存,仅「远程失败+缓存未命中」才置 failed 标记。
final homeCardsProvider = FutureProvider<List<HomeCard>>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  final cache = ref.watch(recommendCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return fetchWithCacheFallback<List<HomeCard>>(
    ref: ref,
    label: 'homeCards',
    fetch: () => repository.getHomeCards(),
    cacheWrite: (cards) => cache.saveHomeCards(libraryId, cards),
    cacheRead: () => cache.getHomeCards(libraryId),
    failedProvider: homeCardsLoadFailedProvider,
    errorMessage: l10nNowCurrent().core_network_error,
    emptyValue: <HomeCard>[],
  );
});

/// 不同插件的平台推荐频道(网易云/QQ 等),整体返回含 providerId。
///
/// 保持数据,不自动释放(见 [homeCardsProvider] 注释);/v1/recommend 冷启动
/// 可达 900ms,失败回落缓存避免白屏等待。
final recommendChannelsProvider = FutureProvider<RecommendResult>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  final cache = ref.watch(recommendCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) {
    return RecommendResult(providerId: '', channels: []);
  }

  return fetchWithCacheFallback<RecommendResult>(
    ref: ref,
    label: 'recommendChannels',
    fetch: () => repository.getRecommend(),
    cacheWrite: (result) => cache.saveRecommendResult(libraryId, result),
    cacheRead: () => cache.getRecommendResult(libraryId),
    failedProvider: recommendChannelsLoadFailedProvider,
    errorMessage: l10nNowCurrent().core_network_error,
    emptyValue: RecommendResult(providerId: '', channels: []),
  );
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

/// 首页「为你推荐」顶部卡片：固定推荐卡 + 随机补位本地歌单。
/// 对齐主项目前端 Home/index.vue：
/// - 固定卡来自 /v1/recommend/home-cards（今日漫游/每日推荐/本地推荐，>30 首门槛）；
/// - 随机歌单从本地库歌单随机抽取（排除固定卡、≥30 首），
///   补足到 homeCount 张（每日推荐插件配置，默认 8，含今日漫游固定卡）。
class HomeRecommendSection {
  final List<HomeCard> fixed;
  final List<Playlist> random;

  const HomeRecommendSection({required this.fixed, required this.random});

  bool get isEmpty => fixed.isEmpty && random.isEmpty;
}

final homeRecommendSectionProvider =
    FutureProvider.autoDispose<HomeRecommendSection>((ref) async {
  final repo = ref.watch(recommendRepositoryProvider);
  final plRepo = ref.watch(playlistRepositoryProvider);

  // 1) 固定推荐卡（>30 首门槛，与主项目一致）
  var fixed = <HomeCard>[];
  if (repo != null) {
    try {
      await ref.read(ensureActiveAddressProvider.future);
      fixed = await repo.getHomeCards();
    } catch (e) {
      Logger.warnWithTag('RECOMMEND', 'home cards load failed', e);
    }
  }
  final fixedCards = fixed.where((c) => c.songCount > 30).toList();

  // 2) 首页张数（默认 8，每日推荐插件配置）
  var homeCount = 8;
  try {
    homeCount = await ref.read(homePlaylistCountProvider.future);
  } catch (_) {}

  // 3) 随机补位本地歌单
  final random = <Playlist>[];
  final fixedIds = fixedCards.map((c) => c.playlistId).toSet();
  final needed = max(0, homeCount - fixedCards.length);
  if (plRepo != null && needed > 0) {
    final pool = <Playlist>[];
    try {
      // 首页随机池：取前若干页本地歌单（上限控制），随机抽取
      for (var page = 1; page <= 4 && pool.length < 400; page++) {
        final r = await plRepo.getPlaylistsPage(page, 100, query: '');
        pool.addAll(r.items);
        if (r.items.length < 100) break;
      }
    } catch (e) {
      Logger.warnWithTag('RECOMMEND', 'random playlist pool load failed', e);
    }
    pool.shuffle(Random());
    for (final p in pool) {
      if (random.length >= needed) break;
      if (fixedIds.contains(p.id)) continue;
      if (p.songCount < 30) continue;
      random.add(p);
    }
  }

  return HomeRecommendSection(fixed: fixedCards, random: random);
});

/// 本地随机歌单(按平台):经 /v1/local-recommend 获取本地库按平台分组随机歌单。
/// 返回的歌单均已入库,客户端直接以本地 id 打开/播放(无需导入刷新)。
///
/// 保持数据,不自动释放(见 [homeCardsProvider] 注释);失败回落缓存避免白屏。
final localRecommendChannelsProvider =
    FutureProvider<List<LocalRecommendChannel>>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  final cache = ref.watch(recommendCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return fetchWithCacheFallback<List<LocalRecommendChannel>>(
    ref: ref,
    label: 'localRecommendChannels',
    fetch: () => repository.getLocalRecommend(),
    cacheWrite: (channels) =>
        cache.saveLocalRecommendChannels(libraryId, channels),
    cacheRead: () => cache.getLocalRecommendChannels(libraryId),
    failedProvider: localRecommendChannelsLoadFailedProvider,
    errorMessage: l10nNowCurrent().core_network_error,
    emptyValue: <LocalRecommendChannel>[],
  );
});
