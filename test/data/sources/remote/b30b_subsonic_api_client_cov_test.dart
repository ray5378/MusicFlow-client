import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/core/dlna/cast_http.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

Dio _baseDio({String base = 'http://srv.test'}) =>
    Dio(BaseOptions(baseUrl: base));

Interceptor _fake({
  required dynamic Function(RequestOptions) responder,
  required List<RequestOptions> captured,
}) => InterceptorsWrapper(
  onRequest: (options, handler) async {
    captured.add(options);
    try {
      final data = await responder(options);
      handler.resolve(
        Response<dynamic>(data: data, statusCode: 200, requestOptions: options),
      );
    } on DioException catch (e) {
      handler.reject(e);
    } catch (e) {
      handler.reject(DioException(requestOptions: options, error: e));
    }
  },
);

MusicLibrary _tokenLib() => MusicLibrary(
  id: 'lib1',
  name: 't',
  username: 'u',
  password: 'p',
  createdAt: DateTime(2020),
  updatedAt: DateTime(2020),
);

MusicLibrary _apiKeyLib() => MusicLibrary(
  id: 'lib2',
  name: 't',
  authType: MusicLibraryAuthType.apiKey,
  apiKey: 'k',
  createdAt: DateTime(2020),
  updatedAt: DateTime(2020),
);

