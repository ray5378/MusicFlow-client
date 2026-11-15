// net_retry_budget_guard_test.dart —— 「同地址重试预算」分档判据的独立守卫。
//
// 背景：`FallbackInterceptor.onError` 的预算按「有没有健康备线」分 1 / 3 两档：
//
//   final hasNextHop = canSwitch &&
//       _addressPool.addresses.any(
//         (a) => a.id != activeAddress?.id &&
//                !a.isLocked &&
//                a.status == ServerAddressStatus.ok,
//       );
//   maxAttempts = hasNextHop ? 1 : maxSameAddressRetries;   // 1 / 3
//
// 其中 `!a.isLocked` 这一段在生产里几乎构造不出来（`setManualMode` 会解锁其它
// 地址、`_restoreActiveAddressFromPool` 又优先把锁定地址选成活跃地址），因此
// 它一直没被任何用例覆盖 —— QA 变异验证时把 `!a.isLocked` 删掉（变异 Y），
// 整个 `test/core/network` 110 条全绿，说明这是一处**零覆盖的防御判据**。
//
// 本文件把设计意图钉住（见 fallback_interceptor.dart 里 hasNextHop 注释的第 3 条
// 「备线被锁定（isLocked）」）：
//   * 备线 ok 且**未锁定** → 有备线 → 预算 1 → a 上只打 2 次；
//   * 备线 ok 但**已锁定** → 等同无备线 → 预算 3 → a 上打 4 次。
// 两条用例成对出现：只有控制组也在同一文件里，才能证明「4 vs 2」的差异确实
// 来自 isLocked，而不是来自别的分支。
//
// 用固定地址池而不是真 AddressPool：需要精确给出「活跃地址未锁定 + 另一条
// 地址已锁定」这一状态，而真实池的公开 API 会把它改写掉（见上）。

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
  int requestCount = 0;
  final List<String> requested = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestCount++;
    requested.add('${options.method} ${options.uri}');
    return handler(options);
  }
}

/// 固定池：`addresses` / `activeAddress` / `getNextAvailable` 全部可控。
///
/// `getNextAvailable()` 恒返回 null 是刻意的 —— 本文件只测「预算分档」，
/// 要让请求在重试耗尽后**直接放弃**（不进第 6 步切线路），把断言隔离在
/// 「同地址打了几次」上。
class _FixedPool extends AddressPool {
  _FixedPool(super.dio, this.entries);

  final List<ServerAddress> entries;

  @override
  List<ServerAddress> get addresses => List.unmodifiable(entries);

  @override
  ServerAddress? get activeAddress => entries.isEmpty ? null : entries.first;

  @override
  ServerAddress? getNextAvailable() => null;
}

ResponseBody _okBody([String body = '{"ok":true}']) => ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

DioException _connErr(RequestOptions options) => DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: Exception('connection refused'),
    );

ServerAddress _addr(
  String id,
  String url, {
  bool isLocked = false,
  ServerAddressStatus status = ServerAddressStatus.ok,
}) =>
    ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: id,
      url: url,
      priority: 0,
      isLocked: isLocked,
      status: status,
    );

void main() {
  late Dio dio;
  late _StubAdapter adapter;

  setUp(() {
    FallbackInterceptor.resetRetryStateForTest();
    // 只验预算分档，不真等 1s / 2s。
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
    dio = Dio();
    adapter = _StubAdapter((_) async => _okBody());
    dio.httpClientAdapter = adapter;
  });

  tearDown(FallbackInterceptor.resetRetryStateForTest);

  /// 挂拦截器并让「对 a 的读取永远失败」。
  void attach(List<ServerAddress> entries) {
    dio.interceptors.add(FallbackInterceptor(_FixedPool(dio, entries), dio));
    adapter.handler = (options) async => throw _connErr(options);
  }

  test('控制组：备线 ok 且未锁定 → 有备线 → 预算 1（a 上只打 2 次）', () async {
    attach([
      _addr('a', 'https://a.example.com'),
      _addr('b', 'https://b.example.com'),
    ]);

    await expectLater(
      dio.get<String>('/rest/ping'),
      throwsA(isA<DioException>()),
    );

    expect(
      adapter.requestCount,
      2,
      reason: '有健康备线时预算为 1：1 次原始 + 1 次零延时重试，'
          '随后应把时间让给 failover（本用例 getNextAvailable=null，直接放弃）',
    );
  });

  test('备线 ok 但已锁定 → 等同无备线 → 预算 3（a 上打 4 次）', () async {
    attach([
      _addr('a', 'https://a.example.com'),
      _addr('b', 'https://b.example.com', isLocked: true),
    ]);

    await expectLater(
      dio.get<String>('/rest/ping'),
      throwsA(isA<DioException>()),
    );

    expect(
      adapter.requestCount,
      4,
      reason: '被锁定的地址不能被当成「可以切过去的路」（用户锁的是 a，'
          '系统不该为了 b 砍掉 a 的自愈次数）：预算 3 = 1 原始 + 3 次重试。'
          '把 hasNextHop 里的 !a.isLocked 删掉（变异 Y）这条必红',
    );
  });
}
