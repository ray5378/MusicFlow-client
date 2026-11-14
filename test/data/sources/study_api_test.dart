// 学习模块 API 的回归守卫：
//   * 学习内容/文件名的自然排序（1 < 3 < 11，与服务端 localeCompare numeric 同口径）；
//   * 「继续学习」两层结构（单曲 + 学习歌单续播）解析；
//   * 学习歌单文件夹字符串数组解析（历史 bug：走 Map 列表解析会全丢）；
//   * 学习歌单曲目带源文件名与 playlistId（播放时据此写整单续播）；
//   * 进度上报的负数钳制、歌单 id 编码；
//   * 目录递归收集（「整个目录加入歌单」）只收音频、稳定排序、有上限；
//   * 批量入库按路径映射并跳过失败项。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

class _FakeClient extends SubsonicApiClient {
  _FakeClient() : super(dio: Dio());

  final List<String> getPaths = <String>[];
  final List<Map<String, dynamic>?> getQueries = <Map<String, dynamic>?>[];
  final List<String> postPaths = <String>[];
  final List<dynamic> postData = <dynamic>[];
  final List<String> putPaths = <String>[];
  final List<dynamic> putData = <dynamic>[];
  final List<String> deletePaths = <String>[];

  dynamic Function(String path, Map<String, dynamic>? query)? onGet;
  dynamic Function(String path, dynamic data)? onPost;
  dynamic Function(String path, dynamic data)? onPut;
  dynamic Function(String path)? onDelete;

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    getPaths.add(path);
    getQueries.add(queryParameters);
    return onGet?.call(path, queryParameters);
  }

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    postPaths.add(path);
    postData.add(data);
    return onPost?.call(path, data);
  }

  @override
  Future<dynamic> putRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    putPaths.add(path);
    putData.add(data);
    return onPut?.call(path, data);
  }

  @override
  Future<dynamic> deleteRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    deletePaths.add(path);
    return onDelete?.call(path);
  }
}

