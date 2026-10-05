import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

/// 只覆盖 RecommendRepository 用到的 getRaw / postRaw，避免真实网络。
class _FakeClient extends SubsonicApiClient {
  _FakeClient() : super(dio: Dio());

  final List<String> paths = <String>[];
  dynamic getResult;
  dynamic postResult;
  Object? error;

  void failWith(Object e) => error = e;

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    paths.add(path);
    final current = error;
    if (current != null) throw current;
    return getResult;
  }

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    paths.add(path);
    final current = error;
    if (current != null) throw current;
    return postResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('getHomeSections 解析 unwrapped 响应', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'sections': <Map<String, dynamic>>[
          {'key': 'daily', 'title': '每日推荐', 'sortOrder': 1, 'visible': true},
        ],
      };
    final repo = RecommendRepository(client);

    final sections = await repo.getHomeSections();

    expect(client.paths.single, '/rest/api/v1/home/sections');
    expect(sections.single.key, 'daily');
    expect(sections.single.title, '每日推荐');
    expect(sections.single.sortOrder, 1);
    expect(sections.single.visible, isTrue);
  });

  test('getHomeSections 解析 subsonic-response 包裹的响应', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'subsonic-response': <String, dynamic>{
          'homeSections': <String, dynamic>{
            'sections': <Map<String, dynamic>>[
              {'key': 'roam', 'title': '今日漫游', 'sortOrder': 2},
            ],
          },
        },
      };
    final repo = RecommendRepository(client);

    final sections = await repo.getHomeSections();

    expect(sections.single.key, 'roam');
    expect(sections.single.sortOrder, 2);
    expect(sections.single.visible, isTrue);
  });

  test('getHomeSections 顶层 homeSections 形态也兼容', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'homeSections': <String, dynamic>{
          'sections': <Map<String, dynamic>>[
            {'key': 'local', 'title': '本地推荐', 'sortOrder': 3, 'visible': false},
          ],
        },
      };
    final repo = RecommendRepository(client);

    final sections = await repo.getHomeSections();

    expect(sections.single.key, 'local');
    expect(sections.single.visible, isFalse);
  });

  test('getHomeSections 无 sections 字段返回空列表', () async {
    final client = _FakeClient()..getResult = <String, dynamic>{'foo': 1};
    final repo = RecommendRepository(client);

    expect(await repo.getHomeSections(), isEmpty);
  });

  test('getHomeSections 响应非 Map 时返回空列表', () async {
    final client = _FakeClient()..getResult = <dynamic>['not', 'a', 'map'];
    final repo = RecommendRepository(client);

    expect(await repo.getHomeSections(), isEmpty);
  });

  test('getHomeSections 请求失败向上抛出', () async {
    final client = _FakeClient()..failWith(StateError('offline'));
    final repo = RecommendRepository(client);

    await expectLater(repo.getHomeSections(), throwsA(isA<StateError>()));
  });

  test('getHomeCards 解析推荐卡列表', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'cards': <Map<String, dynamic>>[
          {
            'playlistId': 'pl-1',
            'name': '每日推荐',
            'playlistName': 'daily',
            'position': 0,
            'isCombo': true,
            'songCount': 30,
            'coverArt': 'ca-1',
          },
        ],
      };
    final repo = RecommendRepository(client);

    final cards = await repo.getHomeCards();

    expect(client.paths.single, '/rest/api/v1/recommend/home-cards');
    expect(cards.single.playlistId, 'pl-1');
    expect(cards.single.isCombo, isTrue);
    expect(cards.single.songCount, 30);
    expect(cards.single.coverArt, 'ca-1');
  });

  test('getHomeCards 缺省 cards 返回空列表', () async {
    final client = _FakeClient()..getResult = <String, dynamic>{};
    final repo = RecommendRepository(client);

    expect(await repo.getHomeCards(), isEmpty);
  });

  test('getHomeCards 请求失败向上抛出', () async {
    final client = _FakeClient()..failWith(StateError('offline'));
    final repo = RecommendRepository(client);

    await expectLater(repo.getHomeCards(), throwsA(isA<StateError>()));
  });

  test('getRecommend 解析 providerId 与频道', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'providerId': 'netease',
        'channels': <Map<String, dynamic>>[
          {
            'source': 'netease',
            'name': '网易云',
            'count': 2,
            'playlists': <Map<String, dynamic>>[
              {
                'id': 'r-1',
                'source': 'netease',
                'name': '华语',
                'creator': 'unknown',
                'trackCount': '20',
                'link': 'https://example.test/1',
                'imported': true,
              },
            ],
          },
        ],
      };
    final repo = RecommendRepository(client);

    final result = await repo.getRecommend();

    expect(client.paths.single, '/rest/api/v1/recommend');
    expect(result.providerId, 'netease');
    expect(result.channels.single.name, '网易云');
    expect(result.channels.single.count, 2);
    expect(result.channels.single.playlists.single.imported, isTrue);
  });

  test('getRecommend 缺省字段回落为空', () async {
    final client = _FakeClient()..getResult = <String, dynamic>{};
    final repo = RecommendRepository(client);

    final result = await repo.getRecommend();

    expect(result.providerId, isEmpty);
    expect(result.channels, isEmpty);
  });

  test('getRecommend 请求失败向上抛出', () async {
    final client = _FakeClient()..failWith(StateError('offline'));
    final repo = RecommendRepository(client);

    await expectLater(repo.getRecommend(), throwsA(isA<StateError>()));
  });

  test('findImportedPlaylistId 命中远程 id 时返回本地歌单 id', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'playlists': <Map<String, dynamic>>[
          {'_remoteId': 'remote-1', 'id': 'local-1'},
          {'_remoteId': 'remote-2', 'id': 'local-2'},
        ],
      };
    final repo = RecommendRepository(client);

    final id = await repo.findImportedPlaylistId('netease', 'remote-2');

    expect(
      client.paths.single,
      '/rest/api/v1/online/netease/recommend/local',
    );
    expect(id, 'local-2');
  });

  test('findImportedPlaylistId 未命中返回 null', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'playlists': <Map<String, dynamic>>[
          {'_remoteId': 'remote-1', 'id': 'local-1'},
        ],
      };
    final repo = RecommendRepository(client);

    expect(await repo.findImportedPlaylistId('netease', 'missing'), isNull);
  });

  test('findImportedPlaylistId 请求失败吞掉异常返回 null', () async {
    final client = _FakeClient()..failWith(StateError('offline'));
    final repo = RecommendRepository(client);

    expect(await repo.findImportedPlaylistId('netease', 'remote-1'), isNull);
  });

  test('importRecommendPlaylist 成功返回本地歌单 id', () async {
    final client = _FakeClient()
      ..postResult = <String, dynamic>{
        'success': true,
        'playlistId': 'local-9',
      };
    final repo = RecommendRepository(client);

    final id = await repo.importRecommendPlaylist('netease', <String, dynamic>{
      'id': 'remote-9',
    });

    expect(
      client.paths.single,
      '/rest/api/v1/online/netease/recommend/import',
    );
    expect(id, 'local-9');
  });

  test('importRecommendPlaylist success 为 false 时抛异常', () async {
    final client = _FakeClient()
      ..postResult = <String, dynamic>{
        'success': false,
        'error': 'import failed',
      };
    final repo = RecommendRepository(client);

    await expectLater(
      repo.importRecommendPlaylist('netease', <String, dynamic>{}),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('import failed'),
        ),
      ),
    );
  });

  test('importRecommendPlaylist 请求失败向上抛出', () async {
    final client = _FakeClient()..failWith(StateError('offline'));
    final repo = RecommendRepository(client);

    await expectLater(
      repo.importRecommendPlaylist('netease', <String, dynamic>{}),
      throwsA(isA<StateError>()),
    );
  });

  test('getLocalRecommend 解析本地随机频道', () async {
    final client = _FakeClient()
      ..getResult = <String, dynamic>{
        'channels': <Map<String, dynamic>>[
          {
            'source': 'local',
            'name': '本地',
            'count': 1,
            'subtag': '每日更新',
            'tagline': '随便听听',
            'playlists': <Map<String, dynamic>>[
              {'id': 'lp-1', 'name': '我的歌单', 'songCount': 12.0},
            ],
          },
        ],
      };
    final repo = RecommendRepository(client);

    final channels = await repo.getLocalRecommend();

    expect(client.paths.single, '/rest/api/v1/local-recommend');
    expect(channels.single.source, 'local');
    expect(channels.single.subtag, '每日更新');
    expect(channels.single.tagline, '随便听听');
    expect(channels.single.playlists.single.songCount, 12);
  });

  test('getLocalRecommend 缺省 channels 返回空列表', () async {
    final client = _FakeClient()..getResult = <String, dynamic>{};
    final repo = RecommendRepository(client);

    expect(await repo.getLocalRecommend(), isEmpty);
  });

  test('getLocalRecommend 请求失败向上抛出', () async {
    final client = _FakeClient()..failWith(StateError('offline'));
    final repo = RecommendRepository(client);

    await expectLater(repo.getLocalRecommend(), throwsA(isA<StateError>()));
  });
}
