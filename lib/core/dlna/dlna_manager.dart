import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dlna_models.dart';
import 'ssdp_discovery.dart';
import 'device_description.dart';
import 'soap_control.dart';
import 'local_relay.dart';

/// DLNA 管理器
/// 统一管理设备发现、投屏控制、本地中继
class DlnaManager {
  final SsdpDiscovery _discovery = SsdpDiscovery();
  final LocalRelay _relay = LocalRelay();

  final List<DlnaDevice> _devices = [];
  DlnaDevice? _currentDevice;
  Timer? _statusTimer;
  DlnaDeviceStatus _currentStatus = const DlnaDeviceStatus();

  bool _initialized = false;

  // ==================== 链路 B 投屏队列状态 ====================

  List<DlnaCastTrack> _queue = [];
  int _queueIndex = -1;
  bool _nextSupported = true;
  final Map<String, String> _relaySessionBySongId = {};
  String? _localIp;
  int? _relayPort;

  // ==================== 回调 ====================

  /// 设备列表变化回调
  void Function(List<DlnaDevice> devices)? onDevicesChanged;

  /// 投屏状态变化回调
  void Function(DlnaDeviceStatus status)? onStatusChanged;

  /// 当前投屏曲目在队列中的下标变化（自动续播/上下一首）
  void Function(int queueIndex)? onTrackChanged;

  /// 投屏断开回调
  void Function()? onCastDisconnected;

  /// 当前投屏队列
  List<DlnaCastTrack> get castQueue => List.unmodifiable(_queue);

  /// 当前投屏曲目下标
  int get castQueueIndex => _queueIndex;

  /// 当前是否存在投屏
  bool get isCasting => _currentDevice != null;

  // ==================== 初始化 ====================

  /// 初始化 DLNA 管理器（链路 B）
  /// [streamUrlBuilder] 根据 songId 构建服务端流 URL（含鉴权参数）。
  Future<void> init({
    required String Function(String songId) streamUrlBuilder,
  }) async {
    if (_initialized) return;

    await _relay.init(
      streamUrlBuilder: streamUrlBuilder,
    );

    // 启动被动监听
    _discovery.startListening(
      onDeviceUpdate: (location, alive) {
        _handleSsdpEvent(location, alive);
      },
    );

    _initialized = true;
  }

  // ==================== 设备发现 ====================

  /// 扫描 DLNA 设备
  Future<List<DlnaDevice>> scanDevices() async {
    final locations = await _discovery.search();

    // 解析每个设备的 description.xml
    for (final location in locations) {
      await _fetchAndAddDevice(location);
    }

    // 标记离线设备
    _markStaleDevices();

    onDevicesChanged?.call(List.unmodifiable(_devices));
    return List.unmodifiable(_devices);
  }

  /// 获取所有设备
  List<DlnaDevice> get devices => List.unmodifiable(_devices);

  /// 获取在线设备
  List<DlnaDevice> get onlineDevices =>
      _devices.where((d) => d.available && !d.disabled).toList();

  /// 处理 SSDP 事件
  Future<void> _handleSsdpEvent(String location, bool alive) async {
    if (alive) {
      await _fetchAndAddDevice(location);
    } else {
      // 查找并标记离线
      for (int i = 0; i < _devices.length; i++) {
        if (_devices[i].location == location) {
          _devices[i] = _devices[i].copyWith(available: false);
          break;
        }
      }
    }

    onDevicesChanged?.call(List.unmodifiable(_devices));
  }

  /// 获取设备描述并添加到列表
  Future<void> _fetchAndAddDevice(String location) async {
    final device = await DeviceDescriptionParser.fetch(location);
    if (device == null) return;

    final existing = _devices.indexWhere((d) => d.id == device.id);
    if (existing >= 0) {
      _devices[existing] = device;
    } else {
      _devices.add(device);
    }
  }

  /// 标记超时设备为离线
  void _markStaleDevices() {
    final now = DateTime.now();
    for (int i = 0; i < _devices.length; i++) {
      if (now.difference(_devices[i].lastSeen).inMinutes > 10) {
        _devices[i] = _devices[i].copyWith(available: false);
      }
    }
  }

