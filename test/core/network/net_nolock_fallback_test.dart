// net_nolock_fallback_test.dart —— 「同地址重试成功」分支里那行
// `NetworkErrorNotifier.cancelPending()` 是不是真兜底？
//
// 背景：这行一度被注释成「删掉全仓仍全绿、架构性不可拦」，于是下一个人很容易
// 把它当冗余删掉。QA 用一把**不走拦截器链**的 Dio 替身推翻了这个论断，本文件
// 就是那个探针的正式版。
//
// 为什么常规用例拦不住这个删除：
//   重试走的是 `_dio.fetch(options)`。当 `_dio` 是挂了本拦截器的真 Dio 时，
//   这次 fetch 会重新进拦截器链，于是**内层 onResponse 也会 cancelPending**
//   （`fallback_interceptor.onResponse` 里那一次）。两处互为冗余，删掉重试
//   成功分支那一行，行为表面不变 —— 常规套件因此全绿。
//
// 本文件的打法：给 `FallbackInterceptor` 传一个 `implements Dio` 且**只实现
// `fetch`** 的替身（其余走 noSuchMethod 抛错），把拦截器链整个绕开。此时
// 「重试成功」分支那一行就是这条路径**唯一**的取消来源：
//   保留 → 30s 宽限期到点不弹；
//   删掉 → 30s 宽限期到点必弹（变异 nolock295）。
//
// 关于「没弹」会不会是断言写坏导致的假绿：本文件所用的 toast 宿主 + 30s
// 宽限期的可观测性，由 `net_same_address_retry_test.dart` 的
// 「反向对照：不喂成功响应 → 31s 后确实弹出」独立证明（那条断言 findsOneWidget）。
// 反向对照刻意不搬进本文件 —— `NetworkErrorNotifier._startedAt` 与
// `ToastNotifier` 的自动消失计时器都是 static 且没有重置 API，同文件两条用例
// 必然互相污染：实测把对照放前面会让主用例收不到自己的 toast（假绿），
// 放后面又会被失败的主用例残留计时器吃掉（假红）。跨文件则天然隔离
// （flutter test 每个测试文件一个 isolate）。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_message.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 不走拦截器链的 Dio 替身：`fetch` 直接返回成功响应，绝不触发任何
/// onRequest / onResponse / onError。
///
/// 这正是源码注释里自陈的风险场景 ——「不该依赖『fetch 会走拦截器链』这个
/// dio 内部实现细节」—— 的最小复现。
class _NoChainDio implements Dio {
  int fetchCount = 0;

  @override
  Future<Response<T>> fetch<T>(RequestOptions requestOptions) async {
    fetchCount++;
    return Response<T>(
      requestOptions: requestOptions,
      statusCode: 200,
      data: '{"ok":true}' as T,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_NoChainDio 只实现 fetch');
}

/// 可编程适配器：记录真实发出的请求数，便于断言「重试到底有没有发生」。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  Future<ResponseBody> Function(RequestOptions) handler;
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

/// 固定单地址池：绕开 `setAddresses` 的异步探测。
class _SinglePool extends AddressPool {
  _SinglePool(super.dio, this.entry);

  final ServerAddress entry;

  @override
  List<ServerAddress> get addresses => <ServerAddress>[entry];

  @override
  ServerAddress? get activeAddress => entry;

  @override
  ServerAddress? getNextAvailable() => entry;
}

DioException _connErr(RequestOptions options) => DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: Exception('connection reset by peer'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 令牌桶 / 时钟 / 退避都是 static，逐用例复位，避免跨用例污染。
    FallbackInterceptor.resetRetryStateForTest();
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
    NetworkErrorNotifier.cancelPending();
  });

  tearDown(FallbackInterceptor.resetRetryStateForTest);

  testWidgets('重试成功分支的 cancelPending 是「fetch 不走拦截器链」时唯一的取消来源',
      (tester) async {
    // toast 宿主：宽限期到点后 toast 会插进 Navigator 的 Overlay，于是可以
    // 直接用 find.byType(MusicFlowMessage) 观测「到底有没有弹」。
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        // MusicFlowMessage 读 AppLocalizations.of(context)!，必须带 delegate。
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    // 进「宽限期内的待确认」状态：markAppStarted 之后再 show，30s 内不弹，
    // 只有 cancelPending 能把它撤掉。
    NetworkErrorNotifier.markAppStarted();
    NetworkErrorNotifier.show('net-err-probe');

    final dio = Dio();
    final adapter = _StubAdapter((options) async => throw _connErr(options));
    dio.httpClientAdapter = adapter;

    final pool = _SinglePool(
      dio,
      ServerAddress(
        id: 'only',
        libraryId: 'lib-1',
        label: 'only',
        url: 'https://only.example.com',
        priority: 0,
      ),
    );
    // 关键：拦截器内部 `_dio.fetch` 用的是「不走拦截器链」的替身。
    final innerDio = _NoChainDio();
    dio.interceptors.add(FallbackInterceptor(pool, innerDio));

    // `await dio.get` 在 testWidgets 的 fake-async 里不会自然完成，用 runAsync
    // 把它放到真实事件循环上跑。
    final response = await tester.runAsync(() => dio.get<String>('/rest/ping'));

    // 前置条件：重试必须真的走通，否则下面「没弹」就不是 cancelPending 的功劳。
    expect(
      response?.statusCode,
      200,
      reason: '前置条件：首次半开连接失败 → 同地址立即重试 → 必须成功',
    );
    expect(
      adapter.requestCount,
      1,
      reason: '前置条件：只有首次原始请求落到真实 adapter 上；重试走的是 fetch 替身',
    );
    expect(
      innerDio.fetchCount,
      1,
      reason: '前置条件：重试确实走了 fetch 替身（即确实绕开了拦截器链）',
    );

    // 推过 30s 宽限期：若重试成功分支没调 cancelPending，这里就会弹。
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();

    expect(
      find.byType(MusicFlowMessage),
      findsNothing,
      reason: 'fetch 不走拦截器链时，唯一能取消待确认提示的就是「重试成功」'
          '分支那一行 cancelPending —— 删掉它这里必弹（变异 nolock295）',
    );
  });
}
