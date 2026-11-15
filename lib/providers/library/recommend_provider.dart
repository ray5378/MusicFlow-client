import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/repositories/recommend_cache_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/data/sources/database/database_provider.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

/// 首页歌单数取不到时的回落值（服务端 `/rest/api/v1/home/playlist-count`）。
const int kDefaultHomePlaylistCount = 8;

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

/// 首页分区清单的失败标记。
///
/// 分区清单失败时首页会**回落客户端默认顺序**继续渲染（见 discover_page），
/// 因此这里只记状态、不驱动任何错误 UI。
final homeSectionsLoadFailedProvider = StateProvider<bool>((ref) => false);

/// 首页歌单数（`/home/playlist-count`）的失败标记。
///
/// 该值取不到时静默回落 [kDefaultHomePlaylistCount]，同样不驱动错误 UI。
final homePlaylistCountLoadFailedProvider = StateProvider<bool>(
  (ref) => false,
);

/// 首页分区清单:由服务端决定首页展示哪些分区及其顺序(sortOrder 升序)。
/// 客户端按此清单逐区渲染,服务端增删分区/调序即生效,实现客户端与服务端解耦。
/// 失败时返回空清单,由首页回落默认分区顺序,仅保留失败标记供重试。
///
/// 与 randomSongsProvider 对齐 —— **保持数据,不自动释放**:离开发现页再回来
/// 不重拉;watch 的依赖(活跃库/客户端)变化时 Riverpod 会自动失效重建重拉。
///
/// 批 D:接入 [fetchWithCacheFallback] 并开 `cacheFirst` —— 有缓存当帧交清单,
/// 无缓存才走远程(行为与改造前一致)。
final homeSectionsProvider = FutureProvider<List<HomeSection>>((ref) async {
  final repository = ref.watch(recommendRepositoryProvider);
  if (repository == null) return const <HomeSection>[];
  final cache = ref.watch(recommendCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id ?? '';

  return fetchWithCacheFallback<List<HomeSection>>(
    ref: ref,
    label: 'homeSections',
    fetch: () => repository.getHomeSections(),
    cacheWrite: (sections) => cache.saveHomeSections(libraryId, sections),
    cacheRead: () => cache.getHomeSections(libraryId),
    failedProvider: homeSectionsLoadFailedProvider,
    errorMessage: l10nNowCurrent().core_network_error,
    emptyValue: const <HomeSection>[],
    cacheFirst: true,
    refreshKey: libraryId,
    // 分区清单没有可见的错误态(失败即回落默认顺序),不该为此弹「网络异常」;
    // 具体区块自己的失败提示已经够了,叠起来就是一片 toast。
    notifyOnFailure: false,
  );
});

/// 正在导入的平台推荐歌单 id(导入即播放流程中显示 loading)
final recommendImportingProvider = StateProvider<String?>((ref) => null);

/// 首页固定推荐卡(每日推荐/今日漫游/本地推荐等)。
///
/// 与 randomSongsProvider 对齐 —— **保持数据,不自动释放**:离开发现页再回来
/// 不重拉;watch 的依赖(活跃库/客户端)变化时 Riverpod 会自动失效重建重拉,
/// 无需手动 invalidate。走 fetchWithCacheFallback:远程成功写缓存(下次秒出),
/// 远程失败静默回落缓存,仅「远程失败+缓存未命中」才置 failed 标记。
///
/// 批 D:开 `cacheFirst` —— 与「最近更新的歌单」同款 SWR,有缓存当帧秒出。
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
    cacheFirst: true,
    refreshKey: libraryId,
  );
});

/// 不同插件的平台推荐频道(网易云/QQ 等),整体返回含 providerId。
///
/// 保持数据,不自动释放(见 [homeCardsProvider] 注释);/v1/recommend 冷启动
/// 可达 900ms,失败回落缓存避免白屏等待。
///
/// 批 D:开 `cacheFirst` —— 有缓存当帧秒出,后台再拉新值。
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
    cacheFirst: true,
    refreshKey: libraryId,
  );
});

/// 平台推荐所属插件 providerId(导入歌单时拼接 /v1/online/:providerId/recommend/import)
final recommendProviderIdProvider = Provider<AsyncValue<String>>((ref) {
  return ref
      .watch(recommendChannelsProvider)
      .whenData((r) => r.providerId);
});

