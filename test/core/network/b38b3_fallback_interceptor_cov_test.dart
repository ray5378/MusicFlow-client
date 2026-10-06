// b38b3 —— `lib/core/network/fallback_interceptor.dart` 补测。
//
// 未覆盖行（230 lcov）：133 —— `onError` 的「非连接错误」分支里，若此前已有
// 连续失败计数，会打一条 `reset consecutive failure counter` 日志。
// 既有 b34b 用例是在计数为 0 时喂 404，故该行从未命中。
//
// 复现路径：先制造 1 次连接错误（计数→1，向上抛），再制造一次非连接错误
// （如 404 badResponse）→ 进入 else 分支且计数 != 0 → 命中 133。
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

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);
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
    dio = Dio();
    adapter = _StubAdapter((options) async => _okBody());
    dio.httpClientAdapter = adapter;
    pool = AddressPool(dio);
    interceptor = FallbackInterceptor(pool, dio);
    dio.interceptors.add(interceptor);
  });

  test('连接失败计数非零后遇到非连接错误：重置计数（命中 133 日志分支）', () async {
    await buildPool();

    // 第 1 次：连接错误 → 计数 1，切换阈值未达，向上抛（不切换）。
    adapter.handler = (options) async {
      if (options.uri.host == 'a.example.com') throw _connErr(options);
      return _okBody();
    };
    await expectLater(dio.get<String>('/rest/ping'), throwsA(isA<DioException>()));
    expect(pool.activeAddress?.id, 'a', reason: '仅 1 次失败，不切换');

    // 第 2 次：非连接错误（404）→ 进入 else 分支且计数=1 → 命中 133 并清零。
    adapter.handler = (options) async =>
        ResponseBody.fromString('nope', 404);
    await expectLater(dio.get<String>('/rest/ping'), throwsA(isA<DioException>()));

    // 计数已被 133 分支清零：此时一次连接错误只会到 1，仍不切换。
    adapter.handler = (options) async {
      if (options.uri.host == 'a.example.com') throw _connErr(options);
      return _okBody();
    };
    await expectLater(dio.get<String>('/rest/ping'), throwsA(isA<DioException>()));
    expect(pool.activeAddress?.id, 'a',
        reason: '非连接错误应把连续失败计数清零（否则此处会切到 b）');
  });
}
