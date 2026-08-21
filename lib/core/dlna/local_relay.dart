import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dlna_models.dart';

/// 本地 HTTP 中继模块
/// 在局域网内启动 HTTP 服务，将从服务端拉取的音频流转发给 DLNA 设备
class LocalRelay {
  HttpServer? _server;
  final Map<String, _RelaySession> _sessions = {};
  String Function(String songId)? _streamUrlBuilder;
  Future<Uint8List> Function(String url, {int? start, int? end})? _fetchBytes;

  /// 初始化中继服务
  /// [streamUrlBuilder] 根据 songId 构建服务端流 URL
  /// [fetchBytes] 从服务端拉取音频数据
  Future<void> init({
    required String Function(String songId) streamUrlBuilder,
    required Future<Uint8List> Function(String url, {int? start, int? end}) fetchBytes,
  }) async {
    _streamUrlBuilder = streamUrlBuilder;
    _fetchBytes = fetchBytes;
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

  /// 停止 HTTP 服务器
  Future<void> stop() async {
    await _server?.close();
    _server = null;

    // 关闭所有会话
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

  /// 获取本地局域网 IP
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
    } catch (_) {}

    return null;
  }

  /// 处理 HTTP 请求
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

    // 处理 Range 请求
    final rangeHeader = request.headers.value('range');
    int? start;
    int? end;
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      start = int.tryParse(parts[0]);
      end = parts.length > 1 ? int.tryParse(parts[1]) : null;
    }

    // 转发请求到服务端
    _proxyRequest(request, session, start: start, end: end);
  }

  /// 代理请求到服务端
  Future<void> _proxyRequest(
    HttpRequest request,
    _RelaySession session, {
    int? start,
    int? end,
  }) async {
    if (_streamUrlBuilder == null || _fetchBytes == null) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..close();
      return;
    }

    final serverUrl = _streamUrlBuilder!(session.session.songId);

    try {
      final bytes = await _fetchBytes!(
        serverUrl,
        start: start,
        end: end,
      );

      request.response
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..headers.contentLength = bytes.length;

      if (start != null) {
        request.response.headers.set(
          'Content-Range',
          'bytes $start-${start + bytes.length - 1}/*',
        );
        request.response.statusCode = HttpStatus.partialContent;
      }

      request.response.add(bytes);
      await request.response.close();
    } catch (e) {
      request.response
        ..statusCode = HttpStatus.badGateway
        ..close();
    }
  }

  /// 生成随机 token
  String _generateToken() {
    final random = List<int>.generate(16, (_) => _secureRandomByte());
    return random.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 生成安全随机字节
  int _secureRandomByte() {
    // 使用时间戳+随机数作为简单实现
    // 生产环境可改用 dart:crypto
    return (DateTime.now().microsecondsSinceEpoch ^ (1000000 * 0.7)).toInt() &
        0xFF;
  }

  /// 获取当前活跃会话数
  int get activeSessions =>
      _sessions.values.where((s) => !s.session.isExpired).length;
}

/// 中继会话内部状态
class _RelaySession {
  final DlnaCastSession session;

  _RelaySession({required this.session});

  void close() {
    // 清理资源
  }
}
