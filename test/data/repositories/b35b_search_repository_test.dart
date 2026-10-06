// b35b: search_repository.dart 补测(逻辑层收尾批)。
// 产品代码零改动。FakeApiClient 路由 getRaw/postRaw(同 b31a 姿势),
// 覆盖: getProviders 解析/容错、searchRemote 四类目路径与解析边界、
// getCollectionSongs/getPlaylistSongs 守卫与取歌、buildRemoteSong 回退、
// 导入三态、startPlaylistImport alreadyRunning 复用、waitTask 嵌套/顶层/超时。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

class FakeApiClient extends SubsonicApiClient {
  FakeApiClient() : super(dio: Dio(BaseOptions(baseUrl: 'http://localhost')));

  final Map<String, dynamic> responses = {};
  final List<String> getPaths = <String>[];
  final List<String> postPaths = <String>[];
  final List<Map<String, dynamic>> postBodies = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>?> getQueries = <Map<String, dynamic>?>[];
  Object? Function(String path)? errorFor;

  /// 每次 getRaw 前回调(轮询场景中途切换响应用)。
  void Function()? beforeGet;

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    getPaths.add(path);
    getQueries.add(queryParameters);
    beforeGet?.call();
    if (errorFor != null) {
      final e = errorFor!(path);
      if (e != null) throw e;
    }
    return jsonDecode(jsonEncode(responses[path] ?? <String, dynamic>{}));
  }

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    postPaths.add(path);
    postBodies.add(data as Map<String, dynamic>);
    if (errorFor != null) {
      final e = errorFor!(path);
      if (e != null) throw e;
    }
    return jsonDecode(jsonEncode(responses[path] ?? <String, dynamic>{}));
  }
}

SearchSong _song({
  String id = 's1',
  String source = 'netease',
  String name = 'Title',
  String artist = '',
  String album = '',
  int duration = 100,
  String cover = '',
  String suffix = '',
  String providerId = '',
}) {
  return SearchSong(
    id: id,
    source: source,
    name: name,
    artist: artist,
    album: album,
    duration: duration,
    cover: cover,
    suffix: suffix,
    providerId: providerId,
  );
}

