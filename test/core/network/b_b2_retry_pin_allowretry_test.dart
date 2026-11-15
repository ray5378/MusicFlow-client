// 批 B 补的两个「变异打空」守卫。
//
// 背景：批 A 的 13 个变异里有两个（`_retryBudgetExtraKey` 钉帧、非幂等早退）
// 在批 B 重打后**没有用例能拦住**——不是批 B 改坏了它们，而是原先就没有
// 任何用例落在那个判据上（旧文件只断言「切到 b 了」，不数 b 上打了几次）。
// 这两条是真实的生产行为，必须有用例钉住：
//
//   * 钉帧：预算只在「本次逻辑请求的首个失败帧」算一次。切线路之后原线路
//     变成 failed，若每帧重算，`hasNextHop` 会翻成 false、预算从 1 抬回 3，
//     刚切过去的备线又被重试 3 次 —— 一次故障被放大成 1+4 次。
//   * 非幂等早退：`allowFallbackRetry == false`（如 scrobble 上报）必须
//     一次都不重试、也不切线路，否则播放次数会被重放放大。

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
  int requestCount = 0;
  final List<String> requested = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    requested.add('${options.method} ${options.uri.host}');
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

int _getCount(_StubAdapter adapter, String host) => adapter.requested
    .where((r) => r.startsWith('GET') && r.endsWith(host))
    .length;

/// 总 GET 数（不含探测用的 HEAD —— `requestCount` 把两者混在一起了）。
int _totalGets(_StubAdapter adapter) =>
    adapter.requested.where((r) => r.startsWith('GET')).length;

void main() {
  // 切换成功 / 失败兜底会走 ToastNotifier.show（读 rootNavigatorKey），
  // 需要已初始化的 WidgetsBinding。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late _StubAdapter adapter;
  late AddressPool pool;

  ServerAddress makeAddr(String id, String url, int priority) => ServerAddress(
        id: id,
        libraryId: 'lib-1',
        label: id,
        url: url,
        priority: priority,
      );

  /// 双地址全 ok 的池（HEAD 永远成功 → switchTo 能走通）。
  Future<void> buildPool() async {
    pool = AddressPool(dio);
    dio.interceptors.clear();
    dio.interceptors.add(FallbackInterceptor(pool, dio));
    pool.setAddresses([
      makeAddr('a', 'https://a.example.com', 0),
      makeAddr('b', 'https://b.example.com', 1),
    ]);
    await pool.probeAll();
  }

  setUp(() {
    FallbackInterceptor.resetRetryStateForTest();
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
    dio = Dio();
    adapter = _StubAdapter((_) async => _okBody());
    dio.httpClientAdapter = adapter;
  });

  tearDown(FallbackInterceptor.resetRetryStateForTest);

  test('预算钉在首个失败帧：切到备线后不得把 3 次预算重新抬起来', () async {
    await buildPool();
    // HEAD 仍成功（switchTo 能通过），所有 GET 都失败。
    adapter.handler = (options) async {
      if (options.method == 'HEAD') return _okBody();
      throw _connErr(options);
    };

    await expectLater(
      dio.get<String>('/rest/ping'),
      throwsA(isA<DioException>()),
    );

    expect(
      _getCount(adapter, 'a.example.com'),
      2,
      reason: '有健康备线 → 预算 1：a 上 1 次原始 + 1 次零延时重试',
    );
    expect(
      _getCount(adapter, 'b.example.com'),
      1,
      reason: '备线上的重放不该再重试：删掉 _retryBudgetExtraKey 钉帧后这里是 4'
          '（重算 hasNextHop → a 已 failed → 预算抬回 3）',
    );
  });

  test('非幂等请求（allowFallbackRetry=false）一次都不重试、也不切线路', () async {
    await buildPool();
    adapter.handler = (options) async {
      if (options.method == 'HEAD') return _okBody();
      throw _connErr(options);
    };

    await expectLater(
      dio.get<String>(
        '/rest/scrobble',
        options: Options(
          extra: <String, dynamic>{
            FallbackInterceptor.allowRetryExtraKey: false,
          },
        ),
      ),
      throwsA(isA<DioException>()),
    );

    expect(
      _totalGets(adapter),
      1,
      reason: '重放 POST/上报类请求会放大副作用（播放次数），必须原样失败',
    );
    expect(_getCount(adapter, 'a.example.com'), 1);
    expect(
      _getCount(adapter, 'b.example.com'),
      0,
      reason: '放弃自动重放同样意味着不切线路重放',
    );
  });
}
