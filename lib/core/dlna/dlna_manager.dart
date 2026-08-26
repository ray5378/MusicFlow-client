import 'dart:async';
import 'dart:math' as math;
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

  /// 投屏播放模式(order|one|all|shuffle),默认列表循环(对齐链路 A cast.playMode)。
  String _playMode = 'all';

  /// 当前已通过 SetNext 预置到设备的「下一首」下标(按播放模式计算),用于自动续播时对齐游标。
  int? _provisionedIndex;

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

  /// 当前投屏是否存在
  bool get isCasting => _currentDevice != null;

  /// 当前投屏播放模式(order|one|all|shuffle)。
  String get playMode => _playMode;

  /// 当前投屏设备是否静音。
  bool get isMuted => _currentStatus.muted;

  /// 设置投屏播放模式(对齐链路 A cast.playMode):列表循环 all/顺序 order/单曲 one/随机 shuffle。
  void setPlayMode(String mode) {
    if (!const <String>['order', 'one', 'all', 'shuffle'].contains(mode)) {
      return;
    }
    _playMode = mode;
  }

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
    _provisionedIndex = null;

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

  /// 下一首（按播放模式:all 循环 / shuffle 随机 / order&one 线性不循环末首）
  Future<void> next() async {
    if (_queue.isEmpty) return;
    switch (_playMode) {
      case 'shuffle':
        if (_queue.length <= 1) return;
        _queueIndex = _randomOtherIndex();
        await _playCurrentTrack();
      case 'all':
        if (_queue.length <= 1) return;
        _queueIndex = (_queueIndex + 1) % _queue.length;
        await _playCurrentTrack();
      default: // order / one
        if (_queueIndex + 1 < _queue.length) {
          _queueIndex++;
          await _playCurrentTrack();
        }
    }
  }

  /// 上一首
  Future<void> previous() async {
    if (_queueIndex - 1 >= 0) {
      _queueIndex--;
      await _playCurrentTrack();
    }
  }

  /// 返回不同于当前下标的随机下标（shuffle 使用）。
  int _randomOtherIndex() {
    if (_queue.length <= 1) return _queueIndex;
    var i = math.Random().nextInt(_queue.length);
    while (i == _queueIndex) {
      i = math.Random().nextInt(_queue.length);
    }
    return i;
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

  /// 预置下一首到 SetNextAVTransportURI（按播放模式选择要无缝续播的曲目；
  /// 设备不支持 SetNext 则回退为手动切歌）。同时记录 _provisionedIndex 供自动续播对齐游标。
  Future<void> _provisionNextTrack() async {
    if (!_nextSupported) return;
    // 计算按播放模式应预置的下一首下标（one/shuffle 预置本曲以支持自循环/随机缓冲）。
    final int? nextIndex = switch (_playMode) {
      'shuffle' => _queue.length <= 1 ? null : _randomOtherIndex(),
      'one' => _queueIndex,
      'all' => _queue.length <= 1 ? null : (_queueIndex + 1) % _queue.length,
      _ => _queueIndex + 1 < _queue.length ? _queueIndex + 1 : null,
    };
    _provisionedIndex = nextIndex;
    if (nextIndex == null) return;

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
    _provisionedIndex = null;
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

  // ==================== 投屏队列编辑（对齐链路 A） ====================

  /// 追加曲目到投屏队列末尾（不中断当前播放，对齐链路 A enqueueSongs）。
  /// 新曲目将在后续轮播/手动切歌时进入播放序列；若已预置下一首则同步重算。
  Future<void> enqueueSongs(List<DlnaCastTrack> tracks) async {
    if (tracks.isEmpty || _currentDevice == null) return;
    _queue = [..._queue, ...tracks];
    // 追加当前位置后的新曲:若当前已预置的是某首后续曲,顺延重算下一首,
    // 保证「自动续播」能覆盖到末尾追加的曲目。
    await _provisionNextTrack();
    onTrackChanged?.call(_queueIndex);
  }

  /// 从投屏队列移除指定下标（播放保持连贯，对齐链路 A removeQueueItem）。
  Future<void> removeQueueItem(int index) async {
    if (_currentDevice == null || index < 0 || index >= _queue.length) return;
    _queue = List.of(_queue)..removeAt(index);
    if (_queue.isEmpty) {
      // 队列被清空:停止设备并退出投屏态。
      await stopCast();
      return;
    }
    // 游标修正:若移除的是当前曲目之前,整体前移;若是当前曲目本身,设备仍在本曲
    // 播放(HTTP 中继未断),游标保持指向同位置(即下一首),避免越界。
    if (index < _queueIndex) {
      _queueIndex--;
    } else if (_queueIndex >= _queue.length) {
      _queueIndex = _queue.length - 1;
    }
    await _provisionNextTrack();
    onTrackChanged?.call(_queueIndex);
  }

  /// 队列拖拽排序 from → to。
  /// [to] 为原列表中「净插入位」：当把曲目拖到队尾(列表末尾之后)时 to 可为
  /// _queue.length；移除后实际插入位为 `to > from ? to - 1 : to`，避免 insert 越界。
  Future<void> reorderQueue(int from, int to) async {
    if (_currentDevice == null) return;
    if (from < 0 || from >= _queue.length || to < 0 || to > _queue.length) {
      return;
    }
    if (from == to) return;
    // 记录游标当前指向的曲目引用，拖拽后用 indexOf 重定位（对等比对，overwrites 重复曲目边界可用）。
    final current =
        from == _queueIndex ? _queue[from] : _queue[_queueIndex];
    _queue = List.of(_queue);
    final item = _queue.removeAt(from);
    final insertAt = to > from ? to - 1 : to;
    _queue.insert(insertAt, item);
    // 游标跟随被拖动的曲目本身；被挤开的曲目按新位置重定位。
    _queueIndex = from == _queueIndex ? insertAt : _queue.indexOf(current);
    // 中继会话按 songId 缓存,排序不丢 token;重算下一首以匹配新顺序。
    await _provisionNextTrack();
    onTrackChanged?.call(_queueIndex);
  }

  /// 清空投屏队列并停止设备投屏（对齐链路 A clearCastQueue）。
  Future<void> clearCastQueue() async {
    await stopCast();
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

      // 自动续播检测：上一帧接近曲末、新帧从头开播 → 设备已自动切到预置的下一首。
      // 游标按 _provisionedIndex（已随播放模式预置）对齐；设备无 SetNext 支持时回退线性 +1。
      final nearEnd = prevState == 'PLAYING' &&
          prevDuration > 0 &&
          prevDuration - prevPosition <= 3;
      final startedOver = state == 'PLAYING' &&
          posInfo.position >= 0 &&
          posInfo.position < 5;
      if (nearEnd && startedOver) {
        final nextIndex = _provisionedIndex ?? (_queueIndex + 1);
        if (nextIndex >= 0 &&
            nextIndex < _queue.length &&
            nextIndex != _queueIndex) {
          _queueIndex = nextIndex;
          onTrackChanged?.call(_queueIndex);
          await _provisionNextTrack();
          _pruneRelaySessions();
        }
      }

      onStatusChanged?.call(_currentStatus);
    } catch (e) {
      // 设备可能离线
      debugPrint('DLNA 状态轮询失败: $e');
    }
  }

  // ==================== 辅助方法 ====================

  /// 构建 DIDL-Lite 元数据（返回**原始 XML**，标签用真实 `<>`，仅转义文本内容）。
  /// 该字符串会作为 CurrentURIMetaData 参数交给 SoapControl 统一做一次 XML 转义后
  /// 嵌入 SOAP 信封；设备 SOAP 栈反解后得到的就是这份原始 XML。
  /// 避免此前「这里先手写 &lt; 预转义、SOAP 再转义一次」导致的双重转义
  /// （设备拿到 `&amp;lt;` → 反解为字面 `&lt;` 而非真实标签，严格设备会拒绝该曲目）。
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
      ..write('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"')
      ..write(' xmlns:dc="http://purl.org/dc/elements/1.1/"')
      ..write(' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">')
      ..write('<item id="1" parentID="0" restricted="1">')
      ..write('<dc:title>${_escapeXml(title)}</dc:title>');

    if (artist != null) {
      buffer.write('<dc:creator>${_escapeXml(artist)}</dc:creator>');
    }
    if (album != null) {
      buffer.write('<upnp:album>${_escapeXml(album)}</upnp:album>');
    }
    if (albumArtUri != null) {
      buffer.write('<upnp:albumArtURI>${_escapeXml(albumArtUri)}</upnp:albumArtURI>');
    }

    buffer
      ..write('<upnp:class>object.item.audioItem.musicTrack</upnp:class>')
      ..write('<res protocolInfo="$protocolInfo">${_escapeXml(uri)}</res>')
      ..write('</item></DIDL-Lite>');

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
    // 先摘掉对外回调，避免停播通知时段（notifier）已被 dispose 而抛错
    onStatusChanged = null;
    onTrackChanged = null;
    onCastDisconnected = null;
    onDevicesChanged = null;
    await stopCast();
    _discovery.dispose();
    await _relay.stop();
    _devices.clear();
    _initialized = false;
  }
}
