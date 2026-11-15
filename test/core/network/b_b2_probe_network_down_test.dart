// 批 B2 · 时间收口（前半）：T4 探测加速限速 / T5 断网不重试。
//
// T4 要防的是「失败风暴变成探测风暴」：首屏 14 条请求同时失败，绝不能变成
// 14 次全量探测（双地址 = 28 个 HEAD）。三重限速都要能被观测到：
//   1. 只探一条；2. 全池 5s 内最多 1 次；3. 上一次未结束直接跳过。
//
// T5 要防的是「断网时白等 + 烧令牌」：无路由下 SocketException 是即时的，
// 1s/2s 两波延时重试纯粹白等，还会把 12 枚令牌吃光（挤掉 10s 内真正需要
// 的那次重试）。**attempt 0 必须保留**，否则 Windows 端 connectivity 误报
// 会把自愈能力整体砍掉。

import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/data/models/server_address.dart';

typedef _Handler = Future<ResponseBody> Function(RequestOptions options);

/// 可编程适配器：同时用于探测（HEAD）与业务请求（GET）。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  _Handler handler;
  int requestCount = 0;
  int headCount = 0;
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
    if (options.method == 'HEAD') headCount++;
    requested.add('${options.method} ${options.uri}');
    return handler(options);
  }
}

ResponseBody _okBody() => ResponseBody.fromString(
      '{"ok":true}',
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
  String id, {
  ServerAddressStatus status = ServerAddressStatus.ok,
  bool isLocked = false,
  int priority = 0,
}) =>
    ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: id,
      url: 'https://$id.example.com',
      priority: priority,
      isLocked: isLocked,
      status: status,
    );

/// 固定地址池：绕开 `setAddresses` 的异步探测，让「有几条备线」完全可控。
class _FixedPool extends AddressPool {
  _FixedPool(super.dio, this.entries);

  final List<ServerAddress> entries;

  @override
  List<ServerAddress> get addresses => List.unmodifiable(entries);

  @override
  ServerAddress? get activeAddress => entries.isEmpty ? null : entries.first;

  @override
  ServerAddress? getNextAvailable() => entries.isEmpty ? null : entries.first;
}

