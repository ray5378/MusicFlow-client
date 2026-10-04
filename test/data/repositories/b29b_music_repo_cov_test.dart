import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// batch29-B：`lib/data/repositories/music_repository.dart`
/// 补测（覆盖率 98/220 = 44.55%）。
///
/// 打法：本次重点补**窗口化分页三件套**（getAllSongs / getAllAlbums /
/// getAllArtists 的 do-while 翻页循环）与三个单页RangeFetcher——既有测试只
/// 覆盖了单次 get 的解析路径，翻页循环整块没进过。API 侧用 [\_SpyApiClient]
/// 替身：按 path 分队列脚本化返回，同时记录每次调用的 path 与 query 用于断言。
class _SpyCall {
  _SpyCall(this.path, this.query);

  final String path;
  final Map<String, dynamic>? query;
}

class _SpyApiClient extends SubsonicApiClient {
  _SpyApiClient() : super(dio: Dio(BaseOptions(baseUrl: 'http://localhost')));

  final List<_SpyCall> calls = <_SpyCall>[];

  /// path → 按调用顺序消费的响应队列。
  final Map<String, List<dynamic>> scripted = <String, List<dynamic>>{};

  /// 设置后所有请求统一抛错（用于验证仓储层的 rethrow / 吞异常策略）。
  Exception? failure;

  dynamic _take(String path) {
    final queue = scripted[path];
    if (queue == null || queue.isEmpty) return const <String, dynamic>{};
    return queue.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    calls.add(_SpyCall(path, queryParameters));
    final failure = this.failure;
    if (failure != null) throw failure;
    return _take(path) as Map<String, dynamic>;
  }

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    calls.add(_SpyCall(path, queryParameters));
    final failure = this.failure;
    if (failure != null) throw failure;
    return _take(path);
  }
}

