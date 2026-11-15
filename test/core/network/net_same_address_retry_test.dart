// 「外网首屏偶发整屏空白 + 报网络异常」失败路径回归（批 A / 同地址受限重试）。
//
// 钉住三条新语义：
//   1. `onRequest` 在活跃地址为空时也不能带空 baseUrl 派发
//      （空 host → ArgumentError → DioExceptionType.unknown → 不重试 →
//       首屏十几条并发请求瞬间全失败）；
//   2. 连接类错误**首次**即重试（0 / 1s / 2s），不再要求「连续失败 2 次」；
//      receiveTimeout 与显式非幂等请求不重试；
//   3. 重试有界：单条请求最多 1 + 3 次，且全局限流（10s 内最多 12 次重试）。
//
// 全部用自定义 HttpClientAdapter 打桩，不发真网络；退避用 `retryBackoff`
// 钩子压成 0，避免用例真等 1s/2s。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_message.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/data/models/server_address.dart';

typedef _Handler = Future<ResponseBody> Function(RequestOptions options);

/// 可编程适配器：记录每次实际发出的请求，便于断言「重试了几次」。
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

/// 固定地址池：绕开 `setAddresses` 的异步探测，让「有没有活跃地址」完全可控
/// （真实 `AddressPool` 的 probeAll 是 fire-and-forget，会让用例与探测赛跑）。
///
/// 两个计数器是「令牌耗尽仍必须落到第 6 步 failover」这条行为的唯一 oracle：
/// 令牌桶耗尽后，「提前 super.onError 终结」与「结构性掉到第 6 步」发出的
/// **请求数完全一样**（1 原始 + 免令牌的 attempt 0），只数 `requestCount`
/// 永远拦不住那个回退。必须观测第 6 步的两个副作用。
///
/// `markFailed` 里**必须先 `++` 再 `super`**：本池没有走 `setAddresses`，
/// 父类的 `_addresses` 是空的，会命中 `length <= 1` 的「单地址跳过判死」
/// 守卫直接 return；先记后调才留得下痕迹。
class _FixedPool extends AddressPool {
  _FixedPool(super.dio, this.entries, {this.hasActive = true});

  final List<ServerAddress> entries;
  final bool hasActive;

  /// 第 6 步调用 `_addressPool.markFailed(currentAddress)` 的次数。
  int markFailedCalls = 0;

  /// 第 6 步调用 `getNextAvailable()` 的次数。
  ///
  /// 注意 `onRequest` 的 `active ?? getNextAvailable() ?? first` 在活跃地址
  /// 非空时被 `??` 短路，不会调用；所以 `hasActive: true` 的用例里，这个
  /// 计数器的唯一增长点就是第 6 步。
  int nextAvailableCalls = 0;

  @override
  List<ServerAddress> get addresses => List.unmodifiable(entries);

  @override
  ServerAddress? get activeAddress =>
      hasActive && entries.isNotEmpty ? entries.first : null;

  @override
  void markFailed(ServerAddress addr) {
    markFailedCalls++;
    super.markFailed(addr);
  }

  @override
  ServerAddress? getNextAvailable() {
    nextAvailableCalls++;
    return entries.isEmpty ? null : entries.first;
  }
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

ServerAddress _addr(String id, String url) => ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: id,
      url: url,
      priority: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late _StubAdapter adapter;

  setUp(() {
    // 令牌桶 / 时钟 / 退避都是 static，必须逐用例复位，否则一个用例烧掉的
    // 令牌会让后面的用例莫名「不重试」。
    FallbackInterceptor.resetRetryStateForTest();
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
    // NetworkErrorNotifier 也是 static 状态，逐用例清掉「待确认」残留。
    NetworkErrorNotifier.cancelPending();
    dio = Dio();
    adapter = _StubAdapter((_) async => _okBody());
    dio.httpClientAdapter = adapter;
  });

  tearDown(() {
    FallbackInterceptor.resetRetryStateForTest();
  });

  /// 最近一次 [attachSingle] 建出来的池，供用例读取第 6 步的计数器。
  late _FixedPool lastPool;

  /// 挂上拦截器并返回它（单地址池，active = 该地址）。
  FallbackInterceptor attachSingle({
    bool hasActive = true,
    String url = 'https://only.example.com',
  }) {
    final pool = _FixedPool(
      dio,
      [_addr('only', url)],
      hasActive: hasActive,
    );
    lastPool = pool;
    final interceptor = FallbackInterceptor(pool, dio);
    dio.interceptors.add(interceptor);
    return interceptor;
  }