void main() {
  group('T4 probeActiveThrottled 三重限速', () {
    late Dio dio;
    late _StubAdapter adapter;
    late Duration savedInterval;

    setUp(() {
      savedInterval = AddressPool.onDemandProbeInterval;
      AddressPool.onDemandProbeInterval = const Duration(seconds: 5);
      dio = Dio();
      adapter = _StubAdapter((_) async => _okBody());
      dio.httpClientAdapter = adapter;
    });

    tearDown(() {
      AddressPool.onDemandProbeInterval = savedInterval;
    });

    test('同一窗口内两次调用 → probeAddress 只跑 1 次', () async {
      final pool = AddressPool(dio);
      pool.setAddresses([_addr('a')]);
      await pumpEventQueue(); // 排空 setAddresses 触发的 probeAll
      adapter.headCount = 0;

      await pool.probeActiveThrottled();
      await pool.probeActiveThrottled();

      expect(
        adapter.headCount,
        1,
        reason: '5s 窗口内第二次必须被 _lastOnDemandProbeAt 挡住',
      );
    });

    test('窗口滑过后第二次生效', () async {
      final pool = AddressPool(dio);
      pool.setAddresses([_addr('a')]);
      await pumpEventQueue();
      adapter.headCount = 0;

      await pool.probeActiveThrottled();
      AddressPool.onDemandProbeInterval = Duration.zero; // 等价于「窗口已滑过」
      await pool.probeActiveThrottled();

      expect(adapter.headCount, 2);
    });

    test('单次失败后 status 仍是 ok（宽容：不因一条请求失败就判死）', () async {
      final pool = AddressPool(dio);
      pool.setAddresses([_addr('a')]);
      await pumpEventQueue();
      expect(pool.addresses.single.status, ServerAddressStatus.ok);

      adapter.handler = (options) async => throw _connErr(options);
      await pool.probeActiveThrottled();

      expect(
        pool.addresses.single.status,
        ServerAddressStatus.ok,
        reason: '一次失败只把状态推向 suspect，failed 要连续 2 次才给',
      );
    });

    test('14 条并发失败 → HEAD 总数 ≤ 2（防风暴硬判据）', () async {
      final pool = AddressPool(dio);
      pool.setAddresses([_addr('a')]);
      await pumpEventQueue();
      adapter.headCount = 0;
      adapter.handler = (options) async => throw _connErr(options);

      // 首屏 14 条请求同时失败 → 14 次 probeActiveThrottled 并发。
      await Future.wait(
        List<Future<void>>.generate(14, (_) => pool.probeActiveThrottled()),
      );

      expect(
        adapter.headCount,
        lessThanOrEqualTo(2),
        reason: '若改成在失败路径上 probeAll()，这里会是 14 或 28',
      );
    });

    test('空地址池 → 不探测、不抛异常', () async {
      final pool = AddressPool(dio);
      await pool.probeActiveThrottled();
      expect(adapter.headCount, 0);
    });
  });

  group('T5 断网不重试（attempt 0 保留）', () {
    late Dio dio;
    late _StubAdapter adapter;

    setUp(() {
      FallbackInterceptor.resetRetryStateForTest();
      FallbackInterceptor.retryBackoff = (_) => Duration.zero;
      dio = Dio();
      adapter = _StubAdapter((options) async => throw _connErr(options));
      dio.httpClientAdapter = adapter;
    });

    tearDown(FallbackInterceptor.resetRetryStateForTest);

    test('断网 + 单地址 → 不发延时重试波，且不消耗令牌', () async {
      final pool = _FixedPool(dio, [_addr('a')]);
      pool.isNetworkDown = true;
      dio.interceptors.add(FallbackInterceptor(pool, dio));

      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );

      // 计数口径说明：`attempt` 是**重试序号**，`attempt == 0` 指的是那条
      // 零延时重试本身，不是原始请求。所以「保留 attempt 0」= 原始 1 次 +
      // 立即重试 1 次 = 2 次；被砍掉的是 attempt 1/2 两波延时重试（共 4 次 → 2 次）。
      expect(
        adapter.requestCount,
        2,
        reason: '断网时只砍 1s/2s 两波延时重试，零延时的 attempt 0 必须保留',
      );
      expect(
        FallbackInterceptor.retryTokensUsedForTest,
        0,
        reason: '`isNetworkDown ||` 短路必须在取令牌之前返回，断网不得烧令牌',
      );
    });

    test('未断网 → 与批 A 完全一致（单地址 4 次）', () async {
      final pool = _FixedPool(dio, [_addr('a')]);
      expect(pool.isNetworkDown, isFalse, reason: '默认必须是 false');
      dio.interceptors.add(FallbackInterceptor(pool, dio));

      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.requestCount, 4, reason: '1 原始 + 3 次重试（无备线 → 预算 3）');
      // attempt 0 免令牌，只有 attempt 1/2 各取 1 枚。
      expect(FallbackInterceptor.retryTokensUsedForTest, 2);
    });

    test('断网 + 有健康备线（预算 1）→ 仍是 2 次', () async {
      final pool = _FixedPool(
        dio,
        [_addr('a'), _addr('b', priority: 1)],
      );
      pool.isNetworkDown = true;
      dio.interceptors.add(FallbackInterceptor(pool, dio));

      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );

      expect(
        adapter.requestCount,
        2,
        reason: '预算 1 那一档走的是 attempt 0（零延时），不该被断网判定砍掉',
      );
      expect(FallbackInterceptor.retryTokensUsedForTest, 0);
    });
  });

  group('T5 ConnectivityMonitor → AddressPool.isNetworkDown', () {
    test('none → true；wifi / mobile → false；重复上报也同步', () {
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((_) async => _okBody());
      final pool = AddressPool(dio);
      final monitor = ConnectivityMonitor(pool);
      addTearDown(monitor.stop);

      expect(pool.isNetworkDown, isFalse, reason: '构造后默认 false');

      ConnectivityMonitor.applyNetworkTypeForTest(monitor, <ConnectivityResult>[ConnectivityResult.none]);
      expect(pool.isNetworkDown, isTrue);

      ConnectivityMonitor.applyNetworkTypeForTest(monitor, <ConnectivityResult>[ConnectivityResult.wifi]);
      expect(pool.isNetworkDown, isFalse);

      // 「类型没变也要写」：连发两次 wifi 后再断网，必须仍然翻成 true。
      ConnectivityMonitor.applyNetworkTypeForTest(monitor, <ConnectivityResult>[ConnectivityResult.wifi]);
      ConnectivityMonitor.applyNetworkTypeForTest(monitor, <ConnectivityResult>[ConnectivityResult.none]);
      expect(
        pool.isNetworkDown,
        isTrue,
        reason: '同步语句若被放进「类型变化」分支里，这里会漏',
      );

      ConnectivityMonitor.applyNetworkTypeForTest(monitor, <ConnectivityResult>[ConnectivityResult.mobile]);
      expect(pool.isNetworkDown, isFalse);
    });
  });
}
