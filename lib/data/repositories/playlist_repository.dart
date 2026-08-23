import '../../core/constants/api_constants.dart';
import '../../core/utils/logger.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../sources/subsonic_api_client.dart';

/// 歌单仓库
class PlaylistRepository {
  final SubsonicApiClient _apiClient;

  PlaylistRepository(this._apiClient);

  /// 单页歌单(窗口化加载):对齐 Web 前端 useCardGrid 的 RangeFetcher,
  /// 走 /rest/api/v1/playlists 服务端分页(page/pageSize/query/local/favorite)。
  Future<({List<Playlist> items, int total})> getPlaylistsPage(
    int page,
    int pageSize, {
    String query = '',
  }) async {
    final data = await _apiClient.getRaw(
      '/rest/api/v1/playlists',
      queryParameters: <String, String>{
        'page': page.toString(),
        'pageSize': pageSize.toString(),
        if (query.isNotEmpty) 'query': query,
      },
    ) as Map<String, dynamic>;
    final items = ((data['items'] ?? data['playlists']) as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(Playlist.fromJson)
        .toList();
    final total = (data['total'] as num?)?.toInt() ?? items.length;
    return (items: items, total: total);
  }

  /// 单页歌单曲目(窗口化加载):走 /rest/api/v1/playlists/:id/tracks 分页。
  Future<({List<Song> items, int total})> getPlaylistTracksPage(
    String playlistId,
    int page,
    int pageSize,
  ) async {
    final data = await _apiClient.getRaw(
      '/rest/api/v1/playlists/$playlistId/tracks',
      queryParameters: <String, String>{
        'page': page.toString(),
        'pageSize': pageSize.toString(),
      },
    ) as Map<String, dynamic>;

    // 兼容两种返回:直接 entries 数组 或 {items,total}。
    Object? rawItems = data['entries'];
    if (rawItems == null) rawItems = data['items'];
    final list = (rawItems as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((e) => Song.fromJson((e['song'] as Map<String, dynamic>?) ?? e))
        .toList();
    final total = (data['total'] as num?)?.toInt() ??
        (data['matched'] as num?)?.toInt() ??
        list.length;
    return (items: list, total: total);
  }

  /// 获取所有歌单
  Future<List<Playlist>> getPlaylists() async {
    try {
      final response = await _apiClient.get(ApiConstants.getPlaylists);

      final playlistList = response['playlists']?['playlist'] as List?;
      if (playlistList == null) return [];

      return playlistList
          .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      Logger.error('Failed to get playlists', e);
      rethrow;
    }
  }

  /// 获取歌单详情（包含歌曲列表）
  Future<Playlist?> getPlaylist(String playlistId) async {
    try {
      final response = await _apiClient.get(
        ApiConstants.getPlaylist,
        queryParameters: {'id': playlistId},
      );

      final playlistData = response['playlist'];
      if (playlistData == null) return null;

      return Playlist.fromJson(playlistData as Map<String, dynamic>);
    } catch (e) {
      Logger.error('Failed to get playlist', e);
      rethrow;
    }
  }

  /// 创建歌单
  Future<Playlist?> createPlaylist({
    required String name,
    List<String>? songIds,
  }) async {
    try {
      final queryParams = {
        'name': name,
        if (songIds != null && songIds.isNotEmpty) 'songId': songIds,
      };

      final response = await _apiClient.get(
        ApiConstants.createPlaylist,
        queryParameters: queryParams,
        allowFallbackRetry: false,
      );

      final playlistData = response['playlist'];
      if (playlistData == null) return null;

      return Playlist.fromJson(playlistData as Map<String, dynamic>);
    } catch (e) {
      Logger.error('Failed to create playlist', e);
      rethrow;
    }
  }

  /// 更新歌单
  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    bool? public,
    List<String>? songIdsToAdd,
    List<int>? songIndexesToRemove,
  }) async {
    try {
      final queryParams = {
        'playlistId': playlistId,
        if (name != null) 'name': name,
        if (comment != null) 'comment': comment,
        if (public != null) 'public': public.toString(),
        if (songIdsToAdd != null && songIdsToAdd.isNotEmpty)
          'songIdToAdd': songIdsToAdd,
        if (songIndexesToRemove != null && songIndexesToRemove.isNotEmpty)
          'songIndexToRemove': songIndexesToRemove
              .map((i) => i.toString())
              .toList(),
      };

      await _apiClient.get(
        ApiConstants.updatePlaylist,
        queryParameters: queryParams,
        allowFallbackRetry: false,
      );
    } catch (e) {
      Logger.error('Failed to update playlist', e);
      rethrow;
    }
  }

  /// 删除歌单
  Future<void> deletePlaylist(String playlistId) async {
    try {
      await _apiClient.get(
        ApiConstants.deletePlaylist,
        queryParameters: {'id': playlistId},
        allowFallbackRetry: false,
      );
    } catch (e) {
      Logger.error('Failed to delete playlist', e);
      rethrow;
    }
  }
}
