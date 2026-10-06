// PlaylistRepository 覆盖率补测 —— batch31 (A 路 worker)。
//
// 产品代码零改动。PlaylistRepository 接收注入的 SubsonicApiClient，这里用
// `extends SubsonicApiClient` 的桩路由请求（只覆写用到的方法），避免 mocktail
// 全量 stub。覆盖所有公开方法与两个容错解析静态方法，目标 85%+。

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

class FakeSubsonicApiClient extends SubsonicApiClient {
  FakeSubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'http://localhost')));

  /// 路由表：path -> 响应体（get 返回 subsonic-response 内容，getRaw/postRaw 返回裸 Map）。
  final Map<String, dynamic> responses = {};

  /// 可选：按 path 抛异常（get / getRaw / postRaw 通用）。
  Object? Function(String path)? errorFor;

  /// 可选：按 path 动态返回（优先级高于 responses）。
  dynamic Function(String path)? responder;

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    if (errorFor != null) {
      final e = errorFor!(path);
      if (e != null) throw e;
    }
    if (responder != null) return responder!(path);
    return responses[path] ?? {};
  }

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    if (errorFor != null) {
      final e = errorFor!(path);
      if (e != null) throw e;
    }
    if (responder != null) return responder!(path);
    return responses[path] ?? {};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    if (errorFor != null) {
      final e = errorFor!(path);
      if (e != null) throw e;
    }
    return responses[path] as Map<String, dynamic>? ??
        {'subsonic-response': <String, dynamic>{}};
  }
}

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  late FakeSubsonicApiClient fake;
  late PlaylistRepository repo;

  setUp(() {
    fake = FakeSubsonicApiClient();
    repo = PlaylistRepository(fake);
  });

  final pJson = Playlist(id: 'p1', name: 'foo', songCount: 3, duration: 100).toJson();
  final pJson2 = Playlist(id: 'p2', name: 'bar', songCount: 1, duration: 50).toJson();
  final sJson = Song(id: 's1', title: 't1').toJson();
  final sJson2 = Song(id: 's2', title: 't2').toJson();
  const tracksPath = '/rest/api/v1/playlists/pl1/tracks';

  group('getPlaylistsPage', () {
    test('items + total 命中 items 键', () async {
      fake.responses['/rest/api/v1/playlists'] = {
        'items': [pJson, pJson2],
        'total': 42,
      };
      final res = await repo.getPlaylistsPage(1, 20);
      expect(res.items.length, 2);
      expect(res.total, 42);
    });

    test('回退到 playlists 键', () async {
      fake.responses['/rest/api/v1/playlists'] = {
        'playlists': [pJson],
        'total': 5,
      };
      final res = await repo.getPlaylistsPage(2, 10, query: 'x', favoriteOnly: true);
      expect(res.items.length, 1);
      expect(res.total, 5);
    });

    test('空列表与 total 缺省', () async {
      fake.responses['/rest/api/v1/playlists'] = {'items': []};
      final res = await repo.getPlaylistsPage(1, 20);
      expect(res.items, isEmpty);
      expect(res.total, 0);
    });
  });

  group('setPlaylistFavorite', () {
    test('success=true', () async {
      fake.responses['/rest/api/v1/playlists/p1/favorite'] = {'success': true};
      expect(await repo.setPlaylistFavorite('p1', true), isTrue);
    });

    test('success=false', () async {
      fake.responses['/rest/api/v1/playlists/p1/favorite'] = {'success': false};
      expect(await repo.setPlaylistFavorite('p1', false), isFalse);
    });
  });

  group('getPlaylistTracksPage', () {
    test('entries 键', () async {
      fake.responses[tracksPath] = {
        'entries': [sJson, sJson2],
        'total': 2,
      };
      final res = await repo.getPlaylistTracksPage('pl1', 1, 50);
      expect(res.items.length, 2);
      expect(res.total, 2);
    });

    test('items 键 + matched 兜底 total', () async {
      fake.responses[tracksPath] = {
        'items': [sJson],
        'matched': 7,
      };
      final res = await repo.getPlaylistTracksPage('pl1', 1, 50);
      expect(res.items.length, 1);
      expect(res.total, 7);
    });

    test('空与 list 长度兜底', () async {
      fake.responses[tracksPath] = {'items': [sJson, sJson2]};
      final res = await repo.getPlaylistTracksPage('pl1', 1, 50);
      expect(res.items.length, 2);
      expect(res.total, 2);
    });
  });

  group('getPlaylistMeta', () {
    test('命中 playlist 元数据', () async {
      fake.responses[tracksPath] = {
        'playlist': {'id': 'pl1', 'name': 'meta', 'songCount': 0, 'duration': 0},
        'total': 1,
      };
      final meta = await repo.getPlaylistMeta('pl1');
      expect(meta, isNotNull);
      expect(meta!.id, 'pl1');
    });

    test('无 playlist 返回 null', () async {
      fake.responses[tracksPath] = {'total': 0};
      final meta = await repo.getPlaylistMeta('pl1');
      expect(meta, isNull);
    });
  });

  group('getAllPlaylistSongs', () {
    test('单页即结束（songs.length >= total 分支）', () async {
      fake.responses[tracksPath] = {
        'items': [sJson, sJson2],
        'total': 2,
      };
      final songs = await repo.getAllPlaylistSongs('pl1');
      expect(songs.length, 2);
    });

    test('多页循环至空 items（items.isEmpty 分支）', () async {
      var calls = 0;
      fake.responder = (path) {
        calls++;
        if (calls == 1) return {'items': [sJson, sJson2], 'total': 400};
        return {'items': [], 'total': 400};
      };
      final songs = await repo.getAllPlaylistSongs('pl1');
      expect(songs.length, 2);
      expect(calls, 2);
    });
  });

  group('triggerPlaylistAutoMatch', () {
    test('started=true', () async {
      fake.responses['/rest/api/v1/playlist/pl1/auto-match'] = {'started': true};
      expect(await repo.triggerPlaylistAutoMatch('pl1'), isTrue);
    });

    test('success=true 兜底', () async {
      fake.responses['/rest/api/v1/playlist/pl1/auto-match'] = {'success': true};
      expect(await repo.triggerPlaylistAutoMatch('pl1'), isTrue);
    });

    test('抛异常返回 false', () async {
      fake.errorFor = (p) =>
          p == '/rest/api/v1/playlist/pl1/auto-match' ? Exception('boom') : null;
      expect(await repo.triggerPlaylistAutoMatch('pl1'), isFalse);
    });
  });

  group('getPlaylists', () {
    test('正常返回列表', () async {
      fake.responses[ApiConstants.getPlaylists] = {
        'playlists': {'playlist': [pJson, pJson2]},
      };
      final list = await repo.getPlaylists();
      expect(list.length, 2);
    });

    test('playlists 为 null 返回空', () async {
      fake.responses[ApiConstants.getPlaylists] = {'playlists': null};
      final list = await repo.getPlaylists();
      expect(list, isEmpty);
    });

    test('抛异常上抛', () async {
      fake.errorFor =
          (p) => p == ApiConstants.getPlaylists ? Exception('net') : null;
      expect(() => repo.getPlaylists(), throwsA(isA<Exception>()));
    });
  });

  group('_parsePlaylists 容错', () {
    test('跳过坏条目（fromJson 抛）', () async {
      fake.responses[ApiConstants.getPlaylists] = {
        'playlists': {
          'playlist': [
            pJson,
            {'id': 123, 'name': 'bad', 'songCount': 1, 'duration': 1},
          ],
        },
      };
      final list = await repo.getPlaylists();
      expect(list.length, 1); // 坏条目被跳过
    });
  });

  group('_parseSongs 容错', () {
    test('平铺 / 嵌套 / 空 / 非 Map 混合', () async {
      fake.responses[tracksPath] = {
        'items': [
          sJson,
          {'song': sJson2},
          {},
          'not-a-map',
        ],
        'total': 4,
      };
      final res = await repo.getPlaylistTracksPage('pl1', 1, 50);
      // 平铺 + 嵌套有效；空/非 Map 被跳过
      expect(res.items.length, 2);
    });
  });

  group('getPlaylist', () {
    test('正常返回', () async {
      fake.responses[ApiConstants.getPlaylist] = {
        'playlist': {'id': 'p1', 'name': 'foo', 'songCount': 1, 'duration': 1},
      };
      final p = await repo.getPlaylist('p1');
      expect(p, isNotNull);
      expect(p!.id, 'p1');
    });

    test('playlist 为 null 返回 null', () async {
      fake.responses[ApiConstants.getPlaylist] = {'playlist': null};
      expect(await repo.getPlaylist('p1'), isNull);
    });

    test('抛异常上抛', () async {
      fake.errorFor =
          (p) => p == ApiConstants.getPlaylist ? Exception('x') : null;
      expect(() => repo.getPlaylist('p1'), throwsA(isA<Exception>()));
    });
  });

  group('createPlaylist', () {
    test('含 songIds 创建成功', () async {
      fake.responses[ApiConstants.createPlaylist] = {
        'playlist': {'id': 'new', 'name': 'n', 'songCount': 0, 'duration': 0},
      };
      final p = await repo.createPlaylist(name: 'n', songIds: ['s1', 's2']);
      expect(p, isNotNull);
      expect(p!.id, 'new');
    });

    test('playlist 为 null 返回 null', () async {
      fake.responses[ApiConstants.createPlaylist] = {'playlist': null};
      expect(await repo.createPlaylist(name: 'n'), isNull);
    });

    test('抛异常上抛', () async {
      fake.errorFor =
          (p) => p == ApiConstants.createPlaylist ? Exception('x') : null;
      expect(
        () => repo.createPlaylist(name: 'n'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('updatePlaylist', () {
    test('全参数更新不抛', () async {
      await repo.updatePlaylist(
        playlistId: 'p1',
        name: 'renamed',
        comment: 'c',
        public: true,
        songIdsToAdd: ['s9'],
        songIndexesToRemove: [1, 2],
      );
      // 无异常即通过
    });

    test('仅 playlistId 更新不抛', () async {
      await repo.updatePlaylist(playlistId: 'p1');
    });

    test('抛异常上抛', () async {
      fake.errorFor =
          (p) => p == ApiConstants.updatePlaylist ? Exception('x') : null;
      expect(
        () => repo.updatePlaylist(playlistId: 'p1'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('deletePlaylist', () {
    test('正常删除不抛', () async {
      await repo.deletePlaylist('p1');
    });

    test('抛异常上抛', () async {
      fake.errorFor =
          (p) => p == ApiConstants.deletePlaylist ? Exception('x') : null;
      expect(() => repo.deletePlaylist('p1'), throwsA(isA<Exception>()));
    });
  });
}
