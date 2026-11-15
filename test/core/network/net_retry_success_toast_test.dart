// 「靠同地址重试自愈的请求，不会在 t=30s 还弹网络异常」行为回归（批 A）。
//
// 为什么单独一个文件：`NetworkErrorNotifier` 的状态全是 **static**
// （`_startedAt` / `_lastShownAt` / `_pendingTimer`），且 `_showNow` 有 20s 节流。
// 同一 isolate 里只要前面的用例真的弹过一次 toast，`_lastShownAt` 就会把本用例
// 里「本该弹出的那一次」节流掉 —— 于是变异（把 cancelPending 全删）时本用例
// **假绿**。flutter test 每个文件独立 isolate，单独成文件即可拿到干净的 static
// 初值，不依赖「放在文件第几个」这种脆弱前提。
// （根治方案是给 notifier 加 `@visibleForTesting static void reset()`，已留批 B。）
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

typedef _Handler = Future<ResponseBody> Function(RequestOptions options);

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  _Handler handler;
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

/// 固定地址池：单地址、始终有 active（绕开 probeAll 的异步探测）。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('同地址重试成功 → 30s 后不弹网络异常（自愈路径的行为断言）',
      (tester) async {
    // toast 宿主：宽限期到点后 toast 会插进 Navigator 的 Overlay，于是可以直接
    // find.byType(MusicFlowMessage) 观测「到底有没有弹」。
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        // MusicFlowMessage 读 AppLocalizations.of(context)!，必须带 delegate。
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    NetworkErrorNotifier.cancelPending();
    NetworkErrorNotifier.markAppStarted();
    NetworkErrorNotifier.show('net-err-probe'); // 宽限期内 → 进「待确认」

    final dio = Dio();
    final adapter = _StubAdapter((options) async {
      // 第一次 = 半开连接失败（请求已发出、对端在响应前断开）；第二次 = 同地址立即重试成功。
      final retried =
          options.extra[FallbackInterceptor.sameAddressRetryCountKey] != null;
      if (!retried) throw _connErr(options);
      return _okBody();
    });
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
    dio.interceptors.add(FallbackInterceptor(pool, dio));
    // attempt 0 零延时，退避钩子压成 0 只是为了万无一失。
    FallbackInterceptor.resetRetryStateForTest();
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
    addTearDown(FallbackInterceptor.resetRetryStateForTest);

    // 必须在真 zone 里跑：testWidgets 的假时钟不推进这条 await 链，
    // attempt 0 那次 `_dio.fetch` 永远等不到结果。
    final response = await tester.runAsync(() => dio.get<String>('/rest/ping'));
    expect(
      response?.statusCode,
      200,
      reason: '重试必须真的走通，否则本用例没测到「重试成功」这个分支',
    );
    expect(adapter.requestCount, 2, reason: '1 次原始失败 + 1 次立即重试');

    // 推过 30s 宽限期：正常（有两处 cancelPending）时不该弹；
    // 把 `onResponse` 与「重试成功」分支两处 cancelPending 全删 → 这里必弹 → 红。
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(
      find.byType(MusicFlowMessage),
      findsNothing,
      reason: '第 2 秒就靠重试自愈了，t=30s 不该弹「网络异常」',
    );
  });
}