  group('改动 4：成功响应取消「待确认」的网络异常提示', () {
    // 这两个用例刻意放在文件最前面：NetworkErrorNotifier 的 `_startedAt` 是
    // static 且只由 markAppStarted 的 `??=` 设置，「宽限期内」这个前提依赖
    // 「距首次 markAppStarted 的真实时间 < 30s」，放最前最稳。
    //
    // 断言的是**真的有没有弹**：挂一个 MaterialApp + rootNavigatorKey 当 toast
    // 宿主，宽限期到点后 toast 会插进 Navigator 的 Overlay，于是可以直接
    // find.byType(MusicFlowMessage)。不挂宿主时 ToastNotifier 只把消息塞进私有
    // _pendingMessage，外部无从观测 —— 这也正是这条路径此前零覆盖的原因。
    //
    // ⚠️ 后人在本文件（或同 isolate 的任何用例）里再加 notifier 用例时，必须先
    // 调 NetworkErrorNotifier.cancelPending()：`_startedAt` 是 static，跑过这里
    // 之后本 isolate 内任何 show() 都会走「待确认」而非立即弹（setUp 已兜了一层，
    // 但同文件内新增 group 时别依赖它）。
    Future<void> mountToastHost(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            // toast 内的 MusicFlowMessage 会读 AppLocalizations.of(context)
            // （空安全 `!`），所以宿主必须带上本地化 delegate，否则插入即崩。
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        );

    testWidgets('任一请求成功即 cancelPending：宽限期到点也不弹', (tester) async {
      await mountToastHost(tester);
      NetworkErrorNotifier.cancelPending();
      NetworkErrorNotifier.markAppStarted();
      NetworkErrorNotifier.show('net-err-probe'); // 宽限期内 → 进「待确认」

      // 直接驱动 onResponse（等价于「一次请求成功」）：testWidgets 的
      // fake-async 里 `await dio.get(...)` 不会自然完成（微任务不被推进），
      // 而这里要钉的就是 onResponse 里那一行，直调更稳也没有引入 flake 的空间。
      final interceptor = attachSingle();
      interceptor.onResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(path: '/rest/ping'),
          statusCode: 200,
          data: '{"ok":true}',
        ),
        ResponseInterceptorHandler(),
      );

      // 推过 30s 宽限期：若 onResponse 没调 cancelPending，这里就会弹。
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();

      expect(
        find.byType(MusicFlowMessage),
        findsNothing,
        reason: '删掉 onResponse 里的 cancelPending() 这条必红',
      );
    });

