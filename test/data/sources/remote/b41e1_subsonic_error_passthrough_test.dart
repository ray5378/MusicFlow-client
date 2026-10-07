// batch41 E1 —— SubsonicApiClient「Error 穿透、Exception 吞」改造验证（收口订正版）。
//
// 最终语义（2026-10-07 用户拍板「Error 穿透、Exception 吞」，经 b30b 契约与
// handoff_e2e 回归校准）：
// - 服务端脏负载（响应不是 Map）属**数据错误**：_asResponseMap 抛 Exception →
//   走普通失败分支（ping→success:false、folders→[]、extensions→[]、dlna 流→回退），
//   不因 TypeError 穿透击穿既有契约（b30b ping 用例 / handoff_e2e 主通道回落）；
// - 真编程错误（Error）：catch 内 `if (e is Error) rethrow;` 原样上抛，不再吞成安全值
//   （钉子：字段级类型不符 int 冒充 String → rethrow TypeError）。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';

Dio _dio({String base = 'http://srv.test'}) => Dio(BaseOptions(baseUrl: base));

/// 直接 resolve 指定 body 的拦截器（不做任何错误包装）。
Interceptor _resolveWith(dynamic Function(RequestOptions) responder) =>
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            data: responder(options),
            statusCode: 200,
            requestOptions: options,
          ),
        );
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

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('脏负载 = 数据错误（Exception 语义，优雅降级）', () {
    test('ping：响应不是 Map → success:false（契约锚点 b30b）', () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(_resolveWith((_) => 'not-a-map'));
      final result = await client.ping();
      expect(result.success, isFalse);
      expect(result.errorMessage, isNotEmpty);
    });

    test('getMusicFolders：响应不是 Map → []', () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(_resolveWith((_) => 'not-a-map'));
      expect(await client.getMusicFolders(), isEmpty);
    });

    test('getOpenSubsonicExtensions：响应不是 Map → []', () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(_resolveWith((_) => 'not-a-map'));
      expect(await client.getOpenSubsonicExtensions(), isEmpty);
    });

    test('getDlnaCastStreamUrl：响应不是 Map → 静默回退带鉴权流（handoff 回落契约）',
        () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(_resolveWith((_) => 'not-a-map'));
      final expected = client.getStreamUrl('song-1', maxBitRate: 128);
      expect(
        await client.getDlnaCastStreamUrl('song-1', maxBitRate: 128),
        expected,
      );
    });
  });

  group('真编程错误仍穿透（Error 不吞）', () {
    test('ping：字段级类型不符（int 冒充 String）→ rethrow TypeError', () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(_resolveWith((_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              'type': 123,
            },
          }));
      await expectLater(client.ping(), throwsA(isA<TypeError>()));
    });
  });

  group('Exception 仍按原安全路径（吞掉语义不变）', () {
    test('ping：status 非 ok（SubsonicException）→ success:false', () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(_resolveWith((_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'failed',
              'error': <String, dynamic>{'message': 'bad', 'code': 40},
            },
          }));
      final result = await client.ping();
      expect(result.success, isFalse);
      expect(result.errorMessage, isNotEmpty);
    });

    test('getMusicFolders：status 非 ok → []', () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio);
      dio.interceptors.add(_resolveWith((_) => <String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'failed',
              'error': <String, dynamic>{'message': 'bad', 'code': 40},
            },
          }));
      expect(await client.getMusicFolders(), isEmpty);
    });

    test('getDlnaCastStreamUrl：DioException(非 409) → 回退带鉴权流', () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ));
        },
      ));
      final expected = client.getStreamUrl('song-1', maxBitRate: 128);
      expect(await client.getDlnaCastStreamUrl('song-1', maxBitRate: 128),
          expected);
    });

    test('getDlnaCastStreamUrl：streamUrl 为空（Exception 哨兵）→ 回退带鉴权流',
        () async {
      final dio = _dio();
      final client = SubsonicApiClient(dio: dio)..setLibrary(_tokenLib());
      dio.interceptors.add(
          _resolveWith((_) => <String, dynamic>{'streamUrl': ''}));
      final expected = client.getStreamUrl('song-empty', maxBitRate: 128);
      expect(
          await client.getDlnaCastStreamUrl('song-empty', maxBitRate: 128),
          expected,
          reason: '空 streamUrl 是期望内的服务端数据缺失（Exception），回退契约保持');
    });
  });
}
