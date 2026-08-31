import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/utils/logger.dart';
import '../core/utils/network_error_notifier.dart';
import '../data/models/playlist.dart';
import '../data/repositories/metadata_cache_repository.dart';
import '../data/repositories/playlist_repository.dart';

import 'package:musicflow_client/providers/library_provider.dart';

import 'api_provider.dart';
import 'fetch_with_cache_fallback.dart';
import 'metadata_cache_provider.dart';

const _playlistLogTag = 'PLAYLIST';

/// 歌单仓库 Provider
final playlistRepositoryProvider = Provider<PlaylistRepository?>((ref) {
  final activeLib = ref.watch(activeLibraryProvider);
  if (activeLib == null) return null;
  final apiClient = ref.watch(subsonicApiClientProvider);
  return PlaylistRepository(apiClient);
});

final playlistsLoadFailedProvider = StateProvider<bool>((ref) => false);
final favoritePlaylistsLoadFailedProvider = StateProvider<bool>((ref) => false);
final playlistDetailLoadFailedProvider = StateProvider.family<bool, String>(
  (ref, playlistId) => false,
);

/// 最近更新的歌单(按 changed 倒序取前 20)
final recentPlaylistsLoadFailedProvider = StateProvider<bool>((ref) => false);

/// 按 changed 倒序取最近更新的前 20 个歌单(缓存/远程共用同一排序口径)。
List<Playlist> _sortRecentPlaylists(List<Playlist> source) {
  final sorted = <Playlist>[...source]
    ..sort((a, b) {
      final ta = a.changed?.millisecondsSinceEpoch ?? 0;
      final tb = b.changed?.millisecondsSinceEpoch ?? 0;
      return tb.compareTo(ta);
    });
  return sorted.take(20).toList();
}

/// 冷启动活跃库尚未就绪时的缓存兜底:回退到最近使用的库 ID 读缓存秒出。
///
/// 旧实现把这段写在了 `libraryId` 判空的分支里、内层又要求 libraryId 非空,
/// 恒为假 —— 缓存兜底从未生效,正是「首页歌单冷启动不显示」的根因。
Future<List<Playlist>?> _recentPlaylistsFromCache(
  MetadataCacheRepository cache,
  String? libraryId,
) async {
  if (libraryId == null || libraryId.isEmpty) return null;
  final cached = await cache.getPlaylists(libraryId);
  if (cached == null || cached.isEmpty) return null;
  return _sortRecentPlaylists(cached);
}

