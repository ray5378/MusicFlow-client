// b38b3 —— `lib/core/network/fallback_interceptor.dart` 补测。
//
// 覆盖 `onError` 的「非连接错误」分支里，若此前已有连续失败计数，会打一条
// `reset consecutive failure counter` 日志并清零。
//
// 语义变更说明（批 A）：`_consecutiveFailures` 已不再参与任何判定（重试阈值
// 由「同地址重试 3 次」承担，切线路由「重试耗尽」承担），只保留为日志/取证
// 信号。因此本用例改为用「不算失败」的 receiveTimeout 先累加计数（它属连接
// 类错误但**不重试**，不会把线路切走），再喂 404 命中该分支。
//
// 产品代码零改动；只读 lib。

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/data/models/server_address.dart';

typedef _Handler = Future<ResponseBody> Function(RequestOptions options);

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  _Handler handler;

  /// 实际发出的请求数（含重试），用来断言「重试了/没重试」。
  int requestCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestCount++;
    return handler(options);
  }
}

ResponseBody _okBody([String body = '{"ok":true}']) =>
    ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });

DioException _connErr(RequestOptions options) => DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: Exception('connection refused'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late _StubAdapter adapter;
  late AddressPool pool;
  late FallbackInterceptor interceptor;

  ServerAddress addr(String id, String url, {int priority = 0}) => ServerAddress(
        id: id,
        libraryId: 'lib-1',
        label: id,
        url: url,
        priority: priority,
      );

  Future<void> buildPool() async {
    pool = AddressPool(dio);
    dio.interceptors.clear();
    interceptor = FallbackInterceptor(pool, dio);
    dio.interceptors.add(interceptor);
    pool.setAddresses([
      addr('a', 'https://a.example.com'),
      addr('b', 'https://b.example.com', priority: 1),
    ]);
    await pool.probeAll();
  }

  setUp(() {
    FallbackInterceptor.resetRetryStateForTest();
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
    dio = Dio();
    adapter = _StubAdapter((options) async => _okBody());
    dio.httpClientAdapter = adapter;
    pool = AddressPool(dio);
    interceptor = FallbackInterceptor(pool, dio);
    dio.interceptors.add(interceptor);
  });

  tearDown(FallbackInterceptor.resetRetryStateForTest);

  test('连接失败计数非零后遇到非连接错误：重置计数并照常向上抛', () async {
    await buildPool();

    // 第 1 步：receiveTimeout 属连接类错误 → 计数 1；但按设计不重试、不切换，
    // 因此既能累加计数，又不会把活跃地址切到 b（保持下一断言的可预测性）。
    adapter.handler = (options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    };
    final afterFirst = adapter.requestCount;
    await expectLater(dio.get<String>('/rest/ping'), throwsA(isA<DioException>()));
    expect(adapter.requestCount - afterFirst, 1, reason: 'receiveTimeout 不重试');
    expect(pool.activeAddress?.id, 'a');

    // 第 2 步：非连接错误（404）→ 进入 else 分支且计数=1 → 打 reset 日志并清零。
    adapter.handler = (options) async => ResponseBody.fromString('nope', 404);
    await expectLater(dio.get<String>('/rest/ping'), throwsA(isA<DioException>()));
    expect(pool.activeAddress?.id, 'a', reason: '非连接错误不切换线路');

    // 第 3 步：连接错误照常走「同地址重试 → 切备线」，证明拦截器状态未被打乱。
    adapter.handler = (options) async {
      if (options.method == 'GET' && options.uri.host == 'a.example.com') {
        throw _connErr(options);
      }
      return _okBody();
    };
    final response = await dio.get<String>('/rest/ping');
    expect(response.statusCode, 200);
    expect(pool.activeAddress?.id, 'b');
  });
}
