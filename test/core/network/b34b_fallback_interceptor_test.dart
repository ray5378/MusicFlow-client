import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/data/models/server_address.dart';

typedef AdapterHandler = Future<ResponseBody> Function(RequestOptions options);

class StubAdapter implements HttpClientAdapter {
  AdapterHandler handler;
  int requestCount = 0;
  final List<String> requested = [];

  StubAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    requested.add('${options.method} ${options.uri}');
    return handler(options);
  }
}

ResponseBody okBody([String body = '{"ok":true}']) =>
    ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });

DioException connectionError(RequestOptions options) => DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: Exception('connection refused'),
    );

void main() {
  // 切换成功后拦截器会调 ToastNotifier.show → rootNavigatorKey.currentState
  // 需要已初始化的 WidgetsBinding（见 lib 中 D-037 相关注释）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late StubAdapter adapter;
  late AddressPool pool;
  late FallbackInterceptor interceptor;

  ServerAddress addr({
    required String id,
    required String url,
    int priority = 0,
  }) =>
      ServerAddress(
        id: id,
        libraryId: 'lib-1',
        label: id,
        url: url,
        priority: priority,
      );

  /// 重建池并全量探测（默认 stub 下两地址均 ok），active = 优先级最高者。
  /// 注意：拦截器必须引用同一个 pool 实例，故每次重建后重新挂拦截器。
  Future<void> buildPool({
    bool manualA = false,
    bool autoFallback = true,
  }) async {
    pool = AddressPool(dio);
    pool.autoFallback = autoFallback;
    dio.interceptors.clear();
    interceptor = FallbackInterceptor(pool, dio);
    dio.interceptors.add(interceptor);
    pool.setAddresses([
      addr(id: 'a', url: 'https://a.example.com'),
      addr(id: 'b', url: 'https://b.example.com', priority: 1),
    ]);
    await pool.probeAll();
    if (manualA) {
      await pool.setManualMode(
        pool.addresses.firstWhere((a) => a.id == 'a'),
      );
    }
  }

  setUp(() {
    dio = Dio();
    adapter = StubAdapter((options) async {
      final key = '${options.method} ${options.uri.host}';
      if (key == 'GET a.example.com') throw connectionError(options);
      return okBody();
    });
    dio.httpClientAdapter = adapter;
    pool = AddressPool(dio);
    interceptor = FallbackInterceptor(pool, dio);
    dio.interceptors.add(interceptor);
  });

  group('onRequest', () {
    test('有活跃地址时 baseUrl 归一化为活跃地址（去尾斜杠）', () async {
      await buildPool();
      Uri? seen;
      adapter.handler = (options) async {
        seen = options.uri;
        return okBody();
      };
      await dio.get<String>('/rest/ping');
      expect(seen?.host, 'a.example.com');
      expect(seen?.path, '/rest/ping');
      expect(pool.activeAddress?.id, 'a');
    });

    test('无活跃地址时不覆盖 baseUrl（保持空）', () async {
      final bare = AddressPool(dio);
      dio.interceptors.clear();
      final freshInterceptor = FallbackInterceptor(bare, dio);
      dio.interceptors.add(freshInterceptor);
      RequestOptions? captured;
      adapter.handler = (options) async {
        captured = options;
        return okBody();
      };
      await dio.get<String>('/rest/ping');
      expect(captured?.baseUrl, isEmpty);
      expect(bare.activeAddress, isNull);
    });
  });

  group('onResponse / 非连接错误', () {
    test('成功响应会重置连续失败计数（重置后单次失败不再触发切换）', () async {
      await buildPool();
      // 第 1 次：连接错误 → 计数 1，不切换，向上抛。
      await expectLater(dio.get<String>('/rest/ping'),
          throwsA(isA<DioException>()));
      expect(pool.activeAddress?.id, 'a');
      // 成功一次 → 计数清零。
      adapter.handler = (options) async => okBody();
      final ok = await dio.get<String>('/rest/ping');
      expect(ok.statusCode, 200);
      // 再失败一次：计数只到 1，仍不切换。
      adapter.handler = (options) async {
        if (options.uri.host == 'a.example.com') {
          throw connectionError(options);
        }
        return okBody();
      };
      await expectLater(dio.get<String>('/rest/ping'),
          throwsA(isA<DioException>()));
      expect(pool.activeAddress?.id, 'a', reason: '计数被响应重置，单次失败不切');
    });

    test('非连接类错误（如 404 badResponse）不累计失败计数', () async {
      await buildPool();
      adapter.handler = (options) async => ResponseBody.fromString('nope', 404);
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      // 若计数被错误累计，这次连接错误将触发切换；应为「计数 1 → 不切」。
      adapter.handler = (options) async {
        if (options.uri.host == 'a.example.com') {
          throw connectionError(options);
        }
        return okBody();
      };
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(pool.activeAddress?.id, 'a');
    });
  });

  group('onError 连接错误降级', () {
    test('extra 显式禁止重试（非幂等请求）→ 不切换直接抛出', () async {
      await buildPool();
      final options = Options(
        extra: {FallbackInterceptor.allowRetryExtraKey: false},
      );
      await expectLater(
        dio.get<String>('/rest/ping', options: options),
        throwsA(isA<DioException>()),
      );
      expect(pool.activeAddress?.id, 'a');
      // 连续两次也不切换。
      await expectLater(
        dio.get<String>('/rest/ping', options: options),
        throwsA(isA<DioException>()),
      );
      expect(pool.activeAddress?.id, 'a');
    });

    test('手动模式且 autoFallback 关闭 → 不自动切换线路', () async {
      await buildPool(manualA: true, autoFallback: false);
      expect(pool.isManualMode, isTrue);
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(pool.activeAddress?.id, 'a');
    });

    test('连续 2 次连接错误 → markFailed 后切到备线并重放成功', () async {
      await buildPool();
      // 第 1 次失败：计数 1，抛出。
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      // 第 2 次失败：达到阈值 → 切到 b → 重放请求成功 resolve。
      final response = await dio.get<String>('/rest/ping');
      expect(response.statusCode, 200);
      expect(pool.activeAddress?.id, 'b', reason: '应已切换到备线 b');
      expect(adapter.requested.last.split(' ').first, 'GET',
          reason: '最后一条请求应为重放的 GET');
      expect(adapter.requested.last.contains('b.example.com'), isTrue,
          reason: '重放请求应发往新地址');
      // 切换成功后 markFailed 已把 a 标为 failed。
      expect(
        pool.addresses.firstWhere((a) => a.id == 'a').status,
        ServerAddressStatus.failed,
      );
    });

    test('切换成功但重放仍失败 → 错误继续向上传播', () async {
      await buildPool();
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      // b 的 GET 也失败（HEAD 探测仍成功，switchTo 能走通）。
      adapter.handler = (options) async {
        if (options.method == 'GET') throw connectionError(options);
        return okBody();
      };
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(pool.activeAddress?.id, 'b', reason: '线路已切到 b（探测成功）');
    });

    test('无备选地址（下一跳就是当前地址）→ 不切换直接抛出', () async {
      pool = AddressPool(dio);
      dio.interceptors.clear();
      interceptor = FallbackInterceptor(pool, dio);
      dio.interceptors.add(interceptor);
      pool.setAddresses([addr(id: 'only', url: 'https://a.example.com')]);
      await pool.probeAll();
      expect(pool.activeAddress?.id, 'only');
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(pool.activeAddress?.id, 'only');
    });

    test('unknown 类型 + SocketException 消息也算连接错误并触发降级', () async {
      await buildPool();
      adapter.handler = (options) async {
        if (options.method == 'GET' && options.uri.host == 'a.example.com') {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            message: 'SocketException: Connection closed (0)',
          );
        }
        return okBody();
      };
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      final response = await dio.get<String>('/rest/ping');
      expect(response.statusCode, 200);
      expect(pool.activeAddress?.id, 'b');
    });

    test('switchTo 被地址池拒绝（探测失败）→ 不重放直接抛出', () async {
      await buildPool();
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      // b 的 GET 与 HEAD 均失败 → switchTo 返回 false → 不重放。
      adapter.handler = (options) async {
        throw connectionError(options);
      };
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      // 未发起重放：对 b 的 GET 重放请求不存在（仅探测 HEAD 可达 b）。
      expect(
        adapter.requested
            .where((r) => r.startsWith('GET') && r.contains('b.example.com')),
        isEmpty,
        reason: 'switchTo 被拒绝后不应发起重放请求（实际请求：${adapter.requested}）',
      );
    });
  });
}
