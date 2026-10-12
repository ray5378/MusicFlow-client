// b50c —— FallbackInterceptor 并发故障切换竞态回归（P2）。
//
// 缺陷：`_consecutiveFailures` 与「切换 + 重试」由多条在途请求的 onError
// 并发触发 → 重复 markFailed / switchTo / 弹多条提示，甚至切到刚切走的线路。
// 修复：`_failoverInFlight` 重入护栏 —— 一次切换/重试未结束前，其余并发连接
// 错误直接上抛，不再进入切换分支。
//
// 打法：真 Dio + StubAdapter + 真 AddressPool（子类计数 switchTo）。
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

/// 计数地址池：切换次数是「是否发生重复切换」的直接证据。
class _CountingPool extends AddressPool {
  _CountingPool(super.dio);
  int switchCount = 0;

  @override
  Future<bool> switchTo(ServerAddress addr, {bool manual = true}) {
    switchCount++;
    return super.switchTo(addr, manual: manual);
  }
}

ResponseBody _okBody() => ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

DioException _connErr(RequestOptions o) => DioException(
      requestOptions: o,
      type: DioExceptionType.connectionError,
      error: Exception('refused'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late _StubAdapter adapter;
  late _CountingPool pool;
  late FallbackInterceptor interceptor;

  ServerAddress addr(String id, String url, {int priority = 0}) =>
      ServerAddress(
        id: id,
        libraryId: 'lib-1',
        label: id,
        url: url,
        priority: priority,
      );

  Future<void> buildPool() async {
    dio = Dio();
    adapter = _StubAdapter((_) async => _okBody());
    dio.httpClientAdapter = adapter;
    dio.interceptors.clear();
    pool = _CountingPool(dio);
    interceptor = FallbackInterceptor(pool, dio);
    dio.interceptors.add(interceptor);
    pool.setAddresses([
      addr('a', 'https://a.example.com'),
      addr('b', 'https://b.example.com', priority: 1),
    ]);
    await pool.probeAll(); // 让 a 成为活跃地址
  }

  test('并发连接失败只触发一次故障切换', () async {
    await buildPool();
    expect(pool.activeAddress?.id, 'a');

    adapter.handler = (o) async {
      if (o.uri.host == 'a.example.com') throw _connErr(o);
      return _okBody();
    };

    // 三条请求同时在途、同时失败。
    final results = await Future.wait([
      dio.get<String>('/rest/ping').then((_) => 'ok', onError: (_) => 'err'),
      dio.get<String>('/rest/ping').then((_) => 'ok', onError: (_) => 'err'),
      dio.get<String>('/rest/ping').then((_) => 'ok', onError: (_) => 'err'),
    ]);

    expect(pool.activeAddress?.id, 'b', reason: '应切换到可用线路 b');
    expect(pool.switchCount, 1, reason: '并发失败必须只切换一次，不得重复切换');
    expect(results.contains('ok'), isTrue, reason: '切换后重试应至少有一条成功');
  });

  test('切换后重试仍失败：不递归、不产生请求风暴，仅切换一次', () async {
    await buildPool();

    final aHits = <RequestOptions>[];
    adapter.handler = (o) async {
      if (o.uri.host == 'a.example.com') {
        aHits.add(o);
        throw _connErr(o);
      }
      // 对 b 的探测（HEAD）成功让 switchTo 返回 true；重试（GET）失败。
      if (o.method == 'HEAD') return _okBody();
      throw _connErr(o);
    };

    for (var i = 0; i < 2; i++) {
      await dio.get<String>('/rest/ping').then((_) {}, onError: (_) {
        /* 吞掉，断言只看切换与请求次数 */
      });
    }

    expect(pool.switchCount, 1, reason: '重试失败不得再次触发切换（无递归）');
    expect(
      aHits.length,
      2,
      reason: 'a 上仅两次原始失败，重试失败的请求不再回流触发新一轮切换',
    );
  });

  test('单次连接失败不切换（阈值语义未变）', () async {
    await buildPool();

    adapter.handler = (o) async {
      if (o.uri.host == 'a.example.com') throw _connErr(o);
      return _okBody();
    };

    await dio.get<String>('/rest/ping').then((_) {}, onError: (_) {});

    expect(pool.switchCount, 0);
    expect(pool.activeAddress?.id, 'a');
  });
}