import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dlna_models.dart';

/// 本地 HTTP 中继模块（链路 B）
/// 在局域网内启动 HTTP 服务，将从服务端拿到的音频流**逐块转发**给 DLNA 设备。
/// 采用真流式：设备带 Range 的 GET → 客户端从服务器拉对应 Range → 逐块 pipe 转发，
/// 禁止整段音频读入内存（SPEC §1.5）。
class LocalRelay {
  HttpServer? _server;
  final Map<String, _RelaySession> _sessions = {};

  /// 根据 songId 构建服务端流 URL（复用 SubsonicApiClient.getStreamUrl 语义）。
  String Function(String songId)? _streamUrlBuilder;

  /// 当某首曲目的流被**完整转发到 EOF** 时回调（携带 songId）。
  ///
  /// 本地中继是我们自己的 HTTP 服务，能确切知道设备何时把整条流消费完毕——
  /// 这比依赖 DLNA 设备上报的 duration/position（RawHTTP 流常回报 0）更可靠。
  /// 客户端据此触发自动续播。仅对从 0 开始的全量播放回调，跳过中途 Range 跳转请求。
  void Function(String songId)? onStreamEnded;

  /// 初始化中继服务
  /// [streamUrlBuilder] 根据 songId 构建服务端流 URL（含鉴权参数）。
  Future<void> init({
    required String Function(String songId) streamUrlBuilder,
  }) async {
    _streamUrlBuilder = streamUrlBuilder;
  }

  /// 启动 HTTP 服务器
  Future<int> start({int port = 0}) async {
    if (_server != null) return _server!.port;

    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
    );

    _server!.listen(_handleRequest);

    return _server!.port;
  }

  /// 停止 HTTP 服务器，并关闭所有会话
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;

    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
  }

  /// 创建投屏会话
  DlnaCastSession createSession(String deviceId, String songId) {
    final token = _generateToken();
    final now = DateTime.now();

    final session = DlnaCastSession(
      token: token,
      deviceId: deviceId,
      songId: songId,
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 6)),
    );

    _sessions[token] = _RelaySession(session: session);
    return session;
  }

  /// 获取本地局域网 IPv4
  static Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        // 跳过回环和虚拟接口
        if (interface.name.startsWith('lo') ||
            interface.name.startsWith('docker') ||
            interface.name.startsWith('br-') ||
            interface.name.startsWith('veth')) {
          continue;
        }

        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      developer.log('获取本地局域网 IP 失败', name: 'DLNA-Relay', error: e);
    }

    return null;
  }

  /// 处理设备发起的 HTTP 请求
  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    final token = request.uri.queryParameters['token'];

    // 只处理 /stream 请求
    if (path != '/stream' || token == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }

    final session = _sessions[token];
    if (session == null || session.session.isExpired) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Invalid or expired session')
        ..close();
      return;
    }

    // 解析 Range 请求（DLNA 设备通常带 range 做进度跳转）
    final rangeHeader = request.headers.value('range');
    int? start;
    int? end;
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      start = int.tryParse(parts[0]);
      end = parts.length > 1 ? int.tryParse(parts[1]) : null;
    }

    // 异步转发，不阻塞事件循环
    unawaited(_proxyRequest(request, session, start: start, end: end));
  }

  /// 从服务端拉流并**逐块**转发给设备（真流式，不整段入内存）
  Future<void> _proxyRequest(
    HttpRequest request,
    _RelaySession session, {
    int? start,
    int? end,
  }) async {
    final builder = _streamUrlBuilder;
    if (builder == null) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..close();
      return;
    }

    final serverUrl = builder(session.session.songId);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);

    try {
      final upstreamRequest = await client.getUrl(Uri.parse(serverUrl));

      // 透传 Range（若上层给了）
      if (start != null || end != null) {
        final range = start != null
            ? (end != null ? 'bytes=$start-$end' : 'bytes=$start-')
            : 'bytes=0-${end ?? ''}';
        upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
      }
      upstreamRequest.headers.set(HttpHeaders.acceptHeader, 'audio/*,*/*;q=0.8');

      final upstream = await upstreamRequest.close();

      final response = request.response;
      try {
        response.statusCode = upstream.statusCode;

        final contentType = upstream.headers.contentType;
        if (contentType != null) {
          response.headers.contentType = contentType;
        }

        final contentRange = upstream.headers.value(HttpHeaders.contentRangeHeader);
        if (contentRange != null) {
          response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
        }

        if (upstream.contentLength >= 0) {
          response.headers.set(
            HttpHeaders.contentLengthHeader,
            upstream.contentLength,
          );
        }
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

        // 核心：把服务端响应流逐块 pipe 给设备，不缓存在内存
        await upstream.pipe(response);

        // 完整转发放到 EOF：若设备是从 0 起的全量播放，则通知管理器“该曲放完”，
        // 用于不依赖设备时长上报的自动续播；中途 Range 跳转请求不触发。
        if (start == null || start == 0) {
          onStreamEnded?.call(session.session.songId);
        }
      } catch (e) {
        developer.log('DLNA 中继转发中断', name: 'DLNA-Relay', error: e);
        try {
          await response.close();
        } catch (_) {}
      }
    } catch (e) {
      developer.log('DLNA 中继拉流失败 song=${session.session.songId}',
          name: 'DLNA-Relay', error: e);
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..close();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }

  /// 生成随机 token
  String _generateToken() {
    final random = List<int>.generate(16, (_) => DateTime.now().millisecond);
    return random.map((b) => b.toRadixString(16).padLeft(2, '0')).join() +
        (DateTime.now().microsecondsSinceEpoch.toRadixString(16));
  }

  /// 当前活跃会话数
  int get activeSessions =>
      _sessions.values.where((s) => !s.session.isExpired).length;
}

/// 中继会话内部状态
class _RelaySession {
  final DlnaCastSession session;

  _RelaySession({required this.session});

  void close() {
    // 会话无独立资源（真流式转发的连接随 close 释放）
  }
}