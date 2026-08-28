import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/song.dart';
import '../data/repositories/music_repository.dart';
import '../core/constants/api_constants.dart';
import '../core/utils/network_error_notifier.dart';
import '../core/utils/logger.dart';
import 'package:musicflow_client/providers/library_provider.dart';

import 'api_provider.dart';
import 'metadata_cache_provider.dart';
import 'playlist_provider.dart';

const _musicLogTag = 'MUSIC';

/// 音乐仓库 Provider
final musicRepositoryProvider = Provider<MusicRepository?>((ref) {
  final activeLib = ref.watch(activeLibraryProvider);
  if (activeLib == null) return null;
  final apiClient = ref.watch(subsonicApiClientProvider);
  return MusicRepository(apiClient);
});

final randomSongsLoadFailedProvider = StateProvider<bool>((ref) => false);
final recentAlbumsLoadFailedProvider = StateProvider<bool>((ref) => false);
final frequentAlbumsLoadFailedProvider = StateProvider<bool>((ref) => false);
final allSongsLoadFailedProvider = StateProvider<bool>((ref) => false);
final allAlbumsLoadFailedProvider = StateProvider<bool>((ref) => false);
final albumDetailLoadFailedProvider = StateProvider.family<bool, String>(
  (ref, albumId) => false,
);
final newestAlbumsLoadFailedProvider = StateProvider<bool>((ref) => false);
final allArtistsLoadFailedProvider = StateProvider<bool>((ref) => false);
final artistDetailLoadFailedProvider = StateProvider.family<bool, String>(
  (ref, artistId) => false,
);
final starredLoadFailedProvider = StateProvider<bool>((ref) => false);
final topSongsByArtistLoadFailedProvider = StateProvider.family<bool, String>(
  (ref, artistName) => false,
);
final searchLoadFailedProvider = StateProvider.autoDispose.family<bool, String>(
  (ref, query) => false,
);

// ---------------------------------------------------------------------------
// 通用辅助：远程获取 + 缓存回退
// ---------------------------------------------------------------------------

/// 通用的远程获取 + 缓存回退逻辑。
///
/// [label] 用于日志标识。
/// [fetch] 执行远程 API 调用。
/// [cacheWrite] 将远程结果写入缓存。
/// [cacheRead] 在远程失败时从缓存读取。
/// [failedNotifier] 用于更新加载失败状态的 StateProvider notifier。
/// [errorMessage] 网络异常时的用户提示。
/// [emptyValue] 远程和缓存都不可用时的默认空值。
Future<T> _fetchWithCacheFallback<T>({
  required Ref ref,
  required String label,
  required Future<T> Function() fetch,
  required Future<void> Function(T data) cacheWrite,
  required Future<T?> Function() cacheRead,
  required StateProvider<bool> failedProvider,
  required String errorMessage,
  required T emptyValue,
}) async {
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final data = await fetch();
    // 缓存写入失败绝不反噬本次已成功获取的数据:写缓存只是为下次命中做优化。
    // Windows 上若个别歌曲元数据含 shared_prefs 无法落盘的字符(孤立代理对/超大值),
    // jsonEncode 或存储会抛 FormatException,若让它冒出去会把整次请求判失败——
    // 于是「网络明明 200、却弹网络异常且不进缓存兜底」,正是 Windows 有网却不显示、
    // 安卓因旧缓存命中而能显示的差异点。
    try {
      await cacheWrite(data);
    } catch (e) {
      Logger.warnWithTag(_musicLogTag, '$label cache write failed', e);
    }
    ref.read(failedProvider.notifier).state = false;
    Logger.infoWithTag(_musicLogTag, '$label loaded from remote');
    return data;
  } catch (e, stackTrace) {
    Logger.warnWithTag(_musicLogTag, '$label remote load failed', e);
    Logger.debugWithTag(
      _musicLogTag,
      '$label fallback stackTrace',
      null,
      stackTrace,
    );
    // 先读缓存;若命中即用缓存兜底并静默返回,不再对用户弹「网络异常」。
    // 否则「Win 刷新随机歌曲」等场景里,明明是离线/接口不可用的环境,每次刷新
    // 都会先弹一次网络异常(尽管随后能展示缓存),造成「总有弹窗又拦不住」的观感,
    // 在安卓弱网下更是集中轰炸,拖累首屏交互。
    T? cached;
    try {
      cached = await cacheRead();
    } catch (e) {
      // 缓存读取本身异常(平台存储/单条坏数据)也不能冒泡成 uncaught,
      // 否则会把一组可恢复的失败放大成整页报错。
      Logger.warnWithTag(_musicLogTag, '$label cache read failed', e);
    }
    if (cached != null) {
      ref.read(failedProvider.notifier).state = false;
      Logger.infoWithTag(_musicLogTag, '$label fallback to cache');
      return cached;
    }
    // 远程失败且无缓存兜底,才向用户提示网络异常。
    NetworkErrorNotifier.show(errorMessage);
    ref.read(failedProvider.notifier).state = true;
    Logger.warnWithTag(_musicLogTag, '$label cache miss');
    return emptyValue;
  }
}