MusicLibrary _incompleteLib() => MusicLibrary(
  id: 'lib3',
  name: 't',
  authType: MusicLibraryAuthType.apiKey,
  apiKey: null,
  createdAt: DateTime(2020),
  updatedAt: DateTime(2020),
);

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SubsonicApiClient.ping', () {
    test('成功 → openSubsonic/type/version', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              'openSubsonic': true,
              'type': 'navidrome',
              'serverVersion': '0.52',
            },
          },
          captured: captured,
        ),
      );
      final r = await client.ping();
      expect(r.success, isTrue);
      expect(r.isOpenSubsonic, isTrue);
      expect(r.serverType, 'navidrome');
      expect(r.serverVersion, '0.52');
    });

    test('DioException → 失败', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => throw DioException(
            requestOptions: RequestOptions(path: '/rest/ping'),
            type: DioExceptionType.connectionTimeout,
            message: 'timeout',
          ),
          captured: captured,
        ),
      );
      final r = await client.ping();
      expect(r.success, isFalse);
      expect(r.errorMessage, isNotNull);
    });

    test('响应类型错误 → 普通异常分支返回失败', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(responder: (_) => 'not-a-map', captured: captured),
      );
      final result = await client.ping();
      expect(result.success, isFalse);
      expect(result.errorMessage, isNotEmpty);
      expect(captured.single.path, ApiConstants.ping);
    });
  });

  group('SubsonicApiClient.getOpenSubsonicExtensions', () {
    test('成功 → 名称列表', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              'openSubsonicExtensions': <Map<String, dynamic>>[
                <String, dynamic>{'name': 'foo'},
                <String, dynamic>{'name': 'bar'},
              ],
            },
          },
          captured: captured,
        ),
      );
      final ext = await client.getOpenSubsonicExtensions();
      expect(ext, <String>['foo', 'bar']);
    });

    test('extensions 为 null → []', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok'},
          },
          captured: captured,
        ),
      );
      expect(await client.getOpenSubsonicExtensions(), isEmpty);
    });

    test('异常 → []', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => throw DioException(
            requestOptions: RequestOptions(
              path: ApiConstants.getOpenSubsonicExtensions,
            ),
            type: DioExceptionType.connectionError,
          ),
          captured: captured,
        ),
      );
      expect(await client.getOpenSubsonicExtensions(), isEmpty);
    });
  });

  group('SubsonicApiClient.get / getRaw / postRaw / deleteRaw', () {
    test('get → 解包 subsonic-response', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok', 'x': 1},
          },
          captured: captured,
        ),
      );
      final data = await client.get('/rest/getAlbum');
      expect(data, <String, dynamic>{'status': 'ok', 'x': 1});
    });

    test('get 缺 subsonic-response 键 → 非空返回类型触发 TypeError', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{'foo': 1},
          captured: captured,
        ),
      );
      expect(() => client.get('/rest/getAlbum'), throwsA(isA<TypeError>()));
    });

    test('get 状态非 ok → 抛 SubsonicException', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'failed',
              'error': <String, dynamic>{'message': 'bad', 'code': 40},
            },
          },
          captured: captured,
        ),
      );
      expect(
        () => client.get('/rest/getAlbum'),
        throwsA(
          predicate<SubsonicException>(
            (e) => e.message == 'bad' && e.code == 40,
          ),
        ),
      );
    });

    test('getRaw → 直接返回 body', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{'raw': true},
          captured: captured,
        ),
      );
      final data = await client.getRaw('/rest/api/v1/x');
      expect(data, <String, dynamic>{'raw': true});
    });

    test('postRaw → 直接返回 body', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{'posted': 1},
          captured: captured,
        ),
      );
      final data = await client.postRaw(
        '/rest/api/v1/y',
        data: <String, dynamic>{},
      );
      expect(data, <String, dynamic>{'posted': 1});
    });

    test('deleteRaw → 直接返回 body', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{'deleted': true},
          captured: captured,
        ),
      );
      final data = await client.deleteRaw('/rest/api/v1/z');
      expect(data, <String, dynamic>{'deleted': true});
    });

    test('raw 超时同时传给收发配置，postRaw 使用 JSON', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (options) => <String, dynamic>{'method': options.method},
          captured: captured,
        ),
      );
      const timeout = Duration(seconds: 7);

      expect(
        await client.getRaw('/rest/api/v1/slow', receiveTimeout: timeout),
        <String, dynamic>{'method': 'GET'},
      );
      expect(captured.last.receiveTimeout, timeout);
      expect(captured.last.sendTimeout, timeout);

      expect(
        await client.postRaw(
          '/rest/api/v1/slow',
          data: <String, dynamic>{'x': 1},
          receiveTimeout: timeout,
        ),
        <String, dynamic>{'method': 'POST'},
      );
      expect(captured.last.receiveTimeout, timeout);
      expect(captured.last.sendTimeout, timeout);
      expect(captured.last.contentType, 'application/json');
    });

    test('post → 解包响应并传递请求参数、数据与重试标记', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              'saved': true,
            },
          },
          captured: captured,
        ),
      );

      final data = await client.post(
        '/rest/updatePlaylist',
        queryParameters: <String, dynamic>{'id': 'p1'},
        data: <String, dynamic>{'name': 'N'},
        allowFallbackRetry: false,
      );
      expect(data['saved'], isTrue);
      expect(captured.single.method, 'POST');
      expect(captured.single.queryParameters['id'], 'p1');
      expect(captured.single.data, <String, dynamic>{'name': 'N'});
      expect(
        captured.single.extra[FallbackInterceptor.allowRetryExtraKey],
        isFalse,
      );
      expect(client.dio, same(dio));
    });
  });

  group('SubsonicApiClient URL 生成（带鉴权参数）', () {
    test('library getter 反映设置与清空', () {
      final client = SubsonicApiClient(dio: _baseDio());
      final library = _tokenLib();
      expect(client.library, isNull);
      client.setLibrary(library);
      expect(client.library, same(library));
      client.setLibrary(null);
      expect(client.library, isNull);
    });

    test('getCoverArtUrl：token 库注入 u/t/s，size 可选', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(responder: (_) => <String, dynamic>{}, captured: captured),
      );
      final url = client.getCoverArtUrl('cover123', size: 300);
      expect(url, contains('getCoverArt'));
      expect(url, contains('id=cover123'));
      expect(url, contains('size=300'));
      expect(url, contains('u=u'));
      expect(url, contains('t='));
      expect(url, contains('s='));
    });

    test('getCoverArtUrl：apiKey 库注入 apiKey', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_apiKeyLib());
      dio.interceptors.add(
        _fake(responder: (_) => <String, dynamic>{}, captured: captured),
      );
      final url = client.getCoverArtUrl('cover123');
      expect(url, contains('apiKey=k'));
      expect(url, isNot(contains('u=u')));
    });

    test('getCoverArtUrl：无库 → 空串', () async {
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      expect(client.getCoverArtUrl('x'), '');
    });

    test('getCoverArtUrl：baseUrl 为空 → 空串', () async {
      final dio = _baseDio(base: '');
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      expect(client.getCoverArtUrl('x'), '');
    });

    test('getStreamUrl：maxBitRate/format/timeOffset 全参数', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(responder: (_) => <String, dynamic>{}, captured: captured),
      );
      final url = client.getStreamUrl(
        'song1',
        maxBitRate: 192,
        format: 'mp3',
        timeOffset: 30,
      );
      expect(url, contains('stream'));
      expect(url, contains('id=song1'));
      expect(url, contains('maxBitRate=192'));
      expect(url, contains('format=mp3'));
      expect(url, contains('timeOffset=30'));
    });

    test('getRemoteStreamUrl：透传全部可选参数；无库 → 空串', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(responder: (_) => <String, dynamic>{}, captured: captured),
      );
      final url = client.getRemoteStreamUrl(
        provider: 'gmd',
        source: 'netease',
        id: 'r1',
        title: 'T',
        artist: 'A',
        album: 'Al',
        duration: 200,
        cover: 'c',
      );
      expect(url, contains('stream-remote'));
      expect(url, contains('provider=gmd'));
      expect(url, contains('source=netease'));
      expect(url, contains('id=r1'));
      expect(url, contains('title=T'));
      expect(url, contains('artist=A'));
      expect(url, contains('album=Al'));
      expect(url, contains('duration=200'));
      expect(url, contains('cover=c'));

      final noLib = SubsonicApiClient(dio: _baseDio());
      expect(
        noLib.getRemoteStreamUrl(provider: 'gmd', source: 'netease', id: 'r1'),
        '',
      );
    });
  });

  group('SubsonicApiClient.getDlnaCastStreamUrl', () {
    test('成功 → 拼接 baseUrl + 返回的相对路径', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(
          responder: (o) {
            expect(o.path, ApiConstants.dlnaStreamUrl);
            return <String, dynamic>{'streamUrl': '/rest/dlna/stream/abc'};
          },
          captured: captured,
        ),
      );
      final url = await client.getDlnaCastStreamUrl('song1');
      expect(url, 'http://srv.test/rest/dlna/stream/abc');
    });

    test('空 streamUrl → 普通异常分支回退带鉴权流', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{'streamUrl': ''},
          captured: captured,
        ),
      );
      final expected = client.getStreamUrl('song-empty', maxBitRate: 128);
      final url = await client.getDlnaCastStreamUrl(
        'song-empty',
        maxBitRate: 128,
      );
      expect(url, expected);
      expect(captured.single.data, <String, dynamic>{'songId': 'song-empty'});
    });

    test('409 → 抛 DlnaSongUnplayableException', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(
          responder: (o) => throw DioException(
            requestOptions: o,
            response: Response<dynamic>(statusCode: 409, requestOptions: o),
          ),
          captured: captured,
        ),
      );
      expect(
        () => client.getDlnaCastStreamUrl('song1'),
        throwsA(isA<DlnaSongUnplayableException>()),
      );
    });

    test('非 409 DioException → 回退带鉴权流', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(
          responder: (o) => throw DioException(
            requestOptions: o,
            response: Response<dynamic>(statusCode: 500, requestOptions: o),
          ),
          captured: captured,
        ),
      );
      final url = await client.getDlnaCastStreamUrl('song1');
      expect(url, client.getStreamUrl('song1'));
    });

    test('无库/baseUrl 空 → 空串', () async {
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      expect(await client.getDlnaCastStreamUrl('song1'), '');
      final c2 = SubsonicApiClient(dio: _baseDio(base: ''))
        ..setLibrary(_tokenLib());
      expect(await c2.getDlnaCastStreamUrl('song1'), '');
    });
  });

  group('SubsonicApiClient.fetchStreamBytes / _buildRangeHeader', () {
    test('无 Range → 直接返回字节', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => Uint8List.fromList(<int>[1, 2, 3]),
          captured: captured,
        ),
      );
      final bytes = await client.fetchStreamBytes('http://x/s');
      expect(bytes, Uint8List.fromList(<int>[1, 2, 3]));
    });

    test('start+end / start only / end only → Range 头三类分支', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => Uint8List.fromList(<int>[9, 9, 9]),
          captured: captured,
        ),
      );

      await client.fetchStreamBytes('http://x/s', start: 10, end: 20);
      expect(captured.last.headers['Range'], 'bytes=10-20');

      await client.fetchStreamBytes('http://x/s', start: 5);
      expect(captured.last.headers['Range'], 'bytes=5-');

      await client.fetchStreamBytes('http://x/s', end: 99);
      expect(captured.last.headers['Range'], 'bytes=0-99');
    });

    test('空响应 → 抛 StateError', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(_fake(responder: (_) => null, captured: captured));
      expect(() => client.fetchStreamBytes('http://x/s'), throwsStateError);
    });
  });

  group('SubsonicApiClient.getMusicFolders', () {
    test('folders 为 List → 返回', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              'musicFolders': <String, dynamic>{
                'musicFolder': <Map<String, dynamic>>[
                  <String, dynamic>{'id': '1', 'name': 'F1'},
                ],
              },
            },
          },
          captured: captured,
        ),
      );
      final folders = await client.getMusicFolders();
      expect(folders, hasLength(1));
      expect(folders.first['name'], 'F1');
    });

    test('folders 为单个 Map → 包成列表', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              'musicFolders': <String, dynamic>{
                'musicFolder': <String, dynamic>{'id': '2', 'name': 'F2'},
              },
            },
          },
          captured: captured,
        ),
      );
      final folders = await client.getMusicFolders();
      expect(folders, hasLength(1));
      expect(folders.first['name'], 'F2');
    });

    test('folders 缺失/null → []', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok'},
          },
          captured: captured,
        ),
      );
      expect(await client.getMusicFolders(), isEmpty);
    });

    test('异常 → []', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => throw DioException(
            requestOptions: RequestOptions(path: ApiConstants.getMusicFolders),
            type: DioExceptionType.connectionError,
          ),
          captured: captured,
        ),
      );
      expect(await client.getMusicFolders(), isEmpty);
    });
  });

  group('SubsonicApiClient 认证参数与拦截器', () {
    test('无库时请求仍带通用参数 v/c/f（不抛）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok'},
          },
          captured: captured,
        ),
      );
      await client.get('/rest/ping');
      final qp = captured.last.queryParameters;
      expect(qp['v'], ApiConstants.apiVersion);
      expect(qp['c'], ApiConstants.clientName);
      expect(qp['f'], ApiConstants.format);
      expect(qp.containsKey('apiKey'), isFalse);
      expect(qp.containsKey('u'), isFalse);
    });

    test('apiKey 库但 apiKey 为空 → 走通用参数分支（else）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_incompleteLib());
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok'},
          },
          captured: captured,
        ),
      );
      await client.get('/rest/ping');
      final qp = captured.last.queryParameters;
      expect(qp.containsKey('apiKey'), isFalse);
      expect(qp['c'], ApiConstants.clientName);
    });

    test('拦截器注入 x-mf-client-id 头（clientId 可用）', () async {
      final captured = <RequestOptions>[];
      final dio = _baseDio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
        _fake(
          responder: (_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok'},
          },
          captured: captured,
        ),
      );
      await client.get('/rest/ping');
      final headers = captured.last.headers;
      expect(headers.containsKey('x-mf-client-id'), isTrue);
      expect(headers['x-mf-client-id'], isNotEmpty);
    });
  });

  group('SubsonicException', () {
    test('toString 包含消息与错误码', () {
      final error = SubsonicException('bad request', 40);
      expect(error.toString(), 'SubsonicException: bad request (code: 40)');
    });
  });
}
