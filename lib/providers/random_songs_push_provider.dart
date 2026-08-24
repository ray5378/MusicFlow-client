import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/utils/logger.dart';
import '../core/utils/server_url_security.dart';
import '../data/models/music_library.dart';
import '../data/models/server_address.dart';
import 'api_provider.dart';
import 'library_provider.dart';
import 'music_provider.dart';

/// 随机歌曲歌单「服务端推送」客户端。
///
/// 主项目(服务端)插件在后台维护刷新「随机歌曲」歌单,每次内容变动时通过
/// WebSocket 广播 `random-songs-changed` 信号。本客户端连接主项目 `/ws`,
/// 收到该信号后调用 [notifyRandomSongsChanged](),让各监听方(如随心听区块)
/// 按需重拉歌单 —— 从而**彻底替代客户端轮询随机歌曲歌单**,打开页面不再
/// 等待后端惰性重建。
final randomSongsPushProvider = Provider<RandomSongsPushClient>((ref) {
  final client = RandomSongsPushClient(ref);
  ref.onDispose(client.dispose);
  return client;
});

class RandomSongsPushClient {
  RandomSongsPushClient(this._ref) {
    _init();
  }

  static const _tag = 'RANDOM_PUSH';

  final Ref _ref;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _connecting = false;
  int _reconnectDelayMs = _minReconnectDelayMs;
  String? _activeUrl;

  static const int _minReconnectDelayMs = 2000;
  static const int _maxReconnectDelayMs = 30000;

  void _init() {
    // 活跃地址变化 → 重连到新线路。
    _ref.listen<ServerAddress?>(activeAddressProvider, (prev, next) {
      if (_disposed) return;
      if (next == null) return;
      if (next.url == _activeUrl) return;
      _reconnect();
    });
    // 库变化(含 apiKey/token 认证信息变化)→ 重新解析 token 并连接。
    _ref.listen<MusicLibrary?>(activeLibraryProvider, (prev, next) {
      if (_disposed) return;
      if (next == null) return;
      _reconnect();
    });
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_disposed || _connecting) return;
    final addr = _ref.read(activeAddressProvider);
    if (addr == null || addr.url.isEmpty) {
      _scheduleReconnect();
      return;
    }
    final url = addr.url;
    // 已连接到同一线路且通道仍存活 → 跳过。
    if (url == _activeUrl && _channel != null) return;

    _connecting = true;
    try {
      final token = await _resolveToken();
      if (_disposed) return;
      if (token == null || token.isEmpty) {
        Logger.debugWithTag(_tag, 'no ws auth token available, push disabled');
        return;
      }

      await _disconnect();
      _activeUrl = url;

      final wsUrl = _buildWsUrl(url, token);
      try {
        final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
        _channel = channel;
        _subscription = channel.stream.listen(
          _onMessage,
          onError: (Object e) {
            Logger.warnWithTag(_tag, 'ws error: $e');
            _clearChannel();
            _scheduleReconnect();
          },
          onDone: () {
            Logger.infoWithTag(_tag, 'ws closed');
            _clearChannel();
            _scheduleReconnect();
          },
          cancelOnError: false,
        );
        Logger.infoWithTag(_tag, 'ws connected: ${Uri.parse(wsUrl).host}');
        _reconnectDelayMs = _minReconnectDelayMs;
      } catch (e) {
        Logger.warnWithTag(_tag, 'ws connect failed: $e');
        _clearChannel();
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  /// 解析 WebSocket 认证 token:
  /// - apiKey 认证:直接用服务端用户的长效 apiKey;
  /// - token 认证:调用主项目登录接口换取 JWT(与 `?token=` 握手协议一致)。
  Future<String?> _resolveToken() async {
    final lib = _ref.read(activeLibraryProvider);
    if (lib == null) return null;
    if (lib.authType == MusicLibraryAuthType.apiKey &&
        lib.apiKey != null &&
        lib.apiKey!.isNotEmpty) {
      return lib.apiKey;
    }
    if (lib.username != null &&
        lib.username!.isNotEmpty &&
        lib.password != null &&
        lib.password!.isNotEmpty) {
      try {
        final dio = _ref.read(dioProvider);
        final base = normalizeServerBaseUrl(
          _ref.read(activeAddressProvider)?.url ?? '',
        );
        if (base.isEmpty) return null;
        final resp = await dio.post<Map<String, dynamic>>(
          '$base/api/v1/auth/login',
          data: {'username': lib.username, 'password': lib.password},
          options: Options(contentType: 'application/json'),
        );
        final token = resp.data?['token'] as String?;
        if (token != null && token.isNotEmpty) return token;
        Logger.warnWithTag(_tag, 'login returned no token');
      } catch (e) {
        Logger.warnWithTag(_tag, 'login for ws token failed', e);
      }
    }
    return null;
  }

  /// 由服务端基地址构建 WebSocket 地址(http→ws, https→wss, 保留子路径)。
  String _buildWsUrl(String url, String token) {
    final normalized = normalizeServerBaseUrl(url);
    final wsBase = normalized.startsWith('https://')
        ? 'wss://${normalized.substring(8)}'
        : normalized.startsWith('http://')
            ? 'ws://${normalized.substring(7)}'
            : normalized;
    final uri = Uri.parse('$wsBase/ws')
        .replace(queryParameters: {'token': token});
    return uri.toString();
  }

  void _onMessage(dynamic data) {
    try {
      final decoded = data is String
          ? jsonDecode(data)
          : jsonDecode(String.fromCharCodes(data is List<int> ? data : []));
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['type'] == 'random-songs-changed') {
        Logger.infoWithTag(_tag, 'received random-songs-changed, notify clients');
        notifyRandomSongsChanged();
      }
    } catch (e) {
      Logger.debugWithTag(_tag, 'ws message parse failed: $e');
    }
  }

  void _reconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectDelayMs = _minReconnectDelayMs;
    unawaited(_connect());
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      Duration(milliseconds: _reconnectDelayMs),
      () {
        _reconnectDelayMs = (_reconnectDelayMs * 2).clamp(
          _minReconnectDelayMs,
          _maxReconnectDelayMs,
        );
        unawaited(_connect());
      },
    );
  }

  void _clearChannel() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  Future<void> _disconnect() async {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
  }
}
