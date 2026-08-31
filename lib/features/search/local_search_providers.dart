import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/logger.dart';
import '../../data/models/album.dart';
import '../../data/models/artist.dart';
import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../providers/api_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/music_provider.dart';
import '../../providers/playlist_provider.dart';

/// 本地搜索每类最多展示的条数(与聚合搜索「本地结果」块的 limit 一致)。
const int kLocalSearchPageSize = 12;

/// 一页本地搜索结果(本页条目 + 服务端总数)。
typedef LocalSearchPage<T> = ({List<T> items, int total});

/// 空页:未连接音乐库/关键词为空时统一返回,避免发出无效请求。
LocalSearchPage<T> _emptyPage<T>() => (items: <T>[], total: 0);

/// 本地歌曲搜索。
final localSongSearchProvider = FutureProvider.autoDispose
    .family<LocalSearchPage<Song>, String>((ref, query) async {
  final repository = ref.watch(musicRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final q = query.trim();
  if (q.isEmpty || repository == null || libraryId == null || libraryId.isEmpty) {
    return _emptyPage<Song>();
  }
  try {
    await ref.read(ensureActiveAddressProvider.future);
    return await repository.getSongsPage(0, kLocalSearchPageSize, query: q);
  } catch (e) {
    Logger.warnWithTag('SEARCH', 'local song search failed: $q', e);
    rethrow;
  }
});

/// 本地专辑搜索。
final localAlbumSearchProvider = FutureProvider.autoDispose
    .family<LocalSearchPage<Album>, String>((ref, query) async {
  final repository = ref.watch(musicRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final q = query.trim();
  if (q.isEmpty || repository == null || libraryId == null || libraryId.isEmpty) {
    return _emptyPage<Album>();
  }
  try {
    await ref.read(ensureActiveAddressProvider.future);
    return await repository.getAlbumsPage(0, kLocalSearchPageSize, query: q);
  } catch (e) {
    Logger.warnWithTag('SEARCH', 'local album search failed: $q', e);
    rethrow;
  }
});

/// 本地艺术家搜索。
final localArtistSearchProvider = FutureProvider.autoDispose
    .family<LocalSearchPage<Artist>, String>((ref, query) async {
  final repository = ref.watch(musicRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final q = query.trim();
  if (q.isEmpty || repository == null || libraryId == null || libraryId.isEmpty) {
    return _emptyPage<Artist>();
  }
  try {
    await ref.read(ensureActiveAddressProvider.future);
    return await repository.getArtistsPage(0, kLocalSearchPageSize, query: q);
  } catch (e) {
    Logger.warnWithTag('SEARCH', 'local artist search failed: $q', e);
    rethrow;
  }
});

/// 本地歌单搜索。
final localPlaylistSearchProvider = FutureProvider.autoDispose
    .family<LocalSearchPage<Playlist>, String>((ref, query) async {
  final repository = ref.watch(playlistRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final q = query.trim();
  if (q.isEmpty || repository == null || libraryId == null || libraryId.isEmpty) {
    return _emptyPage<Playlist>();
  }
  try {
    await ref.read(ensureActiveAddressProvider.future);
    return await repository.getPlaylistsPage(0, kLocalSearchPageSize, query: q);
  } catch (e) {
    Logger.warnWithTag('SEARCH', 'local playlist search failed: $q', e);
    rethrow;
  }
});

/// 热门搜索词(本地兜底)。
///
/// 服务端暂无热门搜索接口,这里用「我的收藏」兜底:优先收藏的艺术家名,
/// 其次收藏专辑名,最后用收藏歌曲的歌手名补齐。无收藏时返回空列表,
/// 调用方整块隐藏「热门搜索」。
final hotSearchTermsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  try {
    final starred = await ref.watch(starredProvider.future);
    return buildHotSearchTerms(starred);
  } catch (e) {
    Logger.warnWithTag('SEARCH', 'hot search terms failed', e);
    return const <String>[];
  }
});

/// 由收藏结果构造热门搜索词:去重(忽略大小写)后最多取 [limit] 个。
@visibleForTesting
List<String> buildHotSearchTerms(
  StarredResult starred, {
  int limit = 10,
}) {
  final seen = <String>{};
  final terms = <String>[];
  void add(String? value) {
    if (terms.length >= limit) return;
    final term = value?.trim() ?? '';
    if (term.isEmpty) return;
    if (!seen.add(term.toLowerCase())) return;
    terms.add(term);
  }

  for (final artist in starred.artists) {
    add(artist.name);
  }
  for (final album in starred.albums) {
    add(album.name);
  }
  for (final song in starred.songs) {
    add(song.artist);
  }
  return terms.take(limit).toList();
}