void main() {
  late _SpyApiClient api;
  late MusicRepository repo;

  setUp(() {
    api = _SpyApiClient();
    repo = MusicRepository(api);
  });

  Map<String, dynamic> _json(String text) =>
      jsonDecode(text) as Map<String, dynamic>;

  // ---------------------------------------------------------------------------
  // getAlbumList
  // ---------------------------------------------------------------------------

  group('getAlbumList', () {
    test('解析 albumList2.album 并透传 size / offset', () async {
      api.scripted['/rest/getAlbumList2'] = <dynamic>[
        _json('{"albumList2":{"album":[{"id":"a1","name":"A1"},'
            '{"id":"a2","name":"A2"}]}}'),
      ];

      final albums = await repo.getAlbumList(
        type: 'random',
        size: 5,
        offset: 10,
      );

      expect(albums.map((a) => a.id).toList(), <String>['a1', 'a2']);
      expect(api.calls.single.path, '/rest/getAlbumList2');
      expect(api.calls.single.query!['type'], 'random');
      expect(api.calls.single.query!['size'], '5');
      expect(api.calls.single.query!['offset'], '10');
    });

    test('albumList2 缺失时返回空列表', () async {
      api.scripted['/rest/getAlbumList2'] = <dynamic>[_json('{}')];

      expect(await repo.getAlbumList(type: 'newest'), isEmpty);
    });

    test('请求抛错时原样向上抛', () async {
      api.failure = Exception('network down');

      expect(
        () => repo.getAlbumList(type: 'newest'),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // getAlbum
  // ---------------------------------------------------------------------------

  group('getAlbum', () {
    test('解析专辑与其曲目列表', () async {
      api.scripted['/rest/getAlbum'] = <dynamic>[
        _json('{"album":{"id":"a1","name":"A1","song":[{"id":"s1","title":"S1"},'
            '{"id":"s2","title":"S2"}]}}'),
      ];

      final detail = await repo.getAlbum('a1');

      expect(detail!.album.id, 'a1');
      expect(detail.songs.map((s) => s.id).toList(), <String>['s1', 's2']);
      expect(api.calls.single.query!['id'], 'a1');
    });

    test('响应里没有 album 字段时返回 null', () async {
      api.scripted['/rest/getAlbum'] = <dynamic>[_json('{}')];

      expect(await repo.getAlbum('a1'), isNull);
    });

    test('album 里没有 song 字段时曲目为空列表（不抛）', () async {
      api.scripted['/rest/getAlbum'] = <dynamic>[
        _json('{"album":{"id":"a1","name":"A1"}}'),
      ];

      final detail = await repo.getAlbum('a1');

      expect(detail!.album.id, 'a1');
      expect(detail.songs, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // getArtists
  // ---------------------------------------------------------------------------

  group('getArtists', () {
    test('按 index → artist 嵌套结构展开，并跳过没有 artist 列表的索引',
        () async {
      api.scripted['/rest/getArtists'] = <dynamic>[
        _json('{"artists":{"index":[{"name":"A","artist":[{"id":"r1","name":"R1"}]},'
            '{"name":"B"},{"name":"C","artist":[{"id":"r2","name":"R2"},'
            '{"id":"r3","name":"R3"}]}]}}'),
      ];

      final artists = await repo.getArtists();

      expect(artists.map((a) => a.id).toList(), <String>['r1', 'r2', 'r3']);
    });

    test('artists.index 缺失时返回空列表', () async {
      api.scripted['/rest/getArtists'] = <dynamic>[_json('{}')];

      expect(await repo.getArtists(), isEmpty);
    });

    test('请求抛错时记录日志后原样向上抛', () async {
      api.failure = Exception('artists boom');

      expect(() => repo.getArtists(), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // getArtist
  // ---------------------------------------------------------------------------

  group('getArtist', () {
    test('聚合多张专辑的歌曲，按 artistId 过滤并按 id 去重', () async {
      api.scripted['/rest/getArtist'] = <dynamic>[
        _json('{"artist":{"id":"r1","name":"R1","album":[{"id":"a1","name":"A1"},{"id":"a2","name":"A2"}]}}'),
      ];
      api.scripted['/rest/getAlbum'] = <dynamic>[
        _json('{"album":{"id":"a1","name":"A1","song":[{"id":"s1","title":"S1","artistId":"r1"},'
            '{"id":"s2","title":"S2","artistId":"other"}]}}'),
        _json('{"album":{"id":"a2","name":"A2","song":[{"id":"s1","title":"S1","artistId":"r1"},'
            '{"id":"s3","title":"S3","artistId":""}]}}'),
      ];

      final detail = await repo.getArtist('r1');

      expect(detail!.albums.map((a) => a.id).toList(), <String>['a1', 'a2']);
      expect(detail.songs.map((s) => s.id).toList(), <String>['s1', 's3']);
    });

    test('artist 没有 album 列表时 albums / songs 都为空且不发额外请求',
        () async {
      api.scripted['/rest/getArtist'] = <dynamic>[
        _json('{"artist":{"id":"r1","name":"R1"}}'),
      ];

      final detail = await repo.getArtist('r1');

      expect(detail!.albums, isEmpty);
      expect(detail.songs, isEmpty);
      expect(api.calls.single.path, '/rest/getArtist');
    });

    test('请求抛错时记录日志后原样向上抛', () async {
      api.failure = Exception('artist boom');

      expect(() => repo.getArtist('r1'), throwsA(isA<Exception>()));
    });

    test('响应里没有 artist 字段时返回 null', () async {
      api.scripted['/rest/getArtist'] = <dynamic>[_json('{}')];

      expect(await repo.getArtist('r1'), isNull);
    });

    test('单张专辑拉取失败时跳过该专辑，不影响其余专辑', () async {
      api.scripted['/rest/getArtist'] = <dynamic>[
        _json('{"artist":{"id":"r1","name":"R1","album":[{"id":"a1","name":"A1"},{"id":"a2","name":"A2"}]}}'),
      ];
      api.scripted['/rest/getAlbum'] = <dynamic>[
        _json('{"album":{"id":"a1","name":"A1","song":[{"id":"s1","title":"S1"}]}}'),
        Exception('album boom'),
      ];

      final detail = await repo.getArtist('r1');

      expect(detail!.songs.map((s) => s.id).toList(), <String>['s1']);
      expect(api.calls.where((c) => c.path == '/rest/getAlbum'), hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // getTopSongs / getRandomSongs
  // ---------------------------------------------------------------------------

  group('getTopSongs', () {
    test('解析 topSongs.song 并透传 count', () async {
      api.scripted['/rest/getTopSongs'] = <dynamic>[
        _json('{"topSongs":{"song":[{"id":"t1","title":"T1"}]}}'),
      ];

      final songs = await repo.getTopSongs('R1', count: 3);

      expect(songs.single.id, 't1');
      expect(api.calls.single.query!['artist'], 'R1');
      expect(api.calls.single.query!['count'], '3');
    });

    test('topSongs 缺失时返回空列表', () async {
      api.scripted['/rest/getTopSongs'] = <dynamic>[_json('{}')];

      expect(await repo.getTopSongs('R1'), isEmpty);
    });

    test('请求抛错时记录日志后原样向上抛', () async {
      api.failure = Exception('top songs boom');

      expect(() => repo.getTopSongs('R1'), throwsA(isA<Exception>()));
    });
  });

  group('getRandomSongs', () {
    test('透传 size / genre / fromYear / toYear 并解析 randomSongs', () async {
      api.scripted['/rest/getRandomSongs'] = <dynamic>[
        _json('{"randomSongs":{"song":[{"id":"g1"},{"id":"g2"}]}}'),
      ];

      final songs = await repo.getRandomSongs(
        size: 2,
        genre: 'rock',
        fromYear: 1990,
        toYear: 2000,
      );

      expect(songs.map((s) => s.id).toList(), <String>['g1', 'g2']);
      expect(api.calls.single.query!['size'], '2');
      expect(api.calls.single.query!['genre'], 'rock');
      expect(api.calls.single.query!['fromYear'], '1990');
      expect(api.calls.single.query!['toYear'], '2000');
    });

    test('randomSongs 缺失时返回空列表', () async {
      api.scripted['/rest/getRandomSongs'] = <dynamic>[_json('{}')];

      expect(await repo.getRandomSongs(size: 1), isEmpty);
    });

    test('请求抛错时记录日志后原样向上抛', () async {
      api.failure = Exception('random songs boom');

      expect(() => repo.getRandomSongs(size: 1), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // getAllSongs（分页）
  // ---------------------------------------------------------------------------

  group('getAllSongs', () {
    test('首页返回空页即停止，不再翻页', () async {
      api.scripted['/rest/api/v1/songs'] = <dynamic>[
        _json('{"items":[],"total":0}'),
      ];

      final songs = await repo.getAllSongs();

      expect(songs, isEmpty);
      expect(
        api.calls.where((c) => c.path == '/rest/api/v1/songs'),
        hasLength(1),
      );
    });

    test('多页分页拉取并累加，query 透传到每一页', () async {
      api.scripted['/rest/api/v1/songs'] = <dynamic>[
        _json('{"items":[{"id":"p1-1"},{"id":"p1-2"}],"total":4}'),
        _json('{"items":[{"id":"p2-1"}],"total":4}'),
        _json('{"items":[],"total":4}'),
      ];

      final songs = await repo.getAllSongs(query: 'ab');

      expect(songs.map((s) => s.id).toList(), <String>[
        'p1-1',
        'p1-2',
        'p2-1',
      ]);
      expect(
        api.calls
            .where((c) => c.path == '/rest/api/v1/songs')
            .map((c) => c.query!['page'])
            .toList(),
        <String>['1', '2', '3'],
      );
      expect(api.calls.first.query!['pageSize'], '200');
      expect(api.calls.first.query!['query'], 'ab');
    });

    test('已取满 total 时立即停翻页', () async {
      api.scripted['/rest/api/v1/songs'] = <dynamic>[
        _json('{"items":[{"id":"z1"}],"total":1}'),
      ];

      final songs = await repo.getAllSongs();

      expect(songs.single.id, 'z1');
      expect(
        api.calls.where((c) => c.path == '/rest/api/v1/songs'),
        hasLength(1),
      );
    });

    test('分页请求抛错时原样向上抛', () async {
      api.failure = Exception('songs boom');

      expect(() => repo.getAllSongs(), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // getAllAlbums（分页）
  // ---------------------------------------------------------------------------

  group('getAllAlbums', () {
    test('多页分页拉取并累加', () async {
      api.scripted['/rest/api/v1/albums'] = <dynamic>[
        _json('{"items":[{"id":"al1","name":"AL1"}],"total":2}'),
        _json('{"items":[{"id":"al2","name":"AL2"}],"total":2}'),
      ];

      final albums = await repo.getAllAlbums();

      expect(albums.map((a) => a.id).toList(), <String>['al1', 'al2']);
      expect(
        api.calls
            .where((c) => c.path == '/rest/api/v1/albums')
            .map((c) => c.query!['page'])
            .toList(),
        <String>['1', '2'],
      );
    });

    test('分页请求抛错时原样向上抛', () async {
      api.failure = Exception('albums boom');

      expect(() => repo.getAllAlbums(), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // getAllArtists（分页）
  // ---------------------------------------------------------------------------

  group('getAllArtists', () {
    test('多页分页拉取并累加', () async {
      api.scripted['/rest/api/v1/artists'] = <dynamic>[
        _json('{"items":[{"id":"ar1","name":"AR1"}],"total":3}'),
        _json('{"items":[{"id":"ar2","name":"AR2"}],"total":3}'),
        _json('{"items":[{"id":"ar3","name":"AR3"}],"total":3}'),
      ];

      final artists = await repo.getAllArtists();

      expect(artists.map((a) => a.id).toList(), <String>['ar1', 'ar2', 'ar3']);
    });

    test('分页请求抛错时原样向上抛', () async {
      api.failure = Exception('artists boom');

      expect(() => repo.getAllArtists(), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // 单页 RangeFetcher
  // ---------------------------------------------------------------------------

  group('单页分页', () {
    test('getSongsPage 返回本页 items 与 total，并透传 query / sort', () async {
      api.scripted['/rest/api/v1/songs'] = <dynamic>[
        _json('{"items":[{"id":"pg1"}],"total":77}'),
      ];

      final page = await repo.getSongsPage(3, 50, query: 'q', sort: 'recentAdded');

      expect(page.items.single.id, 'pg1');
      expect(page.total, 77);
      expect(api.calls.single.query!['page'], '3');
      expect(api.calls.single.query!['pageSize'], '50');
      expect(api.calls.single.query!['query'], 'q');
      expect(api.calls.single.query!['sort'], 'recentAdded');
    });

    test('getAlbumsPage 返回本页 items 与 total', () async {
      api.scripted['/rest/api/v1/albums'] = <dynamic>[
        _json('{"items":[{"id":"ap1","name":"AP1"}],"total":8}'),
      ];

      final page = await repo.getAlbumsPage(2, 25);

      expect(page.items.single.id, 'ap1');
      expect(page.total, 8);
      expect(api.calls.single.query!['page'], '2');
      expect(api.calls.single.query!['pageSize'], '25');
    });

    test('getArtistsPage 返回本页 items 与 total', () async {
      api.scripted['/rest/api/v1/artists'] = <dynamic>[
        _json('{"items":[{"id":"rp1","name":"RP1"}],"total":9}'),
      ];

      final page = await repo.getArtistsPage(1, 10);

      expect(page.items.single.id, 'rp1');
      expect(page.total, 9);
    });
  });

  // ---------------------------------------------------------------------------
  // search
  // ---------------------------------------------------------------------------

  group('search', () {
    test('解析 searchResult3 的三类结果', () async {
      api.scripted['/rest/search3'] = <dynamic>[
        _json('{"searchResult3":{"artist":[{"id":"sr1","name":"SR1"}],"album":[{"id":"sa1","name":"SA1"}],'
            '"song":[{"id":"ss1"}]}}'),
      ];

      final result = await repo.search(
        query: 'x',
        artistCount: 1,
        albumCount: 3,
        songCount: 2,
      );

      expect(result.artists.single.id, 'sr1');
      expect(result.albums.single.id, 'sa1');
      expect(result.songs.single.id, 'ss1');
      expect(result.isEmpty, isFalse);
      expect(api.calls.single.query!['query'], 'x');
      expect(api.calls.single.query!['artistCount'], '1');
      expect(api.calls.single.query!['albumCount'], '3');
      expect(api.calls.single.query!['songCount'], '2');
    });

    test('缺少 searchResult3 时返回空结果', () async {
      api.scripted['/rest/search3'] = <dynamic>[_json('{}')];

      final result = await repo.search(query: 'x');

      expect(result.artists, isEmpty);
      expect(result.albums, isEmpty);
      expect(result.songs, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('只返回部分类别时其余为空列表', () async {
      api.scripted['/rest/search3'] = <dynamic>[
        _json('{"searchResult3":{"song":[{"id":"only"}]}}'),
      ];

      final result = await repo.search(query: 'x');

      expect(result.artists, isEmpty);
      expect(result.albums, isEmpty);
      expect(result.songs.single.id, 'only');
    });

    test('search3 只有 artist 时 songs 为空列表', () async {
      api.scripted['/rest/search3'] = <dynamic>[
        _json('{"searchResult3":{"artist":[{"id":"sr1","name":"SR1"}]}}'),
      ];

      final result = await repo.search(query: 'x');

      expect(result.artists.single.id, 'sr1');
      expect(result.albums, isEmpty);
      expect(result.songs, isEmpty);
    });

    test('请求抛错时记录日志后原样向上抛', () async {
      api.failure = Exception('search boom');

      expect(() => repo.search(query: 'x'), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // star / unstar
  // ---------------------------------------------------------------------------

  group('star', () {
    test('setSongStarred 收藏与取消分别走 star / unstar 且带 id', () async {
      await repo.setSongStarred('s1', true);
      await repo.setSongStarred('s1', false);

      expect(api.calls.map((c) => c.path).toList(), <String>[
        '/rest/star',
        '/rest/unstar',
      ]);
      expect(api.calls.first.query!['id'], 's1');
      expect(api.calls.last.query!['id'], 's1');
    });

    test('setSongStarred 失败时向上抛', () async {
      api.failure = Exception('star boom');

      expect(() => repo.setSongStarred('s1', true), throwsA(isA<Exception>()));
    });

    test('setAlbumStarred 收藏与取消分别走 star / unstar 且带 albumId',
        () async {
      await repo.setAlbumStarred('a1', true);
      await repo.setAlbumStarred('a1', false);

      expect(api.calls.map((c) => c.path).toList(), <String>[
        '/rest/star',
        '/rest/unstar',
      ]);
      expect(api.calls.first.query!['albumId'], 'a1');
    });

    test('setAlbumStarred 失败时向上抛', () async {
      api.failure = Exception('album star boom');

      expect(
        () => repo.setAlbumStarred('a1', true),
        throwsA(isA<Exception>()),
      );
    });

    test('setArtistStarred 收藏与取消分别走 star / unstar 且带 artistId',
        () async {
      await repo.setArtistStarred('r1', true);
      await repo.setArtistStarred('r1', false);

      expect(api.calls.map((c) => c.path).toList(), <String>[
        '/rest/star',
        '/rest/unstar',
      ]);
      expect(api.calls.first.query!['artistId'], 'r1');
    });

    test('setArtistStarred 失败时向上抛', () async {
      api.failure = Exception('artist star boom');

      expect(
        () => repo.setArtistStarred('r1', true),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // getStarred
  // ---------------------------------------------------------------------------

  group('getStarred', () {
    test('解析 starred2 的三类结果', () async {
      api.scripted['/rest/getStarred2'] = <dynamic>[
        _json('{"starred2":{"artist":[{"id":"sr1","name":"SR1"}],"album":[{"id":"sa1","name":"SA1"}],'
            '"song":[{"id":"ss1"}]}}'),
      ];

      final result = await repo.getStarred();

      expect(result.artists.single.id, 'sr1');
      expect(result.albums.single.id, 'sa1');
      expect(result.songs.single.id, 'ss1');
      expect(result.isEmpty, isFalse);
    });

    test('缺少 starred2 时返回空结果', () async {
      api.scripted['/rest/getStarred2'] = <dynamic>[_json('{}')];

      final result = await repo.getStarred();

      expect(result.artists, isEmpty);
      expect(result.albums, isEmpty);
      expect(result.songs, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('starred2 缺 artist 列表时 artists 为空', () async {
      api.scripted['/rest/getStarred2'] = <dynamic>[
        _json('{"starred2":{"album":[{"id":"sa1","name":"SA1"}],"song":[{"id":"ss1"}]}}'),
      ];

      final result = await repo.getStarred();

      expect(result.artists, isEmpty);
      expect(result.albums.single.id, 'sa1');
      expect(result.songs.single.id, 'ss1');
    });

    test('starred2 缺 album 列表时 albums 为空', () async {
      api.scripted['/rest/getStarred2'] = <dynamic>[
        _json('{"starred2":{"artist":[{"id":"sr1","name":"SR1"}],"song":[{"id":"ss1"}]}}'),
      ];

      final result = await repo.getStarred();

      expect(result.artists.single.id, 'sr1');
      expect(result.albums, isEmpty);
      expect(result.songs.single.id, 'ss1');
    });

    test('starred2 缺 song 列表时 songs 为空', () async {
      api.scripted['/rest/getStarred2'] = <dynamic>[
        _json('{"starred2":{"artist":[{"id":"sr1","name":"SR1"}],'
            '"album":[{"id":"sa1","name":"SA1"}]}}'),
      ];

      final result = await repo.getStarred();

      expect(result.artists.single.id, 'sr1');
      expect(result.albums.single.id, 'sa1');
      expect(result.songs, isEmpty);
    });

    test('请求抛错时记录日志后原样向上抛', () async {
      api.failure = Exception('starred boom');

      expect(() => repo.getStarred(), throwsA(isA<Exception>()));
    });
  });

  // ---------------------------------------------------------------------------
  // getSong
  // ---------------------------------------------------------------------------

  group('getSong', () {
    test('解析单曲详情', () async {
      api.scripted['/rest/getSong'] = <dynamic>[
        _json('{"song":{"id":"g1","title":" G1 ","artist":" R ","album":" A ","path":"p"}}'),
      ];

      final song = await repo.getSong('g1');

      expect(song!.id, 'g1');
      expect(api.calls.single.query!['id'], 'g1');
    });

    test('响应里没有 song 字段时返回 null', () async {
      api.scripted['/rest/getSong'] = <dynamic>[_json('{}')];

      expect(await repo.getSong('g1'), isNull);
    });

    test('请求失败时返回 null（仓储层刻意吞异常）', () async {
      api.failure = Exception('song boom');

      expect(await repo.getSong('g1'), isNull);
    });
  });
}
