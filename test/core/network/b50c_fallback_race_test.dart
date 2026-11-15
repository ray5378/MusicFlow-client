// b50c —— FallbackInterceptor 并发故障切换竞态回归（P2）。
//
// 原始缺陷：`_consecutiveFailures` 与「切换 + 重试」由多条在途请求的 onError
// 并发触发 → 重复 markFailed / switchTo / 弹多条提示，甚至切到刚切走的线路。
//
// 批 A 语义变更（本文件随之调整）：
//   * 重试不再受 `_failoverInFlight` 全局锁约束（它改由「按请求的 extra 计数 +
//     全局令牌桶」控制），否则十几条并发请求里只有一条能重试；
//   * 阈值不再看「连续失败 2 次」，而是「同一条请求内同地址重试 3 次耗尽」。
// 因此「每条逻辑请求在单个地址上最多 1 次原始 + 3 次重试」成为新的稳态，
// 而「切换最多一次、不递归」的原护栏语义保持不变。
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

  setUp(() {
    // 令牌桶是 static：不复位的话上一个用例烧掉的令牌会让本用例莫名「不重试」。
    FallbackInterceptor.resetRetryStateForTest();
    // 只验并发语义，把 1s/2s 退避压成 0（退避调度由
    // net_same_address_retry_test.dart 覆盖）。
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
  });

  tearDown(FallbackInterceptor.resetRetryStateForTest);

  test('并发连接失败只触发一次故障切换', () async {
    await buildPool();
    expect(pool.activeAddress?.id, 'a');

    adapter.handler = (o) async {
      if (o.method != 'HEAD' && o.uri.host == 'a.example.com') {
        throw _connErr(o);
      }
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
    expect(results.contains('ok'), isTrue, reason: '切换后重放应至少有一条成功');
  });

  test('重试失败后不再递归切换：切换只发生一次，每条请求的重试次数有界', () async {
    await buildPool();

    final aHits = <RequestOptions>[];
    final bHits = <RequestOptions>[];
    adapter.handler = (o) async {
      // 对 b 的探测（HEAD）成功，让 switchTo 返回 true；读取一律失败。
      if (o.method == 'HEAD') return _okBody();
      if (o.uri.host == 'a.example.com') {
        aHits.add(o);
        throw _connErr(o);
      }
      bHits.add(o);
      throw _connErr(o);
    };

    for (var i = 0; i < 2; i++) {
      await dio.get<String>('/rest/ping').then((_) {}, onError: (_) {
        /* 吞掉，断言只看切换与请求次数 */
      });
    }

    expect(pool.switchCount, 1, reason: '重试失败不得再次触发切换（无递归）');
    // 注意：aHits / bHits 是**两个相互独立的用户请求**的合计，不是单请求放大。
    // 预算按「有没有健康备线」分档且钉在首个失败帧（见 hasNextHop 注释）：
    //   第 1 轮 a 挂了但 b 健康 → 预算 1：a 上「1 原始 + 1 重试」→ 切 b；
    //     切过去之后预算仍是 1（不重算、不复位），故 b 上只重放 1 次就放弃。
    //   第 2 轮 active=b 且 a 已 failed → 等于「无备线」→ 预算 3：
    //     b 上「1 原始 + 3 重试」= 4。
    expect(
      aHits.length,
      2,
      reason: 'a 上 1 次原始 + 1 次重试（有健康备线 → 预算 1），之后切到 b',
    );
    expect(
      bHits.length,
      5,
      reason: '第 1 轮切换后重放 1 次（预算仍为 1）；'
          '第 2 轮 b 是唯一活路 → 1 原始 + 3 重试 —— 合计 5，有界不风暴',
    );
  });

  test('单次连接失败 → 同地址重试耗尽后才切线路（阈值语义已变更）', () async {
    await buildPool();

    final aHits = <RequestOptions>[];
    adapter.handler = (o) async {
      if (o.method != 'HEAD' && o.uri.host == 'a.example.com') {
        aHits.add(o);
        throw _connErr(o);
      }
      return _okBody();
    };

    await dio.get<String>('/rest/ping').then((_) {}, onError: (_) {});

    // 语义已从「连续 2 条请求各失败 1 次才切换」改为「单条请求自己重试到
    // 预算耗尽即切换」：一条首屏请求就能完成自愈，不再依赖第二条请求把
    // 计数顶到 2（旧门槛在十几条并发同时失败时恰恰让所有请求都不重试）。
    // 有健康备线时预算为 1，故 a 上只打 2 次（1 原始 + 1 重试）。
    expect(aHits.length, 2);
    expect(pool.switchCount, 1);
    expect(pool.activeAddress?.id, 'b');
  });
}
