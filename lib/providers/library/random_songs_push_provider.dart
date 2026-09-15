import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/server_url_security.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/peer_remote_control_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 服务端推送客户端 —— 主项目 `/ws` 的**唯一**长连接。
///
/// 承载两类消息(都靠同一条连接,不能拆成两条:服务端按 clientId 定向投递,
/// 两条同 clientId 的连接会让同一条指令被投递两次、执行两次):
///
/// 1. `random-songs-changed`:随机歌曲歌单内容变动,收到后调用
///    [notifyRandomSongsChanged](),让各监听方(如随心听区块)按需重拉歌单 ——
///    彻底替代客户端轮询随机歌曲歌单,打开页面不再等待后端惰性重建。
/// 2. `peer_command` / `peer_queue_changed`:本端实例**被遥控**(Web / HA 遥控
///    本端播放),转交 [peerRemoteControlProvider] 处理。
///
/// 握手必须带 `?clientId=` —— 服务端靠它区分同账号下的多个播放端并定向投递
/// (见后端 `services/ws` 的 `sendToLocalPeer`)。
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
        // 拿不到 token(登录失败 / 地址刚切换还没就绪)→ **必须排重连**:此前这里
        // 直接 return,一旦首轮失败(如登录端点 404),整条 WS 就此永久熄火,
        // 只有等用户改动线路/库才会再试 —— 「能看见状态、按钮全无反应」的隐蔽故障。
        Logger.debugWithTag(_tag, 'no ws auth token available, retry later');
        // 没有活跃库(无凭据可重试)→ 不排重连,避免空转定时器;
        // 只有「有库但 token 临时取不到」才重试(如登录端点抖动 / 地址刚切换)。
        if (_ref.read(activeLibraryProvider) != null) {
          _scheduleReconnect();
        }
        return;
      }

      await _disconnect();
      _activeUrl = url;

      final wsUrl = _buildWsUrl(url, token, await _resolveClientId());
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
        // 登录端点挂在服务端的 `/rest` 前缀下(`app.route("/rest", authRoutes)`),
        // 少写 `/rest` 会 404 —— 表现是「token 拿不到 → 整条 WS 被禁用」:服务端
        // 里本端照样注册 / 心跳 / 上报状态(那些走 Dio 的 baseUrl),但**永远收不到
        // 遥控指令**,而别人能看见本端在放什么。修 404 比补日志更值。
        final resp = await dio.post<Map<String, dynamic>>(
          joinServerUrl(base, '/rest/api/v1/auth/login'),
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

  /// 本安装的临时端 ID —— 服务端据此把「遥控本机」的指令/通知**定向**投递到本条
  /// 连接(见后端 `services/ws` 的 `sendToLocalPeer`,按 userId + clientId 精确匹配)。
  /// 拿不到时退化为不带:只影响「本端被遥控」,不影响本端作为遥控器去遥控别人。
  Future<String?> _resolveClientId() async {
    try {
      return await _ref.read(subsonicApiClientProvider).clientId();
    } catch (e) {
      Logger.debugWithTag(_tag, 'clientId unavailable: $e');
      return null;
    }
  }

  /// 由服务端基地址构建 WebSocket 地址(http→ws, https→wss, 保留子路径)。
  String _buildWsUrl(String url, String token, String? clientId) {
    final normalized = normalizeServerBaseUrl(url);
    final wsBase = normalized.startsWith('https://')
        ? 'wss://${normalized.substring(8)}'
        : normalized.startsWith('http://')
            ? 'ws://${normalized.substring(7)}'
            : normalized;
    final params = <String, String>{'token': token};
    // 必须带上:服务端靠它区分同账号下的多个播放端。不带则本端无法被定向遥控
    // (服务端宁可不下发,也不会把指令广播给同账号的所有连接)。
    if (clientId != null && clientId.isNotEmpty) params['clientId'] = clientId;
    final uri =
        Uri.parse('$wsBase/ws').replace(queryParameters: params);
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
        return;
      }
      // 本端实例「被遥控」的消息(peer_command / peer_queue_changed)。
      // 服务端按 clientId **定向**投递到本条连接,故复用这同一条 WS ——
      // 若本端另开一条同 clientId 的连接,同一条指令会被投递两次、执行两次。
      final type = decoded['type'];
      if (type == 'peer_command' || type == 'peer_queue_changed') {
        unawaited(
          _ref.read(peerRemoteControlProvider.notifier).handleServerMessage(decoded),
        );
        return;
      }
      // 收藏变动(同账号的别的端点的红心)→ 对齐本端镜像里的 starred。
      // 队列项不带 starred,靠队列轮询永远刷不到,必须由这条推送驱动。
      if (type == 'song_starred') {
        final ids = decoded['songIds'];
        final starred = decoded['starred'] == true;
        if (ids is List) {
          final player = _ref.read(playerProvider.notifier);
          for (final id in ids) {
            if (id is String && id.isNotEmpty) {
              player.applyExternalStarred(id, starred);
              Logger.infoWithTag(_tag, 'external starred applied: $id -> $starred');
            }
          }
        }
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
