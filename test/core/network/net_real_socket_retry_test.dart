// net_real_socket_retry_test.dart —— 批 A「同地址受限重试」的**真实 socket** 回归。
//
// 为什么必须另开一份文件：
//   `b34b_*` / `b38b3_*` / `b50c_*` / `net_same_address_retry_test.dart` 全部用
//   `_StubAdapter`（mock `HttpClientAdapter`）打桩，请求根本不落到 `dart:io`。
//   而批 A 要救的是「请求已经发到线上、对端在给出响应前断开」的**半开连接**
//   （服务端 keep-alive 超时与客户端不同步、反代重启、NAT 表项老化都会造成），
//   这个形态只存在于真实 TCP socket 上（`_StubAdapter` 里没有连接、没有半开
//   连接、没有 EOF/RST），所以那四份用例再绿也证明不了它。
//
// 本文件起真实 `HttpServer`（loopback），走真实 `IOHttpClientAdapter`，断言：
//   S1 半开连接（对端在给出响应前断开）→ 最终成功；
//   S2 对端收到请求后暴力掐断 → 按规则重试，重试后成功；
//   S3 非幂等请求遇到 S2 → 只打 1 次、直接抛错；
//   S4 14 条并发 + 对前 N 条连接 destroy → 成功率 / 请求总量 / 令牌桶。
//
// 注意 `HttpOverrides`：`flutter_test` 默认把 `HttpClient` 换成「一律 400」的
// mock（见 flutter_test/src/binding.dart 的 `_MockHttpOverrides`）。本文件要的
// 正是真实客户端，故在 setUp 里把 `HttpOverrides.global` 置空。

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/data/models/server_address.dart';

typedef _Handler = Future<void> Function(HttpRequest request, int seq);

/// 本地真实 HTTP 服务器。
///
/// 之所以要 `detachSocket`：`HttpServer`/`HttpResponse` 不提供「回完响应但把
/// TCP 连接保留在池里、稍后再掐断」的能力。把 socket 从框架手里
/// 摘出来自己写原始响应字节，就能精确控制连接生命周期 —— 这是复现「半开
/// 连接」形态的唯一可靠手段。
class _LocalServer {
  _LocalServer._(this._server, this._handler) {
    _server.listen(
      (request) => unawaited(_dispatch(request)),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  static Future<_LocalServer> start(_Handler handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _LocalServer._(server, handler);
  }

  final HttpServer _server;
  final _Handler _handler;

  /// 到达服务器的业务请求（按到达顺序），形如 `GET /rest/data`。
  /// `AddressPool` 的探测器是 `HEAD /rest/ping`，不计入。
  final List<String> hits = <String>[];

  /// 每条业务请求所在的 TCP 连接（客户端侧端口）。
  ///
  /// 用来判「客户端是否真的复用了同一条连接」：端口变了 ⇒ 客户端另开了新
  /// 连接（即它自己就把死连接丢弃了），这不是「陈旧连接被复用」的场景。
  final List<int> remotePorts = <int>[];

  /// 已回完响应、但仍保持打开的空闲连接（客户端会把它放进 keep-alive 池）。
  final List<Socket> _idle = <Socket>[];

  /// 客户端在「已回完响应的空闲连接」上又写进来的字节数。
  ///
  /// 这是判定「陈旧连接到底有没有被复用」的直接证据：
  ///   * 0  → 客户端从没往这条死连接里写东西（它自己把连接丢了）；
  ///   * >0 → 客户端真的复用了它（那这条请求必然失败，必须靠重试兜）。
  int get idleBytes => _idleBytes;
  int _idleBytes = 0;

  int get port => _server.port;

  Future<void> _dispatch(HttpRequest request) async {
    try {
      if (request.method == 'HEAD') {
        // 探测请求：直接 200，不进业务统计（否则会把「重试了几次」算错）。
        request.response.statusCode = 200;
        await request.response.close();
        return;
      }
      hits.add('${request.method} ${request.uri.path}');
      remotePorts.add(request.connectionInfo?.remotePort ?? -1);
      await _handler(request, hits.length);
    } catch (_) {
      // 连接被对端 destroy 后再 close 会抛，属预期形态，吞掉即可。
    }
  }

  /// 常规路径：回一条 200 JSON 并正常关闭/复用连接。
  Future<void> ok(HttpRequest request, {String body = '{"ok":true}'}) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  }

  /// 回一条完整 200，但**保持连接打开**（客户端据此把它当可复用空闲连接）。
  Future<void> okKeepAlive(
    HttpRequest request, {
    String body = '{"ok":true}',
  }) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    _idle.add(socket);
    socket.write(
      'HTTP/1.1 200 OK\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: ${body.length}\r\n'
      '\r\n'
      '$body',
    );
    await socket.flush();
    // 挂上监听：若客户端之后又在这条连接上写请求，字节数会被记下来。
    socket.listen(
      (chunk) => _idleBytes += chunk.length,
      onError: (Object _) {},
      onDone: () {},
      cancelOnError: false,
    );
  }