void main() {
  group('compareStudyNames', () {
    test('数字段按数值排序，而不是字典序', () {
      final names = <String>['第11课.mp3', '第3课.mp3', '第1课.mp3', '第103课.mp3'];
      names.sort(compareStudyNames);
      expect(names, <String>['第1课.mp3', '第3课.mp3', '第11课.mp3', '第103课.mp3']);
    });

    test('大小写不敏感；前缀短者在前；完全相等返回 0', () {
      expect(compareStudyNames('Lesson A', 'lesson a'), 0);
      expect(compareStudyNames('a', 'ab'), lessThan(0));
      expect(compareStudyNames('ab', 'a'), greaterThan(0));
      expect(compareStudyNames('02', '2'), 0);
    });
  });

  group('isStudyAudioFile', () {
    test('音频扩展名（大小写不敏感）为真', () {
      for (final name in <String>['a.mp3', 'B.FLAC', 'c.M4a', 'd.opus', 'e.aiff']) {
        expect(isStudyAudioFile(name), isTrue, reason: name);
      }
    });

    test('无扩展名/非音频/结尾点号为假', () {
      for (final name in <String>['README', 'a.txt', 'a.', '.mp3', '']) {
        expect(isStudyAudioFile(name), isFalse, reason: name);
      }
    });
  });

  group('继续学习', () {
    test('单曲与学习歌单续播条目分别解析，歌单 id/名称去空白', () async {
      final client = _FakeClient()
        ..onGet = (path, query) {
          expect(path, '/rest/api/v1/study/continue');
          expect(query?['limit'], 50);
          return <String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{
                'id': 's1', 'title': '第1课', 'kind': 'study',
                'positionSec': 120, 'progress': 0.2,
              },
            ],
            'playlistItems': <dynamic>[
              <String, dynamic>{
                'id': 's2', 'title': '第2课', 'kind': 'study',
                'positionSec': 30, 'progress': 0.1,
                'playlistId': ' pl-1 ', 'playlistName': ' 课程A ',
              },
            ],
          };
        };
      final api = StudyApi(client);

      final result = await api.fetchContinueAll(limit: 50);

      expect(result.items, hasLength(1));
      expect(result.items.single.song.id, 's1');
      expect(result.items.single.positionSec, 120);
      expect(result.items.single.isPlaylist, isFalse);
      expect(result.playlistItems, hasLength(1));
      expect(result.playlistItems.single.playlistId, 'pl-1');
      expect(result.playlistItems.single.playlistName, '课程A');
      expect(result.playlistItems.single.isPlaylist, isTrue);
      expect(result.isEmpty, isFalse);
    });

    test('非 Map 负载降级为空结果', () async {
      final client = _FakeClient()..onGet = (path, query) => 'bad';
      final result = await StudyApi(client).fetchContinueAll();
      expect(result.isEmpty, isTrue);
    });
  });

  test('学习歌单文件夹解析字符串数组（Map 条目兼容、空名过滤）', () async {
    final client = _FakeClient()
      ..onGet = (path, query) {
        expect(path, '/rest/api/v1/study/playlist-folders');
        return <String, dynamic>{
          'items': <dynamic>[
            ' 新概念一 ',
            <String, dynamic>{'name': ' 课程/高数 '},
            <String, dynamic>{'other': 'x'},
            42,
            '',
          ],
        };
      };

    final folders = await StudyApi(client).fetchPlaylistFolders();

    expect(folders, <String>['新概念一', '课程/高数']);
  });

  test('学习歌单曲目：标题用源文件名，并带 playlistId/playlistName', () async {
    final client = _FakeClient()
      ..onGet = (path, query) {
        expect(path, '/rest/api/v1/study/playlists/pl%201/tracks');
        return <String, dynamic>{
          'name': '课程A',
          'items': <dynamic>[
            <String, dynamic>{
              'id': 's1', 'title': '第1课', 'kind': 'study',
              'fileName': '第01课.mp3',
            },
            <String, dynamic>{
              'id': 's2', 'title': '第2课', 'kind': 'study',
              'fileName': '',
            },
          ],
        };
      };

    final songs = await StudyApi(client).fetchPlaylistTracks('pl 1');

    expect(songs, hasLength(2));
    expect(songs[0].title, '第01课.mp3');
    expect(songs[0].playlistId, 'pl 1');
    expect(songs[0].playlistName, '课程A');
    expect(songs[1].title, '第2课', reason: '空 fileName 时保留原标题');
  });

  test('进度上报：负数归零，歌单 id 编码进 URL', () async {
    final client = _FakeClient();
    final api = StudyApi(client);

    await api.reportProgress(songId: 's1', positionSec: -5, durationSec: -1);
    expect(client.putPaths.last, '/rest/api/v1/study/progress');
    expect(client.putData.last, <String, dynamic>{
      'songId': 's1', 'positionSec': 0, 'durationSec': 0,
    });

    await api.reportPlaylistProgress(
      playlistId: 'pl 1',
      songId: 's1',
      positionSec: 30,
      durationSec: 600,
    );
    expect(client.putPaths.last, '/rest/api/v1/study/playlists/pl%201/progress');
    expect(client.putData.last, <String, dynamic>{
      'songId': 's1', 'positionSec': 30, 'durationSec': 600,
    });
  });

  test('新建学习歌单：409 映射为名称冲突，缺 id 抛错', () async {
    final conflictClient = _FakeClient()
      ..onPost = (path, data) => throw DioException(
            requestOptions: RequestOptions(path: path),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: path),
              statusCode: 409,
            ),
          );
    await expectLater(
      StudyApi(conflictClient).createPlaylist('课程A'),
      throwsA(isA<StudyPlaylistNameConflict>()),
    );

    final emptyClient = _FakeClient()..onPost = (path, data) => <String, dynamic>{};
    await expectLater(
      StudyApi(emptyClient).createPlaylist('课程A'),
      throwsA(isA<StateError>()),
    );
  });

  group('目录递归收集', () {
    test('逐层遍历、只收音频、按自然序排序', () async {
      final client = _FakeClient()
        ..onGet = (path, query) {
          final dir = query?['path'] as String? ?? '';
          if (dir == '') {
            return <String, dynamic>{
              'items': <dynamic>[
                <String, dynamic>{'name': '第2章', 'relPath': '第2章', 'isDir': true},
                <String, dynamic>{'name': '第10课.mp3', 'relPath': '第10课.mp3', 'isDir': false},
                <String, dynamic>{'name': '第2课.mp3', 'relPath': '第2课.mp3', 'isDir': false},
                <String, dynamic>{'name': '备注.txt', 'relPath': '备注.txt', 'isDir': false},
              ],
            };
          }
          expect(dir, '第2章');
          return <String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{'name': '第1课.mp3', 'relPath': '第2章/第1课.mp3', 'isDir': false},
            ],
          };
        };

      final paths = await StudyApi(client).collectAudioPaths(sourceId: 'src1');

      expect(paths, <String>['第2章/第1课.mp3', '第2课.mp3', '第10课.mp3']);
    });

    test('maxFiles 限制收集数量，避免超大目录打满远端', () async {
      final client = _FakeClient()
        ..onGet = (path, query) => <String, dynamic>{
              'items': <dynamic>[
                <String, dynamic>{'name': '第10课.mp3', 'relPath': 'a/第10课.mp3', 'isDir': false},
                <String, dynamic>{'name': '第2课.mp3', 'relPath': 'a/第2课.mp3', 'isDir': false},
                <String, dynamic>{'name': '第3课.mp3', 'relPath': 'a/第3课.mp3', 'isDir': false},
              ],
            };

      final paths = await StudyApi(client)
          .collectAudioPaths(sourceId: 'src1', maxFiles: 2);

      expect(paths, <String>['a/第2课.mp3', 'a/第10课.mp3']);
    });
  });

  test('批量入库：按 path 映射歌曲，跳过非 Map/缺字段项；空列表不发请求', () async {
    final client = _FakeClient()
      ..onPost = (path, data) {
        expect(path, '/rest/api/v1/study/resolve-batch');
        expect(data, <String, dynamic>{
          'sourceId': 'src1', 'paths': <String>['a.mp3', 'b.mp3', 'c.mp3'],
        });
        return <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{'path': 'a.mp3', 'song': <String, dynamic>{'id': 's1', 'title': 'A'}},
            <String, dynamic>{'path': 'b.mp3'},
            <String, dynamic>{'song': <String, dynamic>{'id': 's2'}},
            'bad',
            <String, dynamic>{'path': 'c.mp3', 'song': <String, dynamic>{'id': 's3', 'title': 'C'}},
          ],
        };
      };
    final api = StudyApi(client);

    final entries = await api.resolveBatchEntries(
      sourceId: 'src1',
      paths: <String>['a.mp3', 'b.mp3', 'c.mp3'],
    );
    expect(entries.map((e) => e.path), <String>['a.mp3', 'c.mp3']);
    expect(entries.map((e) => e.song.id), <String>['s1', 's3']);

    final before = client.postPaths.length;
    expect(await api.resolveBatch(sourceId: 'src1', paths: const <String>[]), isEmpty);
    expect(client.postPaths.length, before, reason: '空列表不应发起网络请求');
  });

  test('学习内容搜索：空查询直接返回且不发请求', () async {
    final client = _FakeClient();
    final api = StudyApi(client);

    expect(await api.searchContents('   '), isEmpty);
    expect(client.getPaths, isEmpty);
  });
}
