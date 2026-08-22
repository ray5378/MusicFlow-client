import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_store.dart';
import 'models.dart';

/// 主项目 API 客户端：
/// - Subsonic 端点（/rest/*）自动解包 subsonic-response；
/// - 自有端点（/rest/api/v1/*）返回原始 JSON；
/// - 鉴权 query 由 [AuthStore.authQuery] 统一注入。
class ApiClient {
  ApiClient(this._store, {http.Client? client}) : _http = client ?? http.Client();

  final AuthStore _store;
  final http.Client _http;

  /// 供测试注入。
  static Uri buildUri({
    required String server,
    required String path,
    Map<String, String> query = const {},
  }) => Uri.parse('$server$path').replace(queryParameters: {
    ...query,
  });

  Uri _uri(String path, [Map<String, String>? extra]) => buildUri(
    server: _store.server,
    path: path,
    query: {..._store.authQuery(), ...?extra},
  );

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final res = await _http.get(uri).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw ApiException('HTTP ${res.statusCode}', res.statusCode);
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(Uri uri, Object body) async {
    final res = await _http
        .post(
          uri,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      throw ApiException('HTTP ${res.statusCode}', res.statusCode);
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// Subsonic 调用：校验 status 并返回 subsonic-response 内容。
  Future<Map<String, dynamic>> subsonic(
    String endpoint, [
    Map<String, String> params = const {},
  ]) async {
    final data = await _getJson(_uri('/rest/$endpoint', params));
    final inner = data['subsonic-response'] as Map<String, dynamic>?;
    if (inner == null) throw ApiException('响应缺少 subsonic-response', 0);
    if (inner['status'] != 'ok') {
      final err = inner['error'] as Map<String, dynamic>?;
      throw ApiException(err?['message']?.toString() ?? '未知错误', (err?['code'] as num?)?.toInt() ?? 0);
    }
    return inner;
  }

  /// 自有 v1 端点（GET）。
  Future<dynamic> api(String pathWithQueryRoot, Map<String, String> params) =>
      _getJson(_uri('/rest/api/$pathWithQueryRoot', params));

  /// 自有 v1 端点（POST，JSON body）。聚合搜索等。
  Future<Map<String, dynamic>> apiPost(String path, Object body) =>
      _postJson(_uri('/rest/api/$path'), body);

  // ==================== 连接 ====================

  Future<void> ping() => subsonic('ping');

  // ==================== 曲库 ====================

  Future<List<Song>> randomSongs({int size = 20}) async {
    final r = await subsonic('getRandomSongs', {'size': '$size'});
    return _list(r['randomSongs']?['song']).map(Song.fromJson).toList();
  }

  Future<Paged<Song>> songsPage(int page, {int pageSize = 50, String query = ''}) async {
    final d = await api('v1/songs', {
      'page': '$page',
      'pageSize': '$pageSize',
      if (query.isNotEmpty) 'query': query,
    });
    return Paged(
      items: _list(d['items']).map(Song.fromJson).toList(),
      total: (d['total'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Paged<Album>> albumsPage(int page, {int pageSize = 60, String query = ''}) async {
    final d = await api('v1/albums', {
      'page': '$page',
      'pageSize': '$pageSize',
      if (query.isNotEmpty) 'query': query,
    });
    return Paged(items: _list(d['items']).map(Album.fromJson).toList(), total: (d['total'] as num?)?.toInt() ?? 0);
  }

  Future<Paged<Artist>> artistsPage(int page, {int pageSize = 100, String query = ''}) async {
    final d = await api('v1/artists', {
      'page': '$page',
      'pageSize': '$pageSize',
      if (query.isNotEmpty) 'query': query,
    });
    return Paged(items: _list(d['items']).map(Artist.fromJson).toList(), total: (d['total'] as num?)?.toInt() ?? 0);
  }

  Future<(Album?, List<Song>)> albumDetail(String id) async {
    final r = await subsonic('getAlbum', {'id': id});
    final a = r['album'];
    final album = a is Map<String, dynamic> ? Album.fromJson(a) : null;
    final songs = _list(a is Map<String, dynamic> ? a['song'] : null).map(Song.fromJson).toList();
    return (album, songs);
  }

  Future<List<Album>> artistAlbums(String id) async {
    final r = await subsonic('getArtist', {'id': id});
    return _list(r['artist']?['album']).map(Album.fromJson).toList();
  }

  Future<List<Song>> starredSongs() async {
    final r = await subsonic('getStarred2');
    return _list(r['starred2']?['song']).map(Song.fromJson).toList();
  }

  Future<void> setStar({String? songId, String? albumId, String? artistId, required bool star}) async {
    final q = <String, String>{};
    if (songId != null) q['id'] = songId;
    if (albumId != null) q['albumId'] = albumId;
    if (artistId != null) q['artistId'] = artistId;
    await subsonic(star ? 'star' : 'unstar', q);
  }

  Future<void> scrobble(String songId) async {
    try {
      await subsonic('scrobble', {'id': songId, 'submission': 'false'});
    } catch (_) {
      // 上报失败不影响播放。
    }
  }

  // ==================== 歌单 ====================

  Future<Paged<Playlist>> playlistsPage(int page, {int pageSize = 30}) async {
    final d = await api('v1/playlists', {'page': '$page', 'pageSize': '$pageSize'});
    return Paged(
      items: _list(d['items'] ?? d['playlists']).map(Playlist.fromJson).toList(),
      total: (d['total'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<Song>> playlistTracks(String id, {int pageSize = 500}) async {
    final d = await api('v1/playlists/$id/tracks', {'page': '1', 'pageSize': '$pageSize'});
    final entries = _list(d['entries']);
    return entries
        .whereType<Map<String, dynamic>>()
        .map((e) => Song.fromJson((e['song'] as Map<String, dynamic>?) ?? e))
        .toList();
  }

  // ==================== 聚合搜索 ====================

  Future<List<RemoteSong>> searchRemoteSongs(String q) async => _aggSongs('song-search', q);

  Future<List<Album>> searchRemoteAlbums(String q) async {
    final d = await apiPost('v1/album-search/aggregate/search', {'q': q});
    return _list(d['items']).map(Album.fromJson).toList();
  }

  Future<List<Artist>> searchRemoteArtists(String q) async {
    final d = await apiPost('v1/artist-search/aggregate/search', {'q': q});
    return _list(d['items']).map(Artist.fromJson).toList();
  }

  Future<List<RemoteSong>> _aggSongs(String kind, String q) async {
    final d = await apiPost('v1/$kind/aggregate/search', {'q': q});
    return _list(d['items']).map(RemoteSong.fromJson).toList();
  }

  // ==================== URL ====================

  String streamUrl(String songId) => _uri('/rest/stream', {'id': songId}).toString();

  String remoteStreamUrl(RemoteSong s) {
    var cover = s.coverUrl ?? '';
    if (cover.startsWith('/')) cover = '${_store.server}$cover';
    final q = <String, String>{
      'provider': s.providerId,
      'source': s.source,
      'id': s.id,
      'title': s.name,
    };
    if (s.artist != null && s.artist!.isNotEmpty) q['artist'] = s.artist!;
    if (s.album != null && s.album!.isNotEmpty) q['album'] = s.album!;
    if (s.durationSeconds != null) q['duration'] = '${s.durationSeconds!.round()}';
    if (cover.isNotEmpty) q['cover'] = cover;
    return _uri('/rest/stream-remote', q).toString();
  }

  String coverUrl(String? coverArtId, {int size = 300}) {
    if (coverArtId == null || coverArtId.isEmpty) return '';
    if (coverArtId.startsWith('http')) return coverArtId;
    return _uri('/rest/getCoverArt', {'id': coverArtId, 'size': '$size'}).toString();
  }
}

List<Map<String, dynamic>> _list(Object? raw) {
  if (raw is List) {
    return raw.whereType<Map<String, dynamic>>().toList();
  }
  return [];
}

class ApiException implements Exception {
  ApiException(this.message, this.code);
  final String message;
  final int code;
  @override
  String toString() => message;
}