// ---------------------------------------------------------------------------
// Provider 定义
// ---------------------------------------------------------------------------

/// 随机歌曲歌单「变更推送」总线。
///
/// 设计目标:客户端**不再轮询**随机歌曲歌单。歌单由主项目(服务端)插件在
/// 后台维护刷新;当歌单内容变动时,由插件主动发送信号到客户端,客户端监听方
/// 收到信号后重新拉取并更新,避免「打开客户端 → 触发后端惰性重建 → 长时间等待」。
///
/// 接入方式(等服务端推送通道就绪后):
/// - 若服务端提供 WebSocket/SSE 等推送,收到「random-songs-changed」事件时
///   调用 [notifyRandomSongsChanged]();
/// - 本地会改动歌单内容的操作(收藏变更/歌曲信息编辑等)也会调用它,保证客户端内一致。
final StreamController<int> _randomSongsChangedController =
    StreamController<int>.broadcast(sync: true);

int _randomSongsVersion = 0;

/// 订阅随机歌曲歌单变更信号。
Stream<int> randomSongsChangedStream() => _randomSongsChangedController.stream;

/// 通知所有监听方:随机歌曲歌单已变动,请重新拉取。
void notifyRandomSongsChanged() {
  _randomSongsVersion++;
  _randomSongsChangedController.add(_randomSongsVersion);
}

/// 随机歌曲 Provider(保持数据,不自动释放)。
/// 读取主项目「随机歌曲」内置插件的固定歌单 pl-random-songs(默认 48 首,
/// 由插件配置控制数量)。客户端只在「播放一批 / 手动刷新 / 收到歌单变更推送」
/// 时按需拉取,**打开首页不再自动请求**,直接以本地缓存秒出展示,
/// 由插件在后台维护歌单新鲜度,避免惰性重建带来的等待。
final randomSongsProvider = FutureProvider<List<Song>>((ref) async {
  final plRepo = ref.watch(playlistRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (plRepo == null || libraryId == null || libraryId.isEmpty) return [];

  return _fetchWithCacheFallback(
    ref: ref,
    label: 'randomSongs',
    fetch: () => plRepo.getAllPlaylistSongs(ApiConstants.randomSongsPlaylistId),
    cacheWrite: (songs) => cache.cacheRandomSongs(libraryId, songs),
    cacheRead: () => cache.getRandomSongs(libraryId),
    failedProvider: randomSongsLoadFailedProvider,
    errorMessage: '网络异常',
    emptyValue: [],
  );
});

/// 最近播放专辑 Provider（保持数据，不自动释放）
final recentAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final repository = ref.watch(musicRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return _fetchWithCacheFallback(
    ref: ref,
    label: 'recentAlbums',
    fetch: () => repository.getAlbumList(type: 'recent', size: 10),
    cacheWrite: (albums) => cache.cacheRecentAlbums(libraryId, albums),
    cacheRead: () => cache.getRecentAlbums(libraryId),
    failedProvider: recentAlbumsLoadFailedProvider,
    errorMessage: '网络异常',
    emptyValue: [],
  );
});