/// 最近更新的歌单(按 changed 倒序取前 20)
///
/// 与 randomSongsProvider 对齐 —— **保持数据,不自动释放**。
/// 首页分区已改为惰性构建(SliverList.separated),若这里用 autoDispose,
/// 歌单区块一旦滑出视口数据就被释放、滑回来又要重拉,表现为「歌单一直
/// 加载不出来 / 闪一下就空了」;随机歌曲区块之所以正常,正是因为它既
/// keepAlive 又自己先读缓存秒出。
///
/// 冷启动「偶尔刷不出来」根因修复:
/// - **watch 活跃地址状态**:地址探测完成(null→ok)或切线路(failed→ok)时
///   provider 自动重建重拉。此前只 read 一次 ensureActiveAddressProvider,
///   冷启动探测慢时首次用 best-effort 地址请求失败后,地址变 ok 也不会
///   触发重拉,歌单一直停在空/缓存兜底态 —— 表现为「偶尔刷不出来」。
/// - **仓库未就绪也先读缓存兜底**:冷启动活跃库未从 drift 恢复时
///   repository 为 null,旧实现直接返回 [](区块整块隐藏),现改为
///   用最近库 ID 读缓存秒出,和随机歌曲的秒出一致。
final recentPlaylistsProvider = FutureProvider<List<Playlist>>((ref) async {
  final repository = ref.watch(playlistRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  // 地址状态变化(探测完成/切线路)时重建重拉 —— 歌单冷启动自愈的关键。
  ref.watch(activeAddressProvider);
  var libraryId = ref.watch(activeLibraryProvider)?.id;

  // 冷启动活跃库尚未从 drift 就绪:回退到最近使用的库 ID,读缓存秒出,
  // 避免「打开即空白、要手动下拉刷新才显示」。
  if (libraryId == null || libraryId.isEmpty) {
    libraryId = await cache.getLastLibraryId();
  }

  if (repository == null || libraryId == null || libraryId.isEmpty) {
    // 仓库/库仍未就绪:先读缓存兜底(和 randomSongs 的秒出一致),
    // 只有缓存也没有时才返回空。
    final cached = await _recentPlaylistsFromCache(cache, libraryId);
    if (cached != null) {
      Logger.infoWithTag(
        _playlistLogTag,
        'recentPlaylists fallback to cache (repo not ready)',
      );
      return cached;
    }
    Logger.warnWithTag(
      _playlistLogTag,
      'recentPlaylists skipped: repository or library unavailable',
    );
    return <Playlist>[];
  }

  final resolvedLibraryId = libraryId;

  final all = await fetchWithCacheFallback<List<Playlist>>(
    ref: ref,
    label: 'recentPlaylists',
    fetch: () async {
      final list = await repository.getPlaylists();
      list.sort((a, b) {
        final ta = a.changed?.millisecondsSinceEpoch ?? 0;
        final tb = b.changed?.millisecondsSinceEpoch ?? 0;
        return tb.compareTo(ta);
      });
      return list;
    },
    // 写全量缓存,冷启动未就绪时可用同一缓存兜底排序取最近歌单。
    cacheWrite: (list) => cache.cachePlaylists(resolvedLibraryId, list),
    cacheRead: () => _recentPlaylistsFromCache(cache, resolvedLibraryId),
    failedProvider: recentPlaylistsLoadFailedProvider,
    errorMessage: '网络异常，歌单加载失败',
    emptyValue: <Playlist>[],
  );
  return _sortRecentPlaylists(all);
});

/// 所有歌单 Provider(同样保持数据,不自动释放)
final playlistsProvider = FutureProvider<List<Playlist>>((ref) async {
  final repository = ref.watch(playlistRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  // 地址状态变化时重建重拉,与 recentPlaylistsProvider 保持一致。
  ref.watch(activeAddressProvider);
  var libraryId = ref.watch(activeLibraryProvider)?.id;

  if (libraryId == null || libraryId.isEmpty) {
    libraryId = await cache.getLastLibraryId();
  }

  if (repository == null || libraryId == null || libraryId.isEmpty) {
    final cached = await cache.getPlaylists(libraryId ?? '');
    if (cached != null) {
      Logger.infoWithTag(
        _playlistLogTag,
        'playlists fallback to cache (repo not ready)',
      );
      return cached;
    }
    Logger.warnWithTag(
      _playlistLogTag,
      'playlists skipped: repository or library unavailable',
    );
    return <Playlist>[];
  }

  final resolvedLibraryId = libraryId;

  return fetchWithCacheFallback<List<Playlist>>(
    ref: ref,
    label: 'playlists',
    fetch: () => repository.getPlaylists(),
    cacheWrite: (list) => cache.cachePlaylists(resolvedLibraryId, list),
    cacheRead: () => cache.getPlaylists(resolvedLibraryId),
    failedProvider: playlistsLoadFailedProvider,
    errorMessage: '网络异常，歌单加载失败',
    emptyValue: <Playlist>[],
  );
});

/// 当前用户收藏的歌单 Provider(「我喜欢 - 歌单」分区)。
///
/// 服务端无 OpenSubsonic 的「收藏歌单」标准接口,走自定义分页接口
/// /rest/api/v1/playlists?favorite=1 逐页拉取全部收藏歌单,并保留 favorite 状态。
/// autoDispose(对齐 starredProvider):每次打开收藏页都重新拉取,确保在其他页面
/// 收藏/取消收藏歌单后回到这里是最新数据;取消收藏后由上层 invalidate 触发重拉。
final favoritePlaylistsProvider = FutureProvider.autoDispose<List<Playlist>>((
  ref,
) async {
  final repository = ref.watch(playlistRepositoryProvider);
  if (repository == null) {
    return <Playlist>[];
  }
  // 地址状态变化(探测完成/切线路)时重建重拉,与 recentPlaylistsProvider 一致。
  ref.watch(activeAddressProvider);
  await ref.read(ensureActiveAddressProvider.future);
  try {
    const pageSize = 100;
    final playlists = <Playlist>[];
    var page = 1;
    while (true) {
      final res = await repository.getPlaylistsPage(
        page,
        pageSize,
        favoriteOnly: true,
      );
      playlists.addAll(res.items);
      if (playlists.length >= res.total || res.items.isEmpty) break;
      page++;
    }
    ref.read(favoritePlaylistsLoadFailedProvider.notifier).state = false;
    return playlists;
  } catch (e) {
    Logger.warnWithTag(_playlistLogTag, 'favoritePlaylists failed', e);
    ref.read(favoritePlaylistsLoadFailedProvider.notifier).state = true;
    return <Playlist>[];
  }
});

/// 歌单详情 Provider
final playlistDetailProvider = FutureProvider.autoDispose.family<Playlist?, String>((
  ref,
  playlistId,
) async {
  final repository = ref.watch(playlistRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) {
    Logger.warnWithTag(
      _playlistLogTag,
      'playlistDetail skipped: repository or library unavailable',
    );
    return null;
  }
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final playlist = await repository.getPlaylist(playlistId);
    if (playlist != null) {
      await cache.cachePlaylistDetail(libraryId, playlist);
      ref.read(playlistDetailLoadFailedProvider(playlistId).notifier).state =
          false;
      Logger.infoWithTag(
        _playlistLogTag,
        'playlistDetail loaded from remote: playlistId=$playlistId songs=${playlist.songs?.length ?? playlist.songCount}',
      );
    } else {
      Logger.warnWithTag(
        _playlistLogTag,
        'playlistDetail remote returned null: playlistId=$playlistId',
      );
    }
    return playlist;
  } catch (e, stackTrace) {
    Logger.warnWithTag(
      _playlistLogTag,
      'playlistDetail remote load failed: playlistId=$playlistId',
      e,
    );
    Logger.debugWithTag(
      _playlistLogTag,
      'playlistDetail fallback stackTrace: playlistId=$playlistId',
      null,
      stackTrace,
    );
    // 先读缓存：命中即静默兜底展示，不打扰用户。
    final cached = await cache.getPlaylistDetail(libraryId, playlistId);
    if (cached != null) {
      ref.read(playlistDetailLoadFailedProvider(playlistId).notifier).state =
          false;
      Logger.infoWithTag(
        _playlistLogTag,
        'playlistDetail fallback to cache: playlistId=$playlistId songs=${cached.songs?.length ?? cached.songCount}',
      );
      return cached;
    }
    // 远程失败且无缓存，才提示网络异常。
    NetworkErrorNotifier.show('网络异常，歌单加载失败');
    ref.read(playlistDetailLoadFailedProvider(playlistId).notifier).state =
        true;
    Logger.warnWithTag(
      _playlistLogTag,
      'playlistDetail cache miss: playlistId=$playlistId',
    );
    return null;
  }
});
