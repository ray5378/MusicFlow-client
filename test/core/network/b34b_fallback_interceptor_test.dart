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

/// 统计「发往某个 host 的 GET 实际次数」——用来验证同地址重试的次数上限。
int getCount(StubAdapter adapter, String host) => adapter.requested
    .where((r) => r.startsWith('GET') && r.contains(host))
    .length;

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
    // 令牌桶 / 时钟 / 退避是 static 状态，必须逐用例复位（否则一个用例烧掉的
    // 令牌会让后面的用例莫名「不重试」）。
    FallbackInterceptor.resetRetryStateForTest();
    // 本文件只验语义；1s/2s 退避压成 0，避免用例真等（退避调度由
    // net_same_address_retry_test.dart 单独覆盖）。
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
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

  tearDown(FallbackInterceptor.resetRetryStateForTest);

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

    test('无活跃地址且地址池为空时不覆盖 baseUrl（保持空）', () async {
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

    // 「无活跃地址但池内有地址 → 兜底用池内地址」的用例放在
    // test/core/network/net_same_address_retry_test.dart（那里用固定地址池，
    // 不受 setAddresses 的异步探测干扰）。
  });

  group('onResponse / 非连接错误', () {
    test('成功响应不触发重试或切换；随后单次连接错误仍可自愈', () async {
      // 语义已从「成功响应把连续失败计数清零，使单次失败不切换」改为
      // 「每条请求自己完成『同地址重试 → 切线路』」：_consecutiveFailures 不再
      // 参与判定（只作为日志/取证信号），因此不再需要「成功一次垫背」。
      await buildPool();
      adapter.handler = (options) async => okBody();
      final before = adapter.requestCount;
      final ok = await dio.get<String>('/rest/ping');
      expect(ok.statusCode, 200);
      expect(adapter.requestCount - before, 1, reason: '成功响应不该有重试');
      expect(pool.activeAddress?.id, 'a');

      // 一次连接错误即可自愈：重试就发生在这一条请求内部。
      adapter.handler = (options) async {
        if (options.uri.host == 'a.example.com') {
          throw connectionError(options);
        }
        return okBody();
      };
      final healed = await dio.get<String>('/rest/ping');
      expect(healed.statusCode, 200);
      expect(pool.activeAddress?.id, 'b', reason: '重试耗尽后切到备线并重放成功');
    });

    test('非连接类错误（如 404 badResponse）不重试、不切换，直接抛出', () async {
      await buildPool();
      adapter.handler = (options) async => ResponseBody.fromString('nope', 404);
      final before = adapter.requestCount;
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(
        adapter.requestCount - before,
        1,
        reason: '404 是确定性的，重试没有意义',
      );
      expect(pool.activeAddress?.id, 'a');
    });
  });

  group('onError 连接错误降级', () {
    test('extra 显式禁止重试（非幂等请求）→ 不重试直接抛出', () async {
      await buildPool();
      final options = Options(
        extra: {FallbackInterceptor.allowRetryExtraKey: false},
      );
      final before = adapter.requestCount;
      await expectLater(
        dio.get<String>('/rest/ping', options: options),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requestCount - before, 1);
      expect(pool.activeAddress?.id, 'a');
      // 连续两次也不切换。
      await expectLater(
        dio.get<String>('/rest/ping', options: options),
        throwsA(isA<DioException>()),
      );
      expect(pool.activeAddress?.id, 'a');
    });

    test('手动模式且 autoFallback 关闭 → 允许重试但不切换线路', () async {
      await buildPool(manualA: true, autoFallback: false);
      expect(pool.isManualMode, isTrue);
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(
        getCount(adapter, 'a.example.com'),
        4,
        reason: '手动锁定 + 关自动回退 → 策略不允许切走 → 等同无备线 → 拿满 3 次'
            '重试（1 原始 + 3 次重试），而不是只打 2 次：预算给 1 的理由是'
            '「把时间让给 failover」，而这一支根本没有 failover',
      );
      expect(pool.activeAddress?.id, 'a');
    });

    test('首次连接错误即重试；重试耗尽后 markFailed 并切到备线重放成功', () async {
      // 语义已从「连续 2 次连接错误（需要两条请求）才 markFailed + 切线路」
      // 改为「同一条请求内先做 3 次同地址重试，耗尽后再切线路」：
      // 首屏十几条请求几乎同时失败会把旧计数瞬间抬到 2 以上，旧门槛于是让它们
      // 全部掉进「切线路」分支；单地址又切不动，结果一条都不重试、整屏失败。
      await buildPool();

      final response = await dio.get<String>('/rest/ping');

      expect(response.statusCode, 200);
      expect(
        getCount(adapter, 'a.example.com'),
        2,
        reason: 'a 上 1 次原始失败 + 1 次同地址重试（有健康备线 → 预算 1），'
            '随后切到 b',
      );
      expect(pool.activeAddress?.id, 'b', reason: '应已切换到备线 b');
      expect(adapter.requested.last.split(' ').first, 'GET',
          reason: '最后一条请求应为重放的 GET');
      expect(adapter.requested.last.contains('b.example.com'), isTrue,
          reason: '重放请求应发往新地址');
      // 切换成功后 markFailed 已把 a 标为 failed（多地址池仍判死）。
      expect(
        pool.addresses.firstWhere((a) => a.id == 'a').status,
        ServerAddressStatus.failed,
      );
    });

    test('切换成功但重放仍失败 → 错误继续向上传播', () async {
      await buildPool();
      // b 的读取也失败（HEAD 探测仍成功，switchTo 能走通）。
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

    test('单地址池 → 重试耗尽后无下一跳，直接抛出（且不判死）', () async {
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

      expect(pool.activeAddress?.id, 'only');
      expect(
        getCount(adapter, 'a.example.com'),
        4,
        reason: '单地址也有 1 原始 + 3 次重试的自愈机会，然后才放弃',
      );
      // 单地址刻意不判死（见 AddressPool.markFailed 注释）。
      expect(
        pool.addresses.single.status,
        ServerAddressStatus.ok,
        reason: '唯一线路不被 markFailed 判死，否则会连锁触发离线降级',
      );
    });

    test('unknown 类型 + SocketException 消息也算连接错误并触发重试/降级', () async {
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
      final response = await dio.get<String>('/rest/ping');
      expect(response.statusCode, 200);
      expect(pool.activeAddress?.id, 'b');
      expect(getCount(adapter, 'a.example.com'), 2);
    });

    test('switchTo 被地址池拒绝（探测失败）→ 不重放直接抛出', () async {
      await buildPool();
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