  // ==================== 设备管理 ====================

  /// 设置设备别名
  void setDeviceAlias(String deviceId, String alias) {
    final index = _devices.indexWhere((d) => d.id == deviceId);
    if (index >= 0) {
      _devices[index] = _devices[index].copyWith(alias: alias);
      onDevicesChanged?.call(List.unmodifiable(_devices));
    }
  }

  /// 禁用/启用设备
  void setDeviceDisabled(String deviceId, bool disabled) {
    final index = _devices.indexWhere((d) => d.id == deviceId);
    if (index >= 0) {
      _devices[index] = _devices[index].copyWith(disabled: disabled);
      onDevicesChanged?.call(List.unmodifiable(_devices));
    }
  }

  /// 删除设备
  void removeDevice(String deviceId) {
    _devices.removeWhere((d) => d.id == deviceId);
    onDevicesChanged?.call(List.unmodifiable(_devices));
  }

  // ==================== 投屏控制 ====================

  /// 开始投屏（链路 B）：投整个队列，支持自动续播
  Future<bool> startCast(
    DlnaDevice device,
    List<DlnaCastTrack> tracks, {
    int startIndex = 0,
  }) async {
    if (device.avTransportUrl == null) return false;
    if (!device.available || device.disabled) return false;
    if (tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length) {
      return false;
    }

    // 启动本地中继（幂等：已启动则复用端口）
    final port = await _relay.start();
    final localIp = await LocalRelay.getLocalIp();
    if (localIp == null) return false;

    _currentDevice = device;
    _queue = List.of(tracks);
    _queueIndex = startIndex;
    _nextSupported = true;
    _localIp = localIp;
    _relayPort = port;

    try {
      await _playCurrentTrack();
      _startStatusPolling();
      return true;
    } catch (e) {
      debugPrint('DLNA 投屏启动失败: $_queueIndex $e');
      _stopStatusPolling();
      await _stopDevice(_currentDevice);
      _clearCastState();
      return false;
    }
  }

  /// 播放/切换到队列中下标 [index] 的曲目（当前曲则跳过）
  Future<void> playAt(int index) async {
    if (_currentDevice == null || index < 0 || index >= _queue.length) return;
    if (index == _queueIndex) return;
    _queueIndex = index;
    await _playCurrentTrack();
  }

  /// 下一首
  Future<void> next() async {
    if (_queueIndex + 1 < _queue.length) {
      _queueIndex++;
      await _playCurrentTrack();
    }
  }

  /// 上一首
  Future<void> previous() async {
    if (_queueIndex - 1 >= 0) {
      _queueIndex--;
      await _playCurrentTrack();
    }
  }

  /// 播放队列中的当前曲目（建会话/设 URI/播）+ 预置下一首
  Future<void> _playCurrentTrack() async {
    final device = _currentDevice!;
    final track = _queue[_queueIndex];
    final url = _relayUrlFor(track.songId);
    final metadata = _buildDidlLite(
      title: track.title,
      uri: url,
      mime: 'audio/mpeg',
      artist: track.artist,
      album: track.album,
    );

    await SoapControl.stop(device.avTransportUrl!);
    await SoapControl.setAvTransportUri(device.avTransportUrl!, url, metadata);
    await SoapControl.play(device.avTransportUrl!);

    // 预置下一首（设备支持 SetNext 则无缝续播）
    await _provisionNextTrack();

    onTrackChanged?.call(_queueIndex);
    _pruneRelaySessions();
  }

  /// 为当前曲目构建（或复用）中继 URI
  String _relayUrlFor(String songId) {
    final device = _currentDevice!;
    var token = _relaySessionBySongId[songId];
    if (token == null) {
      final session = _relay.createSession(device.id, songId);
      token = session.token;
      _relaySessionBySongId[songId] = token;
    }
    return 'http://$_localIp:$_relayPort/stream?token=$token';
  }