void main() {
  late FakeApiClient api;
  late SearchRepository repo;

  setUp(() {
    api = FakeApiClient();
    repo = SearchRepository(api);
  });

  group('getProviders', () {
    test('解析 providers 列表与 platformLabels', () async {
      api.responses['/rest/api/v1/song-search/providers'] = {
        'providers': [
          {
            'id': 'gd',
            'name': 'GD Music',
            'platforms': ['netease', 'qq'],
            'platformLabels': {'netease': '网易云'},
          },
        ],
      };
      final list = await repo.getProviders(SearchEntityKind.song);
      expect(list, hasLength(1));
      expect(list.first.id, 'gd');
      expect(list.first.platforms, ['netease', 'qq']);
      expect(list.first.platformLabels['netease'], '网易云');
    });

    test('缺 providers 字段/非 List → 空列表', () async {
      api.responses['/rest/api/v1/album-search/providers'] = {'x': 1};
      expect(await repo.getProviders(SearchEntityKind.album), isEmpty);
    });

    test('请求异常 → 返回空列表不抛', () async {
      api.errorFor = (_) => StateError('boom');
      expect(await repo.getProviders(SearchEntityKind.artist), isEmpty);
    });

    test('各类目路由到各自 providers 端点', () async {
      await repo.getProviders(SearchEntityKind.playlist);
      expect(api.getPaths.single, '/rest/api/v1/playlist-search/providers');
    });
  });

  group('searchRemote', () {
    test('空白 query 直接返回空结果,不发请求', () async {
      final out = await repo.searchRemote(SearchEntityKind.song, '   ');
      expect(out.isEmpty, isTrue);
      expect(api.postPaths, isEmpty);
    });

    test('song 类目:聚合路径,providerId 回退条目自带值', () async {
      api.responses['/rest/api/v1/song-search/aggregate/search'] = {
        'items': [
          {'id': '1', 'source': 'netease', 'name': 'A', 'providerId': 'gd'},
        ],
      };
      final out = await repo.searchRemote(SearchEntityKind.song, 'a');
      expect(api.postPaths.single,
          '/rest/api/v1/song-search/aggregate/search');
      expect(out.songs, hasLength(1));
      expect(out.songs.first.providerId, 'gd');
      expect(out.songs.first.duration, 0);
    });

    test('album 类目:单插件路径,providerId 用请求参数覆盖', () async {
      api.responses['/rest/api/v1/album-search/gd/search'] = {
        'items': [
          {
            'id': 'al1',
            'source': 'qq',
            'name': 'Album',
            'trackCount': 10,
            'year': 2020,
            'providerId': 'should-be-overridden',
          },
        ],
      };
      final out = await repo.searchRemote(SearchEntityKind.album, 'al',
          providerId: 'gd');
      expect(api.postPaths.single, '/rest/api/v1/album-search/gd/search');
      expect(api.postBodies.single, {'q': 'al'});
      expect(out.albums.single.providerId, 'gd');
      expect(out.albums.single.trackCount, '10');
      expect(out.albums.single.year, '2020');
    });

    test('artist 类目:avatar 缺失回退 cover', () async {
      api.responses['/rest/api/v1/artist-search/gd/search'] = {
        'items': [
          {'id': 'ar1', 'source': 'qq', 'name': 'Artist', 'cover': 'c.png'},
        ],
      };
      final out = await repo.searchRemote(SearchEntityKind.artist, 'ar',
          providerId: 'gd');
      expect(out.artists.single.avatar, 'c.png');
      expect(out.artists.single.platformLabel, 'qq');
    });

    test('playlist 类目:优先 playlists,缺失回退 items', () async {
      api.responses['/rest/api/v1/playlist-search/aggregate/search'] = {
        'playlists': [
          {'id': 'p1', 'source': 'netease', 'name': 'PL', 'imported': true},
        ],
      };
      final out = await repo.searchRemote(SearchEntityKind.playlist, 'pl');
      expect(out.playlists.single.id, 'p1');
      expect(out.playlists.single.imported, isTrue);

      api.responses['/rest/api/v1/playlist-search/aggregate/search'] = {
        'items': [
          {'id': 'p2', 'source': 'netease', 'name': 'PL2'},
        ],
      };
      final out2 = await repo.searchRemote(SearchEntityKind.playlist, 'pl');
      expect(out2.playlists.single.id, 'p2');
    });

    test('items/playlists 缺失 → 空结果', () async {
      api.responses['/rest/api/v1/artist-search/aggregate/search'] = {};
      final out = await repo.searchRemote(SearchEntityKind.artist, 'x');
      expect(out.artists, isEmpty);
    });

    test('请求异常 → 原样 rethrow', () async {
      api.errorFor = (_) => StateError('net down');
      await expectLater(
        repo.searchRemote(SearchEntityKind.song, 'x'),
        throwsStateError,
      );
    });
  });

  group('getCollectionSongs', () {
    test('artist 类目 name 为空 → 空列表,不发请求', () async {
      final got = await repo.getCollectionSongs(
        SearchEntityKind.artist,
        'gd',
        SearchSongLike(name: ''),
      );
      expect(got, isEmpty);
      expect(api.getPaths, isEmpty);
    });

    test('song/album 类目 source 或 id 为空 → 空列表', () async {
      expect(
        await repo.getCollectionSongs(SearchEntityKind.album, 'gd',
            SearchSongLike(id: 'x', source: '')),
        isEmpty,
      );
      expect(
        await repo.getCollectionSongs(SearchEntityKind.album, 'gd',
            SearchSongLike(id: '', source: 'qq')),
        isEmpty,
      );
    });

    test('album 取歌成功 → 转 Song 带 remote: 前缀与预览字段', () async {
      api.responses['/rest/api/v1/album-search/gd/items'] = {
        'items': [
          {
            'id': 't1',
            'source': 'qq',
            'name': 'Track',
            'artist': 'Singer',
            'duration': 180,
          },
        ],
      };
      final songs = await repo.getCollectionSongs(
        SearchEntityKind.album,
        'gd',
        SearchSongLike(id: 'al1', source: 'qq'),
      );
      expect(api.getQueries.single, {'source': 'qq', 'id': 'al1'});
      final s = songs.single;
      expect(s.id, 'remote:gd:qq:t1');
      expect(s.title, 'Track');
      expect(s.artist, 'Singer');
      expect(s.suffix, 'mp3'); // 空后缀回退 mp3
      expect(s.isPreview, isTrue);
      expect(s.previewTrackId, 't1');
      expect(s.previewSource, 'qq');
      expect(s.previewStreamUrl, ''); // fake 未设置 library → stream url 为空,仅验证不抛
    });

    test('artist 取歌用 name 查询', () async {
      api.responses['/rest/api/v1/artist-search/gd/items'] = {'items': []};
      final songs = await repo.getCollectionSongs(
        SearchEntityKind.artist,
        'gd',
        SearchSongLike(name: '周杰伦'),
      );
      expect(songs, isEmpty);
      expect(api.getQueries.single, {'name': '周杰伦'});
    });
  });

  group('getPlaylistSongs / buildRemoteSong', () {
    test('远程歌单曲目拉取', () async {
      api.responses['/rest/api/v1/playlist-search/gd/items'] = {
        'items': [
          {'id': 's9', 'source': 'netease', 'name': 'N'},
        ],
      };
      final songs = await repo.getPlaylistSongs(
        'gd',
        SearchPlaylist(id: 'pl1', source: 'netease', name: 'PL'),
      );
      expect(api.getQueries.single, {'source': 'netease', 'id': 'pl1'});
      expect(songs.single.id, 'remote:gd:netease:s9');
    });

    test('buildRemoteSong:空 artist/album/cover 置 null', () {
      final s = repo.buildRemoteSong(_song(name: 'T', artist: ''));
      expect(s.artist, isNull);
      expect(s.album, isNull);
      expect(s.coverArt, isNull);
      expect(s.previewCoverUrl, isNull);
      expect(s.title, 'T');
    });

    test('buildRemoteSong:字段齐全时透传', () {
      final s = repo.buildRemoteSong(_song(
        id: 's2',
        source: 'qq',
        providerId: 'gd',
        name: 'T2',
        artist: 'A',
        album: 'AL',
        duration: 60,
        cover: 'cov',
        suffix: 'flac',
      ));
      expect(s.id, 'remote:gd:qq:s2');
      expect(s.artist, 'A');
      expect(s.album, 'AL');
      expect(s.duration, 60);
      expect(s.coverArt, 'cov');
      expect(s.suffix, 'flac');
      expect(s.previewCoverUrl, 'cov');
      expect(s.isPreview, isTrue);
    });
  });

  group('导入', () {
    test('importSong 成功返回 taskId,payload 含全部字段', () async {
      api.responses['/rest/api/v1/song-search/gd/import'] = {
        'success': true,
        'taskId': 't-1',
      };
      final taskId = await repo.importSong('gd', [
        _song(id: 's1', source: 'qq', name: 'N', artist: 'A', album: 'AL',
            duration: 10, cover: 'c', suffix: 'mp3'),
      ]);
      expect(taskId, 't-1');
      expect(api.postBodies.single['songs'], hasLength(1));
      final payload = (api.postBodies.single['songs'] as List).first
          as Map<String, dynamic>;
      expect(payload['id'], 's1');
      expect(payload['suffix'], 'mp3');
      expect(payload['duration'], 10);
    });

    test('importSong success!=true → 抛 error 文案', () async {
      api.responses['/rest/api/v1/song-search/gd/import'] = {
        'success': false,
        'error': 'provider offline',
      };
      await expectLater(
        repo.importSong('gd', [_song()]),
        throwsA(predicate((e) => e.toString().contains('provider offline'))),
      );
    });

    test('importAlbum alreadyRunning → 抛任务运行中', () async {
      api.responses['/rest/api/v1/album-search/gd/import'] = {
        'success': true,
        'alreadyRunning': true,
        'taskId': 'x',
      };
      await expectLater(
        repo.importAlbum(
          'gd',
          SearchAlbum(id: 'al1', source: 'qq', name: 'AL'),
        ),
        throwsException,
      );
      final body = api.postBodies.single;
      expect(body['source'], 'qq');
      expect(body['id'], 'al1');
    });

    test('importSong taskId 缺失 → 抛异常', () async {
      api.responses['/rest/api/v1/song-search/gd/import'] = {
        'success': true,
      };
      await expectLater(repo.importSong('gd', [_song()]), throwsException);
    });

    test('startPlaylistImport alreadyRunning → 复用既有 taskId', () async {
      api.responses['/rest/api/v1/playlist-search/gd/import'] = {
        'alreadyRunning': true,
        'taskId': 'running-1',
      };
      final taskId = await repo.startPlaylistImport(
        'gd',
        SearchPlaylist(id: 'pl1', source: 'netease', name: 'PL'),
      );
      expect(taskId, 'running-1');
    });

    test('startPlaylistImport 失败 → 抛 error 文案', () async {
      api.responses['/rest/api/v1/playlist-search/gd/import'] = {
        'success': false,
        'error': 'bad playlist',
      };
      await expectLater(
        repo.startPlaylistImport(
          'gd',
          SearchPlaylist(id: 'pl1', source: 'netease', name: 'PL'),
        ),
        throwsA(predicate((e) => e.toString().contains('bad playlist'))),
      );
    });
  });

  group('waitTask', () {
    test('嵌套 task.status=ok 且 result 为 Map → 返回 result', () async {
      api.responses['/rest/api/v1/tasks/tk'] = {
        'success': true,
        'task': {
          'status': 'ok',
          'result': {'playlistId': 'pl-9'},
        },
      };
      final r = await repo.waitTask('tk');
      expect(r, {'playlistId': 'pl-9'});
    });

    test('历史顶层直出结构(无 task 字段)兼容', () async {
      api.responses['/rest/api/v1/tasks/tk2'] = {
        'status': 'ok',
        'result': {'ok': 1},
      };
      final r = await repo.waitTask('tk2');
      expect(r['ok'], 1);
    });

    test('result 非 Map → 返回空 Map', () async {
      api.responses['/rest/api/v1/tasks/tk3'] = {
        'task': {'status': 'ok', 'result': 'plain-string'},
      };
      expect(await repo.waitTask('tk3'), isEmpty);
    });

    test('status=error → 抛 task.error', () async {
      api.responses['/rest/api/v1/tasks/tk4'] = {
        'task': {'status': 'error', 'error': 'source dead'},
      };
      await expectLater(
        repo.waitTask('tk4'),
        throwsA(predicate((e) => e.toString().contains('source dead'))),
      );
    });

    test('pending → ok 轮询推进', () async {
      var calls = 0;
      api.responses['/rest/api/v1/tasks/tk5'] = {};
      api.beforeGet = () {
        calls++;
        if (calls >= 3) {
          api.responses['/rest/api/v1/tasks/tk5'] = {
            'task': {'status': 'ok', 'result': {'done': true}},
          };
        }
      };
      final r = await repo.waitTask(
        'tk5',
        maxAttempts: 10,
        interval: Duration(milliseconds: 1),
      );
      expect(r['done'], isTrue);
      expect(calls, 3);
    });

    test('超预算(maxAttempts 耗尽) → 抛超时异常', () async {
      api.responses['/rest/api/v1/tasks/tk6'] = {
        'task': {'status': 'running'},
      };
      await expectLater(
        repo.waitTask('tk6', maxAttempts: 2, interval: Duration(milliseconds: 1)),
        throwsException,
      );
    });
  });
}