    testWidgets('反向对照：不喂成功响应 → 31s 后确实弹出', (tester) async {
      await mountToastHost(tester);
      NetworkErrorNotifier.cancelPending();
      NetworkErrorNotifier.markAppStarted();
      NetworkErrorNotifier.show('net-err-probe');

      await tester.pump(const Duration(seconds: 31));
      await tester.pump();

      expect(
        find.byType(MusicFlowMessage),
        findsOneWidget,
        reason: '不取消就一定会弹；这条绿了，上面那条的 findsNothing 才有意义',
      );
      // 让 toast 自己的 3s 自动消失计时走完，别给下一条留下 pending timer。
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('onRequest：空 baseUrl 兜底', () {
    test('activeAddress 为空且池内有地址 → baseUrl 被补成该地址', () {
      final interceptor = attachSingle(hasActive: false);
      final options = RequestOptions(path: '/rest/ping');
      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(
        options.baseUrl,
        'https://only.example.com',
        reason: '活跃地址为空时必须退一步用池内地址，否则 Uri 无 host',
      );
    });

    test('池内地址带尾斜杠 → 归一化去掉（避免拼出 //rest/...）', () {
      final interceptor = attachSingle(
        hasActive: false,
        url: 'https://only.example.com/',
      );
      final options = RequestOptions(path: '/rest/ping');
      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(options.baseUrl, 'https://only.example.com');
    });

    test('池为空 → 保持空 baseUrl（不伪造地址）', () {
      final pool = _FixedPool(dio, <ServerAddress>[], hasActive: false);
      final interceptor = FallbackInterceptor(pool, dio);
      final options = RequestOptions(path: '/rest/ping');
      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(options.baseUrl, isEmpty);
    });

    test('端到端：无活跃地址时请求仍发往池内地址（不再抛 unknown 且不重试）',
        () async {
      attachSingle(hasActive: false);
      final response = await dio.get<String>('/rest/ping');
      expect(response.statusCode, 200);
      expect(
        adapter.requested.single,
        contains('only.example.com'),
        reason: '空 baseUrl 会让请求根本没有 host',
      );
    });
  });

  group('同地址受限重试', () {
    test('首次连接错误即重试，第二次成功（不再需要失败 2 次）', () async {
      attachSingle();
      var calls = 0;
      adapter.handler = (options) async {
        calls++;
        if (calls == 1) throw _connErr(options);
        return _okBody();
      };

      final response = await dio.get<String>('/rest/ping');

      expect(response.statusCode, 200);
      expect(calls, 2, reason: '1 次原始失败 + 1 次立即重试');
    });

    test('非幂等请求（allowRetryExtraKey == false）不重试', () async {
      attachSingle();
      adapter.handler = (options) async => throw _connErr(options);

      await expectLater(
        dio.get<String>(
          '/rest/ping',
          options: Options(
            extra: {FallbackInterceptor.allowRetryExtraKey: false},
          ),
        ),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requestCount, 1, reason: '非幂等请求重放有副作用，必须打住');
    });

    test('receiveTimeout 不重试（请求可能已被服务端处理完）', () async {
      attachSingle();
      adapter.handler = (options) async => throw DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          );

      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requestCount, 1);
    });

    test('退避调度按 0 / 1 / 2 三次，重试 3 次仍失败后抛错（有界不递归）', () async {
      attachSingle();
      final seenAttempts = <int>[];
      FallbackInterceptor.retryBackoff = (attempt) {
        seenAttempts.add(attempt);
        return Duration.zero; // 只验调度，不真等
      };
      adapter.handler = (options) async => throw _connErr(options);

      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );

      expect(seenAttempts, [0, 1, 2], reason: '最多 3 次重试，attempt 依次递增');
      expect(
        adapter.requestCount,
        4,
        reason: '1 次原始 + 3 次重试；单地址无下一跳，到此为止',
      );
    });

    test('默认退避策略：0 / 1s / 2s', () {
      expect(
        FallbackInterceptor.defaultRetryBackoff(0),
        Duration.zero,
        reason: '首次重试必须立刻发：要救的是「请求已发出、对端在响应前断开」的'
            '半开连接，重发一次即自愈',
      );
      expect(
        FallbackInterceptor.defaultRetryBackoff(1),
        const Duration(seconds: 1),
      );
      expect(
        FallbackInterceptor.defaultRetryBackoff(2),
        const Duration(seconds: 2),
      );
    });
  });

  group('重试令牌桶', () {
    // 账目（单地址 = 无备线 → 预算 3；attempt 0 零延时免令牌，attempt 1/2 各 1 枚）：
    //   每条逻辑请求 = 1 原始 + 3 重试 = 4 次请求，消耗 2 枚令牌。
    //   12 枚 ÷ 2 = 6 条请求把窗口用满。
    test('延时重试超 12 枚后不再重试（attempt 0 仍免令牌）', () async {
      attachSingle();
      // 固定时钟 → 窗口内的令牌永不过期，用例无需真等 10s。
      final frozen = DateTime(2026, 1, 1, 12);
      FallbackInterceptor.retryClock = () => frozen;
      adapter.handler = (options) async => throw _connErr(options);

      for (var i = 0; i < 6; i++) {
        await expectLater(
          dio.get<String>('/rest/ping'),
          throwsA(isA<DioException>()),
        );
      }
      expect(adapter.requestCount, 24, reason: '6 条 × (1 原始 + 3 重试)');

      final before = adapter.requestCount;
      // 第 6 步的 oracle：令牌耗尽后必须**结构性掉到第 6 步 failover**。
      // 把 `retryAllowed = false;` 换成 `super.onError(err, handler); return;`
      // （旧的「令牌耗尽就提前终结」）时，这一条会变 0 —— 而 requestCount
      // 差值仍是 2，只数请求数永远抓不到。
      final markFailedBefore = lastPool.markFailedCalls;
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(
        adapter.requestCount - before,
        2,
        reason: '令牌耗尽后只剩「原始请求 + 免令牌的 attempt 0」，延时波不再发',
      );
      expect(
        lastPool.markFailedCalls - markFailedBefore,
        1,
        reason: '令牌耗尽必须掉到第 6 步才会 markFailed；提前终结时该增量为 0',
      );
    });

    test('窗口滑过后令牌恢复', () async {
      attachSingle();
      var frozen = DateTime(2026, 1, 1, 12);
      FallbackInterceptor.retryClock = () => frozen;
      adapter.handler = (options) async => throw _connErr(options);

      for (var i = 0; i < 6; i++) {
        await expectLater(
          dio.get<String>('/rest/ping'),
          throwsA(isA<DioException>()),
        );
      }
      // 把时钟推过 10s 窗口 → 旧时间戳全部过期，令牌重新可用。
      frozen = frozen.add(const Duration(seconds: 11));
      final before = adapter.requestCount;
      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );
      expect(
        adapter.requestCount - before,
        4,
        reason: '窗口滑过后应恢复重试能力（1 原始 + 3 重试）',
      );
    });

    test('14 条并发同时撞上半开连接：attempt 0 免令牌 → 14 条全部自愈且不放大',
        () async {
      attachSingle();
      // 冻结时钟：即便发生「把 attempt 0 也计入令牌桶」的回退，12 枚令牌也不会
      // 因时间流逝而复活，回退能被稳定拦住。
      final frozen = DateTime(2026, 1, 1, 12);
      FallbackInterceptor.retryClock = () => frozen;
      // 每条请求的「首次尝试」失败（extra 里还没写重试计数），重试即成功。
      // 这正是「14 条首屏请求同时撞上半开连接（请求已发出、响应前断开）」的形状。
      adapter.handler = (options) async {
        final alreadyRetried =
            options.extra[FallbackInterceptor.sameAddressRetryCountKey] != null;
        if (!alreadyRetried) throw _connErr(options);
        return _okBody();
      };

      final results = await Future.wait(
        List<Future<int>>.generate(
          14,
          (_) => dio
              .get<String>('/rest/ping')
              .then((r) => r.statusCode ?? 0)
              .catchError((Object _) => -1),
        ),
      );

      expect(
        results,
        everyElement(200),
        reason: '14 条都必须靠 attempt 0 那次免令牌的立即重试自愈 —— '
            '把 attempt 0 也计入令牌桶时，12 枚只够 12 条，必有 2 条失败',
      );
      expect(
        adapter.requestCount,
        28,
        reason: '14 原始 + 14 次立即重试。回退后会变成 26（只放出 12 次重试）',
      );
    });
  });

  group('令牌耗尽必须结构性落到第 6 步 failover', () {
    // 这条钉的是 fallback_interceptor.dart 里 `retryAllowed` 这个条件式重试
    // 骨架的设计意图：令牌耗尽时**不要** `super.onError` 提前终结，而要顺着
    // 控制流掉到第 6 步 failover。
    //
    // 为什么已有的令牌桶用例拦不住回退：改成 `super.onError(err, handler);
    // return;` 之后，发出去的请求数**完全一样**（1 原始 + 免令牌的 attempt 0），
    // `requestCount` 差值仍是 2，仅凭请求数无法区分。真正的分叉在「有没有
    // 进第 6 步」—— 所以必须观测 markFailed / getNextAvailable 这两个副作用。
    test('多地址池无健康备线 + 令牌耗尽 → 仍调用 markFailed 并询问下一跳', () async {
      final pool = _FixedPool(dio, <ServerAddress>[
        _addr('a', 'https://a.example.com'),
        // 备线存在但 status 是 unknown（不是 ok）→ hasNextHop == false，
        // 于是预算给满 3 次（这是外网「单一反代地址」形态的等价条件），
        // 且第 6 步走「找不到下一跳」这条可控分支。
        _addr('b', 'https://b.example.com'),
      ]);
      dio.interceptors.add(FallbackInterceptor(pool, dio));

      // 冻结时钟：12 枚令牌不会因时间流逝自然回填，耗尽态可稳定复现。
      final frozen = DateTime(2026, 1, 1, 12);
      FallbackInterceptor.retryClock = () => frozen;
      adapter.handler = (options) async => throw _connErr(options);

      // 6 条 × 2 枚（attempt 1 / attempt 2 各 1 枚）= 12 枚，把窗口打空。
      for (var i = 0; i < 6; i++) {
        await expectLater(
          dio.get<String>('/rest/ping'),
          throwsA(isA<DioException>()),
        );
      }
      expect(adapter.requestCount, 24, reason: '6 条 × (1 原始 + 3 重试)');

      final markBefore = pool.markFailedCalls;
      final nextBefore = pool.nextAvailableCalls;
      final reqBefore = adapter.requestCount;

      await expectLater(
        dio.get<String>('/rest/ping'),
        throwsA(isA<DioException>()),
      );

      expect(
        adapter.requestCount - reqBefore,
        2,
        reason: '令牌耗尽后只剩「原始请求 + 免令牌的 attempt 0」',
      );
      expect(
        pool.markFailedCalls - markBefore,
        1,
        reason: '令牌耗尽必须掉到第 6 步 failover 才会 markFailed；'
            '改成 super.onError 提前终结时该计数为 0（变异 eagerabort）',
      );
      expect(
        pool.nextAvailableCalls - nextBefore,
        1,
        reason: '只有落到第 6 步才会问「有没有下一跳」；提前终结时一次都不问',
      );
    });
  });
}