  /// 预置下一首到 SetNextAVTransportURI（设备不支持则回退为手动切歌）
  Future<void> _provisionNextTrack() async {
    if (!_nextSupported) return;
    final nextIndex = _queueIndex + 1;
    if (nextIndex >= _queue.length) return;

    final device = _currentDevice!;
    final next = _queue[nextIndex];
    final url = _relayUrlFor(next.songId);
    final metadata = _buildDidlLite(
      title: next.title,
      uri: url,
      mime: 'audio/mpeg',
      artist: next.artist,
      album: next.album,
    );

    final ok = await SoapControl.setNextAvTransportUri(
      device.avTransportUrl!,
      url,
      metadata,
    );
    if (!ok) _nextSupported = false;
  }

  /// 清理中继会话缓存，仅保留窗口内（当前 ±1）的 token，控制内存（§1.5）
  void _pruneRelaySessions() {
    _relaySessionBySongId.removeWhere((songId, _) {
      final idx = _queue.indexWhere((t) => t.songId == songId);
      return idx < _queueIndex - 1 || idx > _queueIndex + 1;
    });
  }

  /// 停止投屏
  Future<void> stopCast() async {
    _stopStatusPolling();
    await _stopDevice(_currentDevice);
    _clearCastState();
    _currentStatus = const DlnaDeviceStatus();
    onStatusChanged?.call(_currentStatus);
    onTrackChanged?.call(-1);
    onCastDisconnected?.call();
  }

  void _clearCastState() {
    _queue = [];
    _queueIndex = -1;
    _nextSupported = true;
    _relaySessionBySongId.clear();
    _currentDevice = null;
    _localIp = null;
    _relayPort = null;
    unawaited(_relay.stop());
  }

  Future<void> _stopDevice(DlnaDevice? device) async {
    if (device?.avTransportUrl == null) return;
    try {
      await SoapControl.stop(device!.avTransportUrl!);
    } catch (_) {}
  }

  /// 暂停播放
  Future<void> pause() async {
    if (_currentDevice?.avTransportUrl == null) return;
    try {
      await SoapControl.pause(_currentDevice!.avTransportUrl!);
      _currentStatus = _currentStatus.copyWith(state: 'PAUSED');
      onStatusChanged?.call(_currentStatus);
    } catch (_) {}
  }

  /// 恢复播放
  Future<void> resume() async {
    if (_currentDevice?.avTransportUrl == null) return;
    try {
      await SoapControl.play(_currentDevice!.avTransportUrl!);
      _currentStatus = _currentStatus.copyWith(state: 'PLAYING');
      onStatusChanged?.call(_currentStatus);
    } catch (_) {}
  }

  /// 跳转进度
  Future<void> seek(int seconds) async {
    if (_currentDevice?.avTransportUrl == null) return;
    try {
      await SoapControl.seek(_currentDevice!.avTransportUrl!, seconds);
    } catch (_) {}
  }

  /// 设置音量
  Future<void> setVolume(int volume) async {
    if (_currentDevice?.renderingControlUrl == null) return;
    try {
      await SoapControl.setVolume(
        _currentDevice!.renderingControlUrl!,
        volume.clamp(0, 100),
      );
      _currentStatus = _currentStatus.copyWith(volume: volume);
      onStatusChanged?.call(_currentStatus);
    } catch (_) {}
  }

  /// 静音开关
  Future<void> toggleMute() async {
    if (_currentDevice?.renderingControlUrl == null) return;
    try {
      final newMuted = !_currentStatus.muted;
      await SoapControl.setMute(
        _currentDevice!.renderingControlUrl!,
        newMuted,
      );
      _currentStatus = _currentStatus.copyWith(muted: newMuted);
      onStatusChanged?.call(_currentStatus);
    } catch (_) {}
  }

  /// 检查设备是否支持无缝切歌
  Future<bool> probeEnqueueSupport(DlnaDevice device) async {
    if (device.avTransportUrl == null) return false;
    // 简洁实现：由 SetNextAVTransportURI 实际结果回写 _nextSupported
    return _nextSupported;
  }