/// 常听专辑 Provider（保持数据，不自动释放）
final frequentAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final repository = ref.watch(musicRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return _fetchWithCacheFallback(
    ref: ref,
    label: 'frequentAlbums',
    fetch: () => repository.getAlbumList(type: 'frequent', size: 10),
    cacheWrite: (albums) => cache.cacheFrequentAlbums(libraryId, albums),
    cacheRead: () => cache.getFrequentAlbums(libraryId),
    failedProvider: frequentAlbumsLoadFailedProvider,
    errorMessage: '网络异常',
    emptyValue: [],
  );
});

/// 最新专辑 Provider（保持数据，不自动释放）
final newestAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final repository = ref.watch(musicRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return _fetchWithCacheFallback(
    ref: ref,
    label: 'newestAlbums',
    fetch: () => repository.getAlbumList(type: 'newest', size: 20),
    cacheWrite: (albums) => cache.cacheNewestAlbums(libraryId, albums),
    cacheRead: () => cache.getNewestAlbums(libraryId),
    failedProvider: newestAlbumsLoadFailedProvider,
    errorMessage: '网络异常',
    emptyValue: [],
  );
});

/// 所有专辑 Provider（按字母排序）
final allAlbumsProvider = FutureProvider.autoDispose<List<Album>>((ref) async {
  final repository = ref.watch(musicRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return _fetchWithCacheFallback(
    ref: ref,
    label: 'allAlbums',
    fetch: () => repository.getAllAlbums(),
    cacheWrite: (albums) => cache.cacheAllAlbums(libraryId, albums),
    cacheRead: () => cache.getAllAlbums(libraryId),
    failedProvider: allAlbumsLoadFailedProvider,
    errorMessage: '网络异常，专辑加载失败',
    emptyValue: [],
  );
});

/// 专辑详情 Provider
final albumDetailProvider = FutureProvider.autoDispose
    .family<AlbumDetail?, String>((ref, albumId) async {
      final repository = ref.watch(musicRepositoryProvider);
      final cache = ref.watch(metadataCacheRepositoryProvider);
      final libraryId = ref.watch(activeLibraryProvider)?.id;
      if (repository == null || libraryId == null || libraryId.isEmpty) {
        return null;
      }

      return _fetchWithCacheFallback<AlbumDetail?>(
        ref: ref,
        label: 'albumDetail($albumId)',
        fetch: () => repository.getAlbum(albumId),
        cacheWrite: (detail) async {
          if (detail != null) await cache.cacheAlbumDetail(libraryId, detail);
        },
        cacheRead: () => cache.getAlbumDetail(libraryId, albumId),
        failedProvider: albumDetailLoadFailedProvider(albumId),
        errorMessage: '网络异常，专辑加载失败',
        emptyValue: null,
      );
    });

/// 所有歌曲 Provider
final allSongsProvider = FutureProvider.autoDispose<List<Song>>((ref) async {
  final repository = ref.watch(musicRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return _fetchWithCacheFallback(
    ref: ref,
    label: 'allSongs',
    fetch: () => repository.getAllSongs(),
    cacheWrite: (songs) => cache.cacheAllSongs(libraryId, songs),
    cacheRead: () => cache.getAllSongs(libraryId),
    failedProvider: allSongsLoadFailedProvider,
    errorMessage: '网络异常，歌曲加载失败',
    emptyValue: [],
  );
});

/// 所有歌手 Provider
final allArtistsProvider = FutureProvider.autoDispose<List<Artist>>((
  ref,
) async {
  final repository = ref.watch(musicRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) return [];

  return _fetchWithCacheFallback(
    ref: ref,
    label: 'allArtists',
    fetch: () => repository.getAllArtists(),
    cacheWrite: (artists) => cache.cacheAllArtists(libraryId, artists),
    cacheRead: () => cache.getAllArtists(libraryId),
    failedProvider: allArtistsLoadFailedProvider,
    errorMessage: '网络异常，歌手列表加载失败',
    emptyValue: [],
  );
});

/// 歌手详情 Provider
final artistDetailProvider = FutureProvider.autoDispose
    .family<ArtistDetail?, String>((ref, artistId) async {
      final repository = ref.watch(musicRepositoryProvider);
      final cache = ref.watch(metadataCacheRepositoryProvider);
      final libraryId = ref.watch(activeLibraryProvider)?.id;
      if (repository == null || libraryId == null || libraryId.isEmpty) {
        return null;
      }

      return _fetchWithCacheFallback<ArtistDetail?>(
        ref: ref,
        label: 'artistDetail($artistId)',
        fetch: () => repository.getArtist(artistId),
        cacheWrite: (detail) async {
          if (detail != null) {
            await cache.cacheArtistDetail(
              libraryId,
              detail.artist,
              detail.albums,
              detail.songs,
            );
          }
        },
        cacheRead: () async {
          final cached = await cache.getArtistDetail(libraryId, artistId);
          if (cached == null) return null;
          return ArtistDetail(
            artist: cached.artist,
            albums: cached.albums,
            songs: cached.songs,
          );
        },
        failedProvider: artistDetailLoadFailedProvider(artistId),
        errorMessage: '网络异常，歌手详情加载失败',
        emptyValue: null,
      );
    });

/// 热门歌曲 Provider（按歌手名）
final topSongsByArtistProvider = FutureProvider.autoDispose
    .family<List<Song>, String>((ref, artistName) async {
      final repository = ref.watch(musicRepositoryProvider);
      if (repository == null || artistName.trim().isEmpty) {
        return [];
      }

      try {
        await ref.read(ensureActiveAddressProvider.future);
        final songs = await repository.getTopSongs(artistName);
        ref
                .read(topSongsByArtistLoadFailedProvider(artistName).notifier)
                .state =
            false;
        return songs;
      } catch (e) {
        Logger.warnWithTag(
          _musicLogTag,
          'topSongs failed: artist=$artistName',
          e,
        );
        ref
                .read(topSongsByArtistLoadFailedProvider(artistName).notifier)
                .state =
            true;
        return [];
      }
    });

/// 搜索 Provider
final searchProvider = FutureProvider.autoDispose.family<SearchResult, String>((
  ref,
  query,
) async {
  final emptyResult = SearchResult(artists: [], albums: [], songs: []);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  final repository = ref.watch(musicRepositoryProvider);
  if (query.isEmpty || repository == null) {
    if (query.isNotEmpty && !disposed) {
      ref.read(searchLoadFailedProvider(query).notifier).state = false;
    }
    return emptyResult;
  }
  try {
    await ref.read(ensureActiveAddressProvider.future);
    final result = await repository.search(
      query: query,
      artistCount: 10,
      albumCount: 20,
      songCount: 30,
    );
    if (disposed) return emptyResult;
    ref.read(searchLoadFailedProvider(query).notifier).state = false;
    return result;
  } catch (e) {
    if (disposed) return emptyResult;
    Logger.warnWithTag(_musicLogTag, 'search failed: query=$query', e);
    ref.read(searchLoadFailedProvider(query).notifier).state = true;
    return emptyResult;
  }
});

/// 收藏列表 Provider
final starredProvider = FutureProvider.autoDispose<StarredResult>((ref) async {
  final repository = ref.watch(musicRepositoryProvider);
  final cache = ref.watch(metadataCacheRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  if (repository == null || libraryId == null || libraryId.isEmpty) {
    return StarredResult(artists: [], albums: [], songs: []);
  }

  return _fetchWithCacheFallback<StarredResult>(
    ref: ref,
    label: 'starred',
    fetch: () => repository.getStarred(),
    cacheWrite: (result) => cache.cacheStarred(
      libraryId,
      artists: result.artists,
      albums: result.albums,
      songs: result.songs,
    ),
    cacheRead: () async {
      final cached = await cache.getStarred(libraryId);
      if (cached == null) return null;
      return StarredResult(
        artists: cached.artists,
        albums: cached.albums,
        songs: cached.songs,
      );
    },
    failedProvider: starredLoadFailedProvider,
    errorMessage: '网络异常，收藏加载失败',
    emptyValue: StarredResult(artists: [], albums: [], songs: []),
  );
});
