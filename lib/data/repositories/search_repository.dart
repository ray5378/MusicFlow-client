import '../../core/utils/logger.dart';
import '../models/search.dart';
import '../models/song.dart';
import '../sources/subsonic_api_client.dart';

/// 搜索仓库:对齐主项目 web 的 entity-search / playlist-search。
/// 本地搜索由页面自身列表过滤承担;本仓库只负责「聚合 / 插件」远程搜索与导入。
class SearchRepository {
  final SubsonicApiClient _apiClient;

  SearchRepository(this._apiClient);

  static String _base(SearchEntityKind kind) {
    switch (kind) {
      case SearchEntityKind.song:
        return '/rest/api/v1/song-search';
      case SearchEntityKind.album:
        return '/rest/api/v1/album-search';
      case SearchEntityKind.artist:
        return '/rest/api/v1/artist-search';
      case SearchEntityKind.playlist:
        return '/rest/api/v1/playlist-search';
    }
  }

  /// 已启用且声明对应能力的插件列表(搜索来源下拉)
  Future<List<SearchProvider>> getProviders(SearchEntityKind kind) async {
    try {
      final data = await _apiClient.getRaw('${_base(kind)}/providers');
      final list = data['providers'] as List? ?? [];
      return list
          .map((e) => SearchProvider.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      Logger.error('Failed to get search providers', e);
      return [];
    }
  }

  /// 聚合或单插件远程搜索 → 结果按类目归位。
  Future<SearchOutcome> searchRemote(
    SearchEntityKind kind,
    String query, {
    String providerId = '',
  }) async {
    final q = query.trim();
    if (q.isEmpty) return SearchOutcome();
    try {
      final path = providerId.isEmpty
          ? '${_base(kind)}/aggregate/search'
          : '${_base(kind)}/$providerId/search';
      final data = await _apiClient.postRaw(path, data: {'q': q});
      final items = data['items'] as List? ?? [];
      final playlists = data['playlists'] as List? ?? [];
      switch (kind) {
        case SearchEntityKind.song:
          return SearchOutcome(
            songs: items
                .map((e) => SearchSong.fromRemoteJson(
                      e as Map<String, dynamic>,
                      providerId: providerId,
                    ))
                .toList(),
          );
        case SearchEntityKind.album:
          return SearchOutcome(
            albums: items
                .map((e) => SearchAlbum.fromRemoteJson(
                      e as Map<String, dynamic>,
                      providerId: providerId,
                    ))
                .toList(),
          );
        case SearchEntityKind.artist:
          return SearchOutcome(
            artists: items
                .map((e) => SearchArtist.fromRemoteJson(
                      e as Map<String, dynamic>,
                      providerId: providerId,
                    ))
                .toList(),
          );
        case SearchEntityKind.playlist:
          // 聚合歌单接口返回 playlists;单插件返回 items(同结构)
          final plList = playlists.isNotEmpty ? playlists : items;
          return SearchOutcome(
            playlists: plList
                .map((e) => SearchPlaylist.fromRemoteJson(
                      e as Map<String, dynamic>,
                      providerId: providerId,
                    ))
                .toList(),
          );
      }
    } catch (e) {
      Logger.error('Remote search failed', e);
      rethrow;
    }
  }

  /// 拉远程专辑/艺术家内部歌曲列表(只拉不导入),返回可播放 Song 列表。
  Future<List<Song>> getCollectionSongs(
    SearchEntityKind kind,
    String providerId,
    SearchSongLike item,
  ) async {
    final base = _base(kind);
    final query = <String, String>{};
    if (kind == SearchEntityKind.artist) {
      if (item.name.isEmpty) return [];
      query['name'] = item.name;
    } else {
      if (item.source.isEmpty || item.id.isEmpty) return [];
      query['source'] = item.source;
      query['id'] = item.id;
    }
    final data = await _apiClient.getRaw(
      '$base/$providerId/items',
      queryParameters: query,
    );
    final songs = data['items'] as List? ?? [];
    return songs
        .map((e) => SearchSong.fromRemoteJson(
              e as Map<String, dynamic>,
              providerId: providerId,
            ))
        .map((s) => buildRemoteSong(s))
        .toList();
  }

  /// 远程歌单内部歌曲(只拉不导入)
  Future<List<Song>> getPlaylistSongs(
    String providerId,
    SearchPlaylist pl,
  ) async {
    final data = await _apiClient.getRaw(
      '/rest/api/v1/playlist-search/$providerId/items',
      queryParameters: {'source': pl.source, 'id': pl.id},
    );
    final songs = data['items'] as List? ?? [];
    return songs
        .map((e) => SearchSong.fromRemoteJson(
              e as Map<String, dynamic>,
              providerId: providerId,
            ))
        .map((s) => buildRemoteSong(s))
        .toList();
  }

  /// 把远程搜索歌曲转成可直接播放的 Song(走 /rest/stream-remote)。
  Song buildRemoteSong(SearchSong s) {
    final streamUrl = _apiClient.getRemoteStreamUrl(
      provider: s.providerId,
      source: s.source,
      id: s.id,
      title: s.name,
      artist: s.artist,
      album: s.album,
      duration: s.duration,
      cover: s.cover,
    );
    return Song(
      id: 'remote:${s.providerId}:${s.source}:${s.id}',
      title: s.name,
      artist: s.artist.isNotEmpty ? s.artist : null,
      album: s.album.isNotEmpty ? s.album : null,
      duration: s.duration,
      suffix: s.suffix.isNotEmpty ? s.suffix : 'mp3',
      coverArt: s.cover.isNotEmpty ? s.cover : null,
      isPreview: true,
      previewStreamUrl: streamUrl,
      previewCoverUrl: s.cover.isNotEmpty ? s.cover : null,
      previewSource: s.source,
      previewTrackId: s.id,
    );
  }

  // ===================== 导入(加入库) =====================

  /// 歌曲入库:POST /v1/song-search/:providerId/import {songs:[...]} → 异步任务
  Future<String> importSong(
    String providerId,
    List<SearchSong> songs,
  ) async {
    final payload = songs
        .map((s) => ({
              'id': s.id,
              'source': s.source,
              'name': s.name,
              'artist': s.artist,
              'album': s.album,
              'duration': s.duration,
              'cover': s.cover,
              'suffix': s.suffix,
            }))
        .toList();
    return _import('/rest/api/v1/song-search/$providerId/import',
        {'songs': payload});
  }

  /// 专辑入库:POST /v1/album-search/:providerId/import {source,id,name,cover}
  Future<String> importAlbum(
    String providerId,
    SearchAlbum album,
  ) async {
    return _import('/rest/api/v1/album-search/$providerId/import', {
      'source': album.source,
      'id': album.id,
      'name': album.name,
      'cover': album.cover,
    });
  }

  /// 歌单导入:POST /v1/playlist-search/:providerId/import。
  /// 该端点走异步任务(触发即返回 taskId),平台歌单在子进程里拉歌+入库后才生成
  /// library playlistId,因此需要轮询 GET /v1/tasks/:taskId 拿到结果里的 playlistId。
  Future<String> importPlaylist(
    String providerId,
    SearchPlaylist pl,
  ) async {
    final data = await _apiClient.postRaw(
      '/rest/api/v1/playlist-search/$providerId/import',
      data: {
        'source': pl.source,
        'id': pl.id,
        'name': pl.name,
        'cover': pl.cover,
        'creator': pl.creator,
        'trackCount': pl.trackCount,
        'link': pl.link,
      },
    ) as Map<String, dynamic>;
    if (data['success'] != true || data['taskId'] == null) {
      throw Exception(data['error']?.toString() ?? '导入歌单失败');
    }
    final taskId = data['taskId'] as String;
    final result = await _waitTask(taskId);
    final playlistId = result['playlistId'] as String?;
    if (playlistId == null) {
      throw Exception(result['error']?.toString() ?? '导入歌单失败');
    }
    return playlistId;
  }

  /// 轮询异步任务直到完成,返回任务 result(含 playlistId)。
  Future<Map<String, dynamic>> _waitTask(String taskId) async {
    const maxAttempts = 40;
    for (var i = 0; i < maxAttempts; i++) {
      final state = await _apiClient.getRaw(
        '/rest/api/v1/tasks/$taskId',
      ) as Map<String, dynamic>;
      final status = state['status'] as String?;
      if (status == 'ok') {
        final result = state['result'];
        if (result is Map) {
          return Map<String, dynamic>.from(result);
        }
        return <String, dynamic>{};
      }
      if (status == 'error') {
        throw Exception((state['error'] as String?) ?? '导入任务失败');
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    throw Exception('导入歌单超时,请稍后在音乐库查看');
  }

  Future<String> _import(String path, Map<String, dynamic> body) async {
    final data = await _apiClient.postRaw(path, data: body)
        as Map<String, dynamic>;
    if (data['success'] != true) {
      throw Exception(data['error']?.toString() ?? '导入失败');
    }
    if (data['alreadyRunning'] == true) {
      throw Exception('导入任务进行中，请稍候');
    }
    if (data['taskId'] == null) {
      throw Exception('导入未返回任务');
    }
    return data['taskId'] as String;
  }
}

/// 专辑/艺术家取歌时所需的轻量标识(避免直接依赖具体模型)
class SearchSongLike {
  final String id;
  final String source;
  final String name;
  SearchSongLike({this.id = '', this.source = '', this.name = ''});
}