  // ==================== 状态轮询 ====================

  /// 启动状态轮询
  void _startStatusPolling() {
    _stopStatusPolling();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollStatus();
    });
  }

  /// 停止状态轮询
  void _stopStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  /// 轮询设备状态
  Future<void> _pollStatus() async {
    if (_currentDevice?.avTransportUrl == null) return;

    try {
      // 上一帧位置/状态（用于自动续播检测）
      final prevState = _currentStatus.state;
      final prevPosition = _currentStatus.position;
      final prevDuration = _currentStatus.duration;

      // 获取播放状态
      final state = await SoapControl.getTransportInfo(
        _currentDevice!.avTransportUrl!,
      );

      // 获取进度信息
      final posInfo = await SoapControl.getPositionInfo(
        _currentDevice!.avTransportUrl!,
      );

      // 获取音量
      int volume = _currentStatus.volume;
      bool muted = _currentStatus.muted;
      if (_currentDevice?.renderingControlUrl != null) {
        try {
          volume = await SoapControl.getVolume(
            _currentDevice!.renderingControlUrl!,
          );
          muted = await SoapControl.getMute(
            _currentDevice!.renderingControlUrl!,
          );
        } catch (_) {}
      }

      _currentStatus = DlnaDeviceStatus(
        state: state,
        position: posInfo.position,
        duration: posInfo.duration,
        volume: volume,
        muted: muted,
      );

      // 自动续播检测：上一帧接近曲末、新帧从头开播 → 设备已自动切到下一首
      final nearEnd = prevState == 'PLAYING' &&
          prevDuration > 0 &&
          prevDuration - prevPosition <= 3;
      final startedOver = state == 'PLAYING' &&
          posInfo.position >= 0 &&
          posInfo.position < 5;
      if (nearEnd && startedOver && _queueIndex + 1 < _queue.length) {
        _queueIndex++;
        onTrackChanged?.call(_queueIndex);
        await _provisionNextTrack();
        _pruneRelaySessions();
      }

      onStatusChanged?.call(_currentStatus);
    } catch (e) {
      // 设备可能离线
      debugPrint('DLNA 状态轮询失败: $e');
    }
  }

  // ==================== 辅助方法 ====================

  /// 构建 DIDL-Lite 元数据
  String _buildDidlLite({
    required String title,
    required String uri,
    required String mime,
    String? artist,
    String? album,
    String? albumArtUri,
  }) {
    final protocolInfo =
        'http-get:*:$mime:DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
        'DLNA.ORG_FLAGS=01700000000000000000000000000000';

    final buffer = StringBuffer()
      ..write('&lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"')
      ..write(' xmlns:dc="http://purl.org/dc/elements/1.1/"')
      ..write(' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;')
      ..write('&lt;item id="1" parentID="0" restricted="1"&gt;')
      ..write('&lt;dc:title&gt;${_escapeXml(title)}&lt;/dc:title&gt;');

    if (artist != null) {
      buffer.write('&lt;dc:creator&gt;${_escapeXml(artist)}&lt;/dc:creator&gt;');
    }
    if (album != null) {
      buffer.write('&lt;upnp:album&gt;${_escapeXml(album)}&lt;/upnp:album&gt;');
    }
    if (albumArtUri != null) {
      buffer.write(
          '&lt;upnp:albumArtURI&gt;${_escapeXml(albumArtUri)}&lt;/upnp:albumArtURI&gt;');
    }

    buffer
      ..write('&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;')
      ..write('&lt;res protocolInfo="$protocolInfo"&gt;${_escapeXml(uri)}&lt;/res&gt;')
      ..write('&lt;/item&gt;&lt;/DIDL-Lite&gt;');

    return buffer.toString();
  }

  /// XML 转义
  String _escapeXml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  // ==================== 资源清理 ====================

  /// 清理所有资源
  Future<void> dispose() async {
    await stopCast();
    _discovery.dispose();
    await _relay.stop();
    _devices.clear();
    _initialized = false;
  }
}