  /// 收下请求但**不返回任何响应**，直接暴力掐断（模拟对端 RST / 隧道中断）。
  Future<void> abort(HttpRequest request) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    socket.destroy();
  }

  /// 掐断全部空闲 keep-alive 连接（模拟服务端 keep-alive 超时回收）。
  void killIdle() {
    for (final socket in _idle) {
      socket.destroy();
    }
    _idle.clear();
  }

  Future<void> close() async {
    killIdle();
    await _server.close(force: true);
  }
}

/// 只做观测的拦截器：统计「请求帧被走了几次」（= Dio 实际发起了几次尝试），
/// 记录原始错误类型，并标注哪些帧是**重试帧**。
///
/// ⚠️ 必须加在 `FallbackInterceptor` **之前**：dio 的 `onError` 链是**正序**
/// 执行（`dio_mixin.dart` 里 `for (final interceptor in interceptors) {
/// future = future.catchError(...) }`），而 `FallbackInterceptor.onError` 会
/// 把错误吃掉（resolve），排在它后面的拦截器永远看不到原始错误。
class _Probe implements Interceptor {
  int attempts = 0;

  /// 带 `musicflow.sameAddressRetryCount` 标记的请求帧 ⇒ 这是一次重试。
  int retryFrames = 0;

  /// 每个重试帧上的「第几次重试」值（1 = attempt 0 的零延时重试；
  /// 2/3 = attempt 1/2 的延时重试，各消耗一枚令牌）。
  final List<int> retryAttempts = <int>[];

  final List<DioExceptionType> rawErrors = <DioExceptionType>[];

  bool get retried => retryFrames > 0;

