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
  /// [favoriteOnly] 为 true 时仅返回「当前用户已收藏」的歌单(我喜欢-歌单分区)。
  Future<({List<Playlist> items, int total})> getPlaylistsPage(
    int page,
    int pageSize, {
    String query = '',
    bool favoriteOnly = false,
  }) async {
    final data = await _apiClient.getRaw(
      '/rest/api/v1/playlists',
      queryParameters: <String, String>{
        'page': page.toString(),
        'pageSize': pageSize.toString(),
        if (query.isNotEmpty) 'query': query,
        if (favoriteOnly) 'favorite': '1',
      },
    ) as Map<String, dynamic>;
    final items = _parsePlaylists((data['items'] ?? data['playlists']) as List? ?? []);
    final total = (data['total'] as num?)?.toInt() ?? items.length;
    return (items: items, total: total);
  }

  /// 收藏 / 取消收藏歌单:POST /rest/api/v1/playlists/:id/favorite。
  /// 返回服务端处理结果,失败抛异常由上层统一提示。
  Future<bool> setPlaylistFavorite(String playlistId, bool favorite) async {
    final data = await _apiClient.postRaw(
      '/rest/api/v1/playlists/$playlistId/favorite',
      data: <String, dynamic>{'favorite': favorite},
    ) as Map<String, dynamic>;
    return data['success'] == true;
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
    Object? rawItems = data['entries'] ?? data['items'];
    // 容忍性解析：逐条 try/catch，跳过个别损坏/不兼容曲目。否则一条坏数据会让
    // Song.fromJson 抛异常，整页 .map().toList() 一起失败，上游把它误判成
    // 「网络异常」→ Windows 随机歌曲/歌单一直加载失败的根因(只解析了第 49 首，
    // 第 50+ 首里某首字段不兼容即整批崩)。
    final list = _parseSongs((rawItems as List? ?? []));
    final total = (data['total'] as num?)?.toInt() ??
        (data['matched'] as num?)?.toInt() ??
        list.length;
    return (items: list, total: total);
  }

  /// 轻量歌单元数据(不含曲目列表):走 tracks 分页接口 page=1&pageSize=1,
  /// 只取响应里的 playlist 元数据(name/songCount/duration/coverArt/public/owner),
  /// 避免为打开歌单头部而一次性拉取全部曲目(对齐音乐库页的窗口化加载)。
  Future<Playlist?> getPlaylistMeta(String playlistId) async {
    final data = await _apiClient.getRaw(
      '/rest/api/v1/playlists/$playlistId/tracks',
      queryParameters: <String, String>{'page': '1', 'pageSize': '1'},
    ) as Map<String, dynamic>;
    final meta = data['playlist'] as Map<String, dynamic>?;
    if (meta == null) return null;
    return Playlist.fromJson(meta);
  }

  /// 拉取歌单全部曲目(逐页循环,pageSize=200):供「播放全部 / 非默认排序 /
  /// 加入播放列表」等需要完整顺序表的操作使用,渲染层仍保持窗口化不回退全量。
  Future<List<Song>> getAllPlaylistSongs(String playlistId) async {
    final songs = <Song>[];
    var page = 1;
    while (true) {
      final res = await getPlaylistTracksPage(playlistId, page, 200);
      songs.addAll(res.items);
      if (songs.length >= res.total || res.items.isEmpty) break;
      page++;
    }
    return songs;
  }

  /// 获取所有歌单
  Future<List<Playlist>> getPlaylists() async {
    try {
      final response = await _apiClient.get(ApiConstants.getPlaylists);

      final playlistList = response['playlists']?['playlist'] as List?;
      if (playlistList == null) return [];

      return _parsePlaylists(playlistList);
    } catch (e) {
      Logger.error('Failed to get playlists', e);
      rethrow;
    }
  }

  /// 容忍性解析歌单列表：逐条 try/catch，跳过个别损坏/不兼容歌单。
  /// 否则一条坏歌单会让 Playlist.fromJson 抛异常，整批歌单解析失败，
  /// 被上游误判为「网络异常」→ 首页「最新更新歌单/全部歌单」一直加载不出。
  static List<Playlist> _parsePlaylists(List rawList) {
    final result = <Playlist>[];
    for (final e in rawList) {
      if (e is! Map || e.isEmpty) continue;
      try {
        result.add(Playlist.fromJson(Map<String, dynamic>.from(e)));
      } catch (err) {
        Logger.warnWithTag('PLAYLIST', 'skip broken playlist entry', err);
      }
    }
    return result;
  }

  /// 容忍性解析曲目列表：跳过损坏/字段不兼容的单首歌曲，避免整批崩。
  /// 兼容直接歌曲对象(所有字段平铺)与 {song:{...}} 嵌套两种返回。
  static List<Song> _parseSongs(List rawList) {
    final result = <Song>[];
    for (final e in rawList) {
      if (e is! Map || e.isEmpty) continue;
      // 嵌套形式 {song:{...}} 时取内层;平铺时直接用元素本身。
      final embedded = e['song'];
      final songJson = embedded is Map ? embedded : e;
      if (songJson.isEmpty) continue;
      try {
        result.add(Song.fromJson(Map<String, dynamic>.from(songJson)));
      } catch (err) {
        Logger.warnWithTag('PLAYLIST', 'skip broken track entry', err);
      }
    }
    return result;
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