/// 每日推荐插件控制的首页歌单数(含今日漫游+随机歌单,默认 8,范围 1~24)。
///
/// 批 D:接 [fetchWithCacheFallback] 并开 `cacheFirst`;失败**仍然静默回
/// [kDefaultHomePlaylistCount]**(老口径),既不弹窗也不让 UI 出错误态 ——
/// 这个值只是「多排几张卡」的微调参数,拿不到就用默认值。
final homePlaylistCountProvider = FutureProvider<int>((ref) async {
  final client = ref.watch(subsonicApiClientProvider);
  final cache = ref.watch(recommendCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id ?? '';

  return fetchWithCacheFallback<int>(
    ref: ref,
    label: 'homePlaylistCount',
    fetch: () async {
      final data = await client.getRaw('/rest/api/v1/home/playlist-count');
      return (data['count'] as num?)?.toInt() ?? kDefaultHomePlaylistCount;
    },
    cacheWrite: (count) => cache.saveHomePlaylistCount(libraryId, count),
    cacheRead: () => cache.getHomePlaylistCount(libraryId),
    failedProvider: homePlaylistCountLoadFailedProvider,
    errorMessage: l10nNowCurrent().core_network_error,
    emptyValue: kDefaultHomePlaylistCount,
    cacheFirst: true,
    refreshKey: libraryId,
    // 失败静默回默认值:老口径,不打扰用户。
    notifyOnFailure: false,
  );
});

/// 首页「为你推荐」区块数据（服务端聚合快照：固定卡 + 随机补位）。
///
/// 与 randomSongsProvider 对齐 —— **保持数据,不自动释放**:离开发现页再回来
/// 不重拉;watch 的依赖(活跃库/客户端)变化时 Riverpod 会自动失效重建重拉。
///
/// 数据源:`GET /rest/api/v1/home/recommend-section`(服务端一次算好)。
/// 与旧实现的三处本质差别:
/// 1. **不再按 songCount 门槛过滤** —— 服务端零门槛下发固定卡,客户端原样展示。
///    旧实现在这里做 `songCount > 30`,把 30 首的卡全部误杀,用户观感「固定卡
///    不见了、全是随机」。
/// 2. **不再翻页建池 + 本地 shuffle** —— 服务端按小时确定性洗牌并冻结快照,
///    同一小时内各端一致;旧实现串行翻 4 页 `/v1/playlists?pageSize=100`
///    (生产 873 张库只覆盖最新 400 张)再 `shuffle(Random())`,既有长尾又有偏差。
/// 3. **失败会置 `homeCardsLoadFailedProvider`** —— 旧实现首屏这条链永远不置位,
///    UI 无法区分「真的没卡」和「加载失败」,只能静默降级成纯随机。
///
/// 批 D:从手写 try/catch 迁进 [fetchWithCacheFallback] 并开 `cacheFirst`
/// (与「最近更新的歌单」同款 SWR)。两条老业务规则**原样保留**:
/// - `repo == null` → 返回 `empty()` 且 `failed = false`(不算失败);
/// - 服务端回带 `playlistId` 为空的坏卡 → 过滤 + `Logger.warnWithTag`。
/// 另外「地址失败不算加载失败」的口径靠 `addressFailureIsLoadFailure: false`
/// 保住:闸预算到期与地址异常都不置 failed,只有真请求失败且无缓存才置 true。
final homeRecommendSectionProvider =
    FutureProvider<HomeRecommendSection>((ref) async {
  final repo = ref.watch(recommendRepositoryProvider);

  // 仓库未就绪(冷启动活跃库还没从 drift 恢复)不是加载失败,不该让 UI 出错误态。
  if (repo == null) {
    ref.read(homeCardsLoadFailedProvider.notifier).state = false;
    return const HomeRecommendSection.empty();
  }

  final cache = ref.watch(recommendCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id ?? '';

  return fetchWithCacheFallback<HomeRecommendSection>(
    ref: ref,
    label: 'homeRecommendSection',
    // 坏卡过滤放在 fetch 里(而不是拿到结果之后再处理):缓存写下来的就是
    // 已经过滤干净的快照,下次 SWR 秒出的内容与本次完全一致。
    fetch: () async =>
        _dropCardsWithoutPlaylistId(await repo.getHomeRecommendSection()),
    cacheWrite: (section) =>
        cache.saveHomeRecommendSection(libraryId, section),
    cacheRead: () async {
      final cached = await cache.getHomeRecommendSection(libraryId);
      // 空快照不算「有缓存」:否则远程一成功但返回空区块之后,SWR 会一直把
      // 空区块当成缓存秒出,固定卡永远不会自己回来。
      if (cached == null || cached.isEmpty) return null;
      return cached;
    },
    failedProvider: homeCardsLoadFailedProvider,
    errorMessage: l10nNowCurrent().core_network_error,
    emptyValue: const HomeRecommendSection.empty(),
    cacheFirst: true,
    refreshKey: libraryId,
    // 地址未就绪 / 闸预算到期都不算「固定卡加载失败」(老口径)。
    addressFailureIsLoadFailure: false,
    // 区块自己有可见的错误态(loadFailed),不再叠一条全局网络异常提示。
    notifyOnFailure: false,
  );
});

/// 过滤服务端回带的「`playlistId` 为空」坏卡(插件数据缺陷)。
///
/// 不这么做的后果:一张空 id 卡会把整排卡拖成一张空封面卡片。过滤后重建对象
/// 返回,`degraded` 等服务端字段**原样透传**(过滤坏卡不改写服务端的判定)。
HomeRecommendSection _dropCardsWithoutPlaylistId(HomeRecommendSection section) {
  var dropped = false;
  final validFixed = <HomeCard>[];
  for (final card in section.fixed) {
    if (card.playlistId.isEmpty) {
      Logger.warnWithTag(
        'RECOMMEND',
        'drop home card without playlistId: name=${card.name}',
      );
      dropped = true;
      continue;
    }
    validFixed.add(card);
  }
  if (!dropped) return section;
  return HomeRecommendSection(
    hourBucket: section.hourBucket,
    homeCount: section.homeCount,
    degraded: section.degraded,
    fixed: validFixed,
    random: section.random,
  );
}

/// 本地随机歌单(按平台):经 /v1/local-recommend 获取本地库按平台分组随机歌单。
/// 返回的歌单均已入库,客户端直接以本地 id 打开/播放(无需导入刷新)。
///
/// 保持数据,不自动释放(见 [homeCardsProvider] 注释);失败回落缓存避免白屏。
///
/// 批 D:开 `cacheFirst` —— 有缓存当帧秒出,后台再拉新值。
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
    cacheFirst: true,
    refreshKey: libraryId,
  );
});