  /// 延时重试（attempt >= 1）次数 = 消耗令牌桶的次数。
  int get delayedRetries => retryAttempts.where((v) => v >= 2).length;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    attempts++;
    final mark = options.extra[FallbackInterceptor.sameAddressRetryCountKey];
    if (mark is int) {
      retryFrames++;
      retryAttempts.add(mark);
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    rawErrors.add(err.type);
    handler.next(err);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late AddressPool pool;
  late _Probe probe;
  _LocalServer? lastServer;

  /// 起一个真实 Dio + 真实 AddressPool（单条 loopback 地址）+ 真拦截器。
  Future<void> boot(_LocalServer s) async {
    lastServer = s;
    probe = _Probe();
    dio = Dio(
      BaseOptions(
        baseUrl: 'http://127.0.0.1:${s.port}',
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
    // 探测用独立 Dio：`setAddresses` 会 fire-and-forget 一次 probeAll（HEAD
    // /rest/ping），让它走另一个 client，业务请求的 socket 池才干净可控。
    final probeDio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${s.port}'));
    pool = AddressPool(probeDio);
    pool.setAddresses([
      ServerAddress(
        id: 'only',
        libraryId: 'lib',
        label: 'loopback',
        url: 'http://127.0.0.1:${s.port}',
        priority: 0,
        status: ServerAddressStatus.ok,
      ),
    ]);
    // 等探测落定，避免探测与业务请求赛跑（setAddresses 已触发同一次 probeAll）。
    await pool.probeAll();
    dio.interceptors.add(probe);
    dio.interceptors.add(FallbackInterceptor(pool, dio));
  }

  setUp(() {
    // flutter_test 的 mock HttpClient 会把所有请求变成 400，必须摘掉。
    HttpOverrides.global = null;
    // 令牌桶 / 时钟 / 退避是 static 状态，逐用例复位；退避压零避免真等 1s/2s。
    FallbackInterceptor.resetRetryStateForTest();
    FallbackInterceptor.retryBackoff = (_) => Duration.zero;
  });

  tearDown(() async {
    FallbackInterceptor.resetRetryStateForTest();
    await lastServer?.close();
    lastServer = null;
  });

  group('S1 半开连接（对端在响应前断开 · 批 A 主场景）', () {
    late _LocalServer srv;

    Future<_LocalServer> startKeepAliveThenOk() async {
      late _LocalServer s;
      s = await _LocalServer.start((request, seq) async {
        // 第 1 次：回完响应但保持连接打开（客户端会复用）。
        // 第 2 次起：正常回（新连接）。
        if (seq == 1) {
          await s.okKeepAlive(request);
        } else {
          await s.ok(request);
        }
      });
      return s;
    }

    // ⚠️ 结论先行（实测 + SDK 源码双重确认）：
    //   「服务端关掉**空闲** keep-alive 连接 → 客户端复用它 → 请求失败」这个
    //   形态在 dart:io 上**不会发生**。`_HttpClientConnection` 的 socket 挂了
    //   onDone，对端一关就调 `_connectionTarget.connectionClosed(...)`，
    //   把该连接从 `_idle` 池里移除（dart-sdk/lib/_http/http_impl.dart 第
    //   2610~2615 行），下次请求直接开新连接。
    //   所以本 group 的用例**不能**用「跨用例断言必失败」来写 —— 那会写出一条
    //   永远红的假需求。它只能钉住「最终一定能成功」+ 留下「是否真写进了死连接」
    //   的字节证据，供人判断这条真因在 Dart 上到底成不成立。
    test('killIdle 后请求仍成功；若真写进了死连接就必须看到重试（不允许静默失败）',
        () async {
      srv = await startKeepAliveThenOk();
      await boot(srv);

      final first = await dio.get<String>('/rest/data');
      expect(first.statusCode, 200, reason: '前置：第一条请求必须成功');
      expect(srv.hits.length, 1);

      // 给客户端一点时间把这条连接还回 keep-alive 空闲池，再掐断它。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      srv.killIdle();

      final second = await dio.get<String>('/rest/data');
      // ignore: avoid_print
      print('[S1-EVIDENCE] attempts=${probe.attempts} '
          'retryFrames=${probe.retryFrames} '
          'rawErrors=${probe.rawErrors.map((e) => e.name).toList()} '
          'serverHits=${srv.hits.length} remotePorts=${srv.remotePorts} '
          'bytesWrittenToKilledConnection=${srv.idleBytes}');

      expect(second.statusCode, 200, reason: '掐断陈旧连接后的请求必须最终成功');
      expect(
        srv.hits.length,
        2,
        reason: '服务器应只收到 2 次业务请求（1 原始 + 1 重试），不得出现风暴',
      );
      expect(
        srv.idleBytes == 0 || probe.retryFrames > 0,
        isTrue,
        reason: '若客户端确实把第二条请求写进了已关闭的连接'
            '（bytesWrittenToKilledConnection > 0），就必须看到一次重试；'
            '否则说明它被静默吞掉了',
      );
    });

    test('控制组：不掐断 → 第二条请求复用同一条 TCP 连接（证明 keep-alive 真的生效）',
        () async {
      // 这条是 S1 的「反向对照」，缺了它 S1 的结论就不成立：
      //   若本 setup 里客户端压根不 keep-alive（每次都新开连接），
      //   「killIdle 后第二条请求仍然成功」就毫无信息量 —— 那只是「本来就没复用」。
      // 用普通 `ok()`（不 detach）：这样连接仍归 HttpServer 管，第二条请求能真的
      // 落在同一条连接上被服务（第一次写这版时我 detach 了 socket，结果客户端的
      // 复用请求没人应答 → receiveTimeout，反而直接证明了「复用确实发生」）。
      late _LocalServer s;
      s = await _LocalServer.start((request, seq) async {
        await s.ok(request);
      });
      srv = s;
      await boot(srv);

      await dio.get<String>('/rest/data');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await dio.get<String>('/rest/data');

      // ignore: avoid_print
      print('[S1-CONTROL] retryFrames=${probe.retryFrames} '
          'rawErrors=${probe.rawErrors.map((e) => e.name).toList()} '
          'serverHits=${srv.hits.length} remotePorts=${srv.remotePorts}');

      expect(srv.remotePorts.length, 2);
      expect(
        srv.remotePorts[0],
        srv.remotePorts[1],
        reason: '不掐断时必须复用同一条连接（remotePort 相同），'
            '否则 S1 里「换了一条新连接」就说明不了任何问题',
      );
      expect(probe.retryFrames, 0, reason: '控制组里不该出现重试');
    });

    test('记录 S1 的实际故障形态（是否真复用 + 重试帧 + 原始错误类型）', () async {
      srv = await startKeepAliveThenOk();
      await boot(srv);

      await dio.get<String>('/rest/data');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      srv.killIdle();
      await dio.get<String>('/rest/data');

      // 这条用例只产出「证据行」，硬断言留给上面那条；它回答的问题是：
      //   客户端有没有真的往那条已关闭的连接里写东西？
      //   * bytesWrittenToKilledConnection == 0 → 客户端自己把死连接从 idle 池
      //     丢掉了（对应 http_impl.dart 的 connectionClosed → _idle.remove）；
      //   * > 0 → 它真的复用了，那这次请求必然失败、必须靠重试兜。
      // ignore: avoid_print
      print('[S1-VERDICT] attempts=${probe.attempts} '
          'retryFrames=${probe.retryFrames} '
          'rawErrors=${probe.rawErrors.map((e) => e.name).toList()} '
          'serverHits=${srv.hits.length} remotePorts=${srv.remotePorts} '
          'bytesWrittenToKilledConnection=${srv.idleBytes}');
      expect(srv.hits.length, 2);
    });
  });

  group('S2 对端收到请求后暴力掐断', () {
    late _LocalServer srv;

    test('首次掐断 → 立即重试 → 重试成功', () async {
      late _LocalServer s;
      s = await _LocalServer.start((request, seq) async {
        if (seq == 1) {
          await s.abort(request);
        } else {
          await s.ok(request);
        }
      });
      srv = s;
      await boot(srv);

      final response = await dio.get<String>('/rest/data');

      expect(response.statusCode, 200);
      expect(srv.hits.length, 2, reason: '1 次被掐断 + 1 次重试成功');
      expect(probe.attempts, 2, reason: '必须真的重试过一次（不是静默成功）');
      expect(probe.retryFrames, 1, reason: '第 2 帧必须带重试标记');
      expect(
        probe.rawErrors.first,
        DioExceptionType.connectionError,
        reason: '「Connection closed before full header was received」'
            '被 dio 映射为 connectionError，才命中 _isConnectionError',
      );
    });

    test('持续掐断 → 单地址最多 1 + 3 次后放弃（有界，不递归）', () async {
      late _LocalServer s;
      s = await _LocalServer.start((request, seq) async {
        await s.abort(request);
      });
      srv = s;
      await boot(srv);

      await expectLater(
        dio.get<String>('/rest/data'),
        throwsA(isA<DioException>()),
      );

      expect(
        srv.hits.length,
        4,
        reason: '单地址池 = 无备线 → 预算 3：1 原始 + 3 次同地址重试',
      );
      expect(probe.attempts, 4);
      expect(probe.retryFrames, 3);
    });
  });

  group('S3 非幂等请求不重放', () {
    test('allowFallbackRetry=false + 被掐断 → 只打 1 次，直接抛错', () async {
      late _LocalServer s;
      s = await _LocalServer.start((request, seq) async {
        await s.abort(request);
      });
      await boot(s);

      await expectLater(
        dio.get<String>(
          '/rest/data',
          options: Options(
            extra: {FallbackInterceptor.allowRetryExtraKey: false},
          ),
        ),
        throwsA(isA<DioException>()),
      );

      expect(s.hits.length, 1, reason: '非幂等请求重放有副作用，必须打住');
      expect(probe.attempts, 1);
      expect(probe.retryFrames, 0);
      expect(
        probe.rawErrors.single,
        DioExceptionType.connectionError,
        reason: '确认它确实是「连接类错误」而非被别的分支拦下',
      );
    });
  });

  group('S4 真实 socket 下的 14 条并发', () {
    test('前 7 条连接被 destroy，其余正常 → 成功率 / 请求总量', () async {
      const total = 14;
      const destroyed = 7;
      late _LocalServer s;
      s = await _LocalServer.start((request, seq) async {
        if (seq <= destroyed) {
          await s.abort(request);
        } else {
          await s.ok(request);
        }
      });
      await boot(s);

      final results = await Future.wait(
        List<Future<int>>.generate(
          total,
          (_) => dio
              .get<String>('/rest/data')
              .then((r) => r.statusCode ?? 0)
              .catchError((Object _) => -1),
        ),
      );

      final okCount = results.where((code) => code == 200).length;
      // ignore: avoid_print
      print('[S4-EVIDENCE] success=$okCount/$total '
          'serverHits=${s.hits.length} attempts=${probe.attempts} '
          'retryFrames=${probe.retryFrames} '
          'rawErrors=${probe.rawErrors.map((e) => e.name).toList()}');

      expect(
        okCount,
        total,
        reason: 'attempt 0 免令牌 → 被掐断的每一条都还有一次立即重试机会，'
            '不应有请求因为「令牌桶被前几条吃光」而失败',
      );
      expect(
        s.hits.length,
        total + destroyed,
        reason: '被掐断的 7 条各补 1 次立即重试（零延时、免令牌），共 21 次',
      );
      expect(
        s.hits.length,
        lessThanOrEqualTo(total * 3),
        reason: '不出现请求风暴：单条逻辑请求最多 1 原始 + 3 重试',
      );
    });

    test('令牌桶：14 条并发持续失败时，延时重试波被 12 枚令牌封顶', () async {
      const total = 14;
      final frozen = DateTime(2026, 1, 1, 12);
      FallbackInterceptor.retryClock = () => frozen;

      late _LocalServer s;
      s = await _LocalServer.start((request, seq) async {
        await s.abort(request);
      });
      await boot(s);

      final results = await Future.wait(
        List<Future<int>>.generate(
          total,
          (_) => dio
              .get<String>('/rest/data')
              .then((r) => r.statusCode ?? 0)
              .catchError((Object _) => -1),
        ),
      );

      final delayed = probe.delayedRetries;
      // ignore: avoid_print
      print('[S4b-EVIDENCE] success=${results.where((c) => c == 200).length}/'
          '$total serverHits=${s.hits.length} attempts=${probe.attempts} '
          'retryFrames=${probe.retryFrames} delayedRetries=$delayed '
          'retryAttempts=${probe.retryAttempts}');

      expect(results.every((code) => code == -1), isTrue, reason: '全部失败');
      // 账目：每条至少打「1 原始 + 1 次零延时 attempt 0」（免令牌）= 2 次，
      // 共 28 次；之后 attempt 1/2 各需 1 枚令牌，12 枚 → 最多再 12 次。
      expect(
        delayed,
        FallbackInterceptor.retryTokenLimit,
        reason: '延时重试次数必须正好被 12 枚令牌封顶（14 条都想要，只放出 12）',
      );
      expect(
        s.hits.length,
        lessThanOrEqualTo(total * 4),
        reason: '总量上限：每条 1 + 3 次',
      );
    });
  });
}
