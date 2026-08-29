import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../utils/logger.dart';
import 'dlna_models.dart';
import 'ssdp_discovery.dart';
import 'device_description.dart';
import 'soap_control.dart';

/// DLNA 管理器
/// 统一管理设备发现、投屏控制。
/// 架构：A 档·直传直连 —— 客户端把每首歌**服务端直连流 URL**(getStreamUrl, 含鉴权)
/// 交给设备，设备用自己的网卡从服务器**自拉流**播放；曲毕由客户端轮询检测自动
/// Set 下一首直连 URL 续播。不再做本地中继/推流(已删除 local_relay.dart)、不再用
/// 服务端 CDS 清单(/castPlaylist, 纯 renderer 兼容性差)。
class DlnaManager {
  final SsdpDiscovery _discovery = SsdpDiscovery();

  /// 服务端直连流 URL 构造器：给定 songId 返回设备可直拉的流 URL。
  /// A 档投屏时该 URL 应为**无鉴权**的 token 流地址 `/rest/dlna/stream/:token`
  /// （见 SubsonicApiClient.getDlnaCastStreamUrl），避免向设备下发带 `u/t/s`
  /// 鉴权参数的 URL 导致 GMediaRender 等渲染器拉流失败无声。异步以便先去服务端换 token。
  Future<String> Function(String songId)? _streamUrlBuilder;

  final List<DlnaDevice> _devices = [];
  DlnaDevice? _currentDevice;
  Timer? _statusTimer;
  DlnaDeviceStatus _currentStatus = const DlnaDeviceStatus();

  /// 串行化状态轮询：设备慢/超时导致上一帧仍在跑时跳过本帧，避免状态回写与
  /// 自动续播推进互相覆盖。
  bool _polling = false;

  /// 串行化「切歌/重放」：多个调用方（UI 快速连点、看门狗续播、SetNext 对齐）
  /// 可能在极短时间内对同一/相邻曲目并发下发 SetAVTransportURI，重叠的在途
  /// 切换会让正在建立的流被中断(实测 `Connection aborted`/`PlayerInterrupted`)。
  /// 这里把切歌动作串成一条 Future 链：前一个切歌完成后再处理下一个，杜绝重叠。
  Future<void> _pendingSwitchFuture = Future.value();

  bool _initialized = false;

  // ==================== 链路 B 投屏队列状态 ====================

  List<DlnaCastTrack> _queue = [];
  int _queueIndex = -1;
  bool _nextSupported = true;

  /// 当前投屏采用的路径档位（A 档·直传直连恒为 direct）。
  DlnaCastPath _castPath = DlnaCastPath.direct;

  /// 当前设备的能力（探测结果，供路径选择与 UI 展示）。
  DeviceCapability _capability = const DeviceCapability();

  /// 用户是否主动暂停（用于区分「暂停」与「设备异常停止」，避免误触发自动跳过）。
  bool _userPaused = false;
  /// 曲中段连续异常停止的连击计数（≥2 判定为播放失败，触发自动跳过兜底）。
  int _stallCount = 0;
  /// 「音源失败 → 自动跳过」的连击计数，达到上限后停止（防死循环，对齐本机连续失败上限）。
  int _failStreak = 0;
  /// 自动跳过上限：连续失败达到该值即不再自动跳，避免坏源无限循环。
  static const int _maxCastFailStreak = 8;

  /// 投屏播放模式(order|one|all|shuffle),默认列表循环(对齐链路 A cast.playMode)。
  String _playMode = 'all';

  /// 当前已通过 SetNext 预置到设备的「下一首」下标(按播放模式计算),用于自动续播时对齐游标。
  int? _provisionedIndex;

  /// 最近一次自动续播/切歌的时间戳,用于轮询检测与曲末定时器之间互斥——
  /// 避免两者都判定「播放结束」而重复推进到同一首的下下首。
  DateTime? _lastCompletionAdvance;

  /// 按已知剩余时长前置的「曲末到点」一次性定时器：到点做收尾复核并续播。
  /// 目的：把续播从「被动等 2s 轮询恰好撞上曲末那一下」改成「按已知总长准点触发」，
  /// 即便轮询被节流到若干秒一帧，只要进程仍活着，曲毕那一刻也能及时推进下一首。
  Timer? _endScheduler;

  /// 当前曲目的真实时长(秒)。来自 DlnaCastTrack.duration(Song.duration),未知为 0。
  /// 用于设备不报时长(RawHTTP)时基于墙钟兜底的自动续播与播控进度。
  int _currentRealDuration = 0;

  /// 自当前曲目开始播放以来累计的实际播放秒数(墙钟推进,不受设备上报影响)。
  /// 部分 DLNA 设备对 RawHTTP 流回报 duration=0/position=0,轮询与曲末定时
  /// 均不可靠;此墙钟成为「放完→自动下一首」最稳妥的依据。
  double _playbackElapsed = 0;

  /// 最近一次“连续播放”段的开始时间锚点;暂停/异常停止时置 null,播放时更新。
  DateTime? _playSegmentStart;

  /// 状态轮询帧计数：用于「音量/静音」降频(不必每帧都读)，减轻慢设备单帧耗时，
  /// 保证首尾「状态+进度」这两路关键检测每帧都足够快地完成。
  int _pollCount = 0;

  /// 每 N 帧读一次音量/静音(RenderingControl)；其余帧跳过，只读检测所需状态/进度。
  static const int _volumeEveryNPolls = 4;

  /// 设备上报位置是否连续多帧停滞(用于「卡在 PLAYING 不推进」的曲末硬触发)。
  int _positionStaleFrames = 0;
  double _lastDevicePosition = -1;

  /// 位置回绕判定阈值(秒)：上报位置相对上一帧「回退」超过该值(如 300s→290s)，
  /// 视为设备自环/重播而非停滞，仅清空停滞计数、不计入曲末硬触发。
  static const double _positionWrapDrift = 5.0;

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

  /// 当前投屏路径档位（A 直传 / B CDS）。
  DlnaCastPath get castPath => _castPath;

  /// 当前设备能力（探测结果，供 UI 展示 / 测试断言）。
  DeviceCapability get capability => _capability;

  /// 设备是否自主循环整队列。A 档·直传直连下客户端逐首续播，恒为 false。
  bool get isSelfLooping => false;

  /// 设置投屏播放模式(对齐链路 A cast.playMode):列表循环 all/顺序 order/单曲 one/随机 shuffle。
  void setPlayMode(String mode) {
    if (!const <String>['order', 'one', 'all', 'shuffle'].contains(mode)) {
      return;
    }
    _playMode = mode;
  }

  // ==================== 初始化 ====================

  /// 初始化 DLNA 管理器（A 档·直传直连）
  /// [streamUrlBuilder] 根据 songId 构建**服务端直接可拉的流 URL**（异步，先换无鉴权
  /// token），交给 DLNA 设备让其自拉流播放（设备不连本机，直连服务器）。
  Future<void> init({
    required Future<String> Function(String songId) streamUrlBuilder,
  }) async {
    if (_initialized) return;

    _streamUrlBuilder = streamUrlBuilder;

    // 启动被动监听
    _discovery.startListening(
      onDeviceUpdate: (location, alive) {
        _handleSsdpEvent(location, alive);
      },
    );

    _initialized = true;
  }

  /// 为 songId 生成交给 DLNA 设备的直接可拉流 URL（A 档·直传直连）。
  /// 先经服务端换一次性无鉴权 token（见 SubsonicApiClient.getDlnaCastStreamUrl），
  /// 返回的 URL 无 `u/t/s` 鉴权，设备自拉流，不经本机。
  Future<String> _directStreamUrl(String songId) => _streamUrlBuilder!(songId);

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

  /// 开始投屏：投整个队列（A 档·直传直连）。
  /// 把每首歌的服务端直连流 URL 依次 Set 给设备，设备自拉流；客户端看门狗自动续播。
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

    // 能力探测：A 档·直传直连恒走 DlnaCastPath.direct（客户端逐首 Set + 轮询续播）。
    _capability = await _probeDevice(device);
    _castPath = DlnaCastPath.direct;

    _currentDevice = device;
    _queue = List.of(tracks);
    _queueIndex = startIndex;
    _nextSupported = true;
    _provisionedIndex = null;
    _userPaused = false;
    _stallCount = 0;
    _failStreak = 0;

    try {
      await _playCurrentTrack();
      _startStatusPolling();
      // 后台保活由投屏 Provider 层统一负责（原生 PARTIAL 唤醒锁 + 直投保活前台服务），
      // 此处不重复持有，避免多路唤醒锁/资源互相干扰。
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
    await _playSwitch();
  }

  /// 下一首（按播放模式:all 循环 / shuffle 随机 / order&one 线性不循环末首）
  Future<void> next() async {
    if (_queue.isEmpty) return;
    switch (_playMode) {
      case 'shuffle':
        if (_queue.length <= 1) return;
        _queueIndex = _randomOtherIndex();
        await _playSwitch();
      case 'all':
        if (_queue.length <= 1) return;
        _queueIndex = (_queueIndex + 1) % _queue.length;
        await _playSwitch();
      default: // order / one
        if (_queueIndex + 1 < _queue.length) {
          _queueIndex++;
          await _playSwitch();
        }
    }
  }

  /// 上一首
  Future<void> previous() async {
    if (_queueIndex - 1 >= 0) {
      _queueIndex--;
      await _playSwitch();
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

  /// 播放队列中的当前曲目（A 档·直传直连：设服务端直连 URL/播）+ 预置下一首
  Future<void> _playCurrentTrack() async {
    final device = _currentDevice!;
    final track = _queue[_queueIndex];
    // A 档：先换无鉴权 token 流 URL，再交给设备自拉流。
    final url = await _directStreamUrl(track.songId);
    final metadata = _buildDidlLite(
      title: track.title,
      uri: url,
      mime: track.mimeHint ?? 'audio/mpeg',
      artist: track.artist,
      album: track.album,
    );

    // 新一轮主动播放：记录真实时长并重置墙钟播放进度（自动续播/播控进度依据）。
    _currentRealDuration = track.duration ?? 0;
    _restartPlaybackClock();

    // 新一轮主动播放：清除用户暂停态与失败连击（对齐链路 A「成功开播即清零」）。
    _userPaused = false;
    _failStreak = 0;
    _stallCount = 0;

    await SoapControl.stop(device.avTransportUrl!);
    // 尽力而为：单步失败不阻断后续关键动作。尤其曲毕主动续播时，若 Set 一次失败，
    // 仍继续尝试 Play，且交给下一轮轮询由 deviceEnded 兜底重推，避免「播放结束停止」。
    try {
      await SoapControl.setAvTransportUri(device.avTransportUrl!, url, metadata);
    } catch (e) {
      debugPrint('DLNA 设置 URI 失败: ${track.title} $e');
    }
    try {
      await SoapControl.play(device.avTransportUrl!);
    } catch (e) {
      debugPrint('DLNA Play 失败: ${track.title} $e');
    }
    // 记录本次(主动/自动)切歌时刻，供轮询续播检测 1.5s 内互斥，避免切歌后
    // 设备短暂处于非播态时被 deviceEnded/曲末定时重复推进到下一首。
    _lastCompletionAdvance = DateTime.now();

    // 预置下一首（设备支持 SetNext 则无缝续播）
    await _provisionNextTrack();

    // 新一轮主动播放：把本地合成状态刷成「新曲刚开播(进度 0)」。此行必须在切换
    // 之后立即执行——否则下一帧轮询会在 prev(nearEnd/prevPosition) 里读到旧曲的
    // 「近尾」状态(near=true 且新曲进度小→started=true)，误走 _alignToNext 再推一档，
    // 造成游标/设备实际播放错位(跳过头或重复推进)。
    _currentStatus = DlnaDeviceStatus(
      state: 'PLAYING',
      position: 0,
      duration:
          _currentRealDuration > 0 ? _currentRealDuration : _currentStatus.duration,
      volume: _currentStatus.volume,
      muted: _currentStatus.muted,
    );

    onTrackChanged?.call(_queueIndex);
  }

  /// 用户主动切歌的统一入口：A 档·直传直连下逐首重放当前曲。
  ///
  /// 所有切歌（播放某曲/下一首/上一首/自动续播）都经由此入口串行化：
  /// 快速连点或看门狗与 UI 并发时，上一轮切歌未落地前不重叠下发，
  /// 避免在途 SetAVTransportURI 被下一次切换打断 —— 修复极短间隔重复
  /// 触发导致的 `Connection aborted` / 播放被中断（issue #1）。
  Future<void> _playSwitch() async {
    final next = _pendingSwitchFuture.then((_) => _playCurrentTrack());
    // 链尾吞掉异常，避免一条切歌失败导致整条链后续动作全部中断。
    _pendingSwitchFuture = next.catchError((_) {});
    await next;
  }

  /// 设备能力探测：A 档·直传直连只要一根 AVTransport 即可逐首 Set。
  ///  - supportsDirectHttp：仅 AVTransport 存在即视为可直连服务端 URL 自拉流（A 档前提）。
  ///  - supportsSetNext / reportsDuration：开播前无法可靠预判，走惰性探测
  ///    （SetNext 以首次调用成功确立 _nextSupported；RawHTTP 时长以墙钟兜底），
  ///    此处给保守默认，避免一次过重的实探拉长投屏启动。
  Future<DeviceCapability> _probeDevice(DlnaDevice device) async {
    return DeviceCapability(
      supportsDirectHttp: device.avTransportUrl != null,
      supportsSetNext: false,
      reportsDuration: false,
    );
  }

  /// 预置下一首到 SetNextAVTransportURI（按播放模式选择要无缝续播的曲目；
  /// 设备不支持 SetNext 则回退为手动切歌）。同时记录 _provisionedIndex 供自动续播对齐游标。
  Future<void> _provisionNextTrack() async {
    if (!_nextSupported) return;
    if (_castPath != DlnaCastPath.direct) return; // 仅 A 档·直传直连做逐首预置。
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
    // A 档：预置下一首同样用无鉴权 token 流 URL。
    final url = await _directStreamUrl(next.songId);
    final metadata = _buildDidlLite(
      title: next.title,
      uri: url,
      mime: next.mimeHint ?? 'audio/mpeg',
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

  /// 手动清理 App 时释放「客户端保活」而不干预设备：停止状态轮询与曲末调度，
  /// 并摘掉对外回调。设备继续把当前曲放完自然结束即可，客户端不再自动切下一首。
  void detachClientKeepalive() {
    _stopStatusPolling();
    _endScheduler?.cancel();
    _endScheduler = null;
    _playSegmentStart = null;
    onStatusChanged = null;
    onTrackChanged = null;
    onCastDisconnected = null;
  }

  void _clearCastState() {
    _endScheduler?.cancel();
    _endScheduler = null;
    _queue = [];
    _queueIndex = -1;
    _nextSupported = true;
    _currentDevice = null;
    _provisionedIndex = null;
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
      _userPaused = true;
      _endScheduler?.cancel(); // 暂停即取消曲末到点定时器，恢复时由轮询重排
      _playSegmentStart = null; // 暂停期间墙钟不计入播放时长
      _currentStatus = _currentStatus.copyWith(state: 'PAUSED');
      onStatusChanged?.call(_currentStatus);
    } catch (_) {}
  }

  /// 恢复播放
  Future<void> resume() async {
    if (_currentDevice?.avTransportUrl == null) return;
    try {
      await SoapControl.play(_currentDevice!.avTransportUrl!);
      _userPaused = false;
      _playSegmentStart = DateTime.now(); // 从恢复时刻继续累计播放时长
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
    // 播放(服务端直连流未断),游标保持指向同位置(即下一首),避免越界。
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
    // 服务端直连 URL 按 songId 即时生成,无需缓存会话;重算下一首以匹配新顺序。
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
    if (_polling) return;
    _polling = true;

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

      // 获取音量（降频：每 4 帧(约 8s)读一次，避免慢设备每帧被 RenderingControl
      // 拖慢，保证状态/进度两路关键检测帧足够快，不错过曲末窗口）。
      int volume = _currentStatus.volume;
      bool muted = _currentStatus.muted;
      _pollCount++;
      if (_currentDevice?.renderingControlUrl != null &&
          _pollCount % _volumeEveryNPolls == 0) {
        try {
          volume = await SoapControl.getVolume(
            _currentDevice!.renderingControlUrl!,
          );
          muted = await SoapControl.getMute(
            _currentDevice!.renderingControlUrl!,
          );
        } catch (_) {}
      }

      // 按墙钟累计实际播放时长：**以客户端自己的时钟为准**，不再依赖设备上报的 state。
      // 原因：部分渲染器（尤其 RawHTTP）会一直报 PLAYING 或一直报 STOPPED，导致原「仅
      // PLAYING 计时」的墙钟要么不启动、要么中途停摆，曲末检测随之失效，表现为「播放
      // 结束不推下一首」。现在只要曲段锚点未重置就无条件累加墙钟；暂停由 pause() 置
      // _userPaused + 置空锚点停表；切歌/续播由 _restartPlaybackClock() 清零重起。
      final now = DateTime.now();
      final anchor = _playSegmentStart;
      if (anchor != null) {
        _playbackElapsed += now.difference(anchor).inMilliseconds / 1000.0;
      }
      _playSegmentStart = now;
      if (state == 'PLAYING') {
        // 设备正常播放中：清除曲中段停止连击，避免把跳转/短暂切换误判为失败。
        _stallCount = 0;
      }

      // 设备和播控中心都需要的有效进度：设备不报时长/位置(RawHTTP)时退回墙钟，
      // 保证即便设备回报 0，播控进度条与全屏进度也能持续前进。
      final effectivePosition = posInfo.position > 0
          ? posInfo.position
          : _playbackElapsed.round();
      final effectiveDuration = posInfo.duration > 0
          ? posInfo.duration
          : _currentRealDuration;

      _currentStatus = DlnaDeviceStatus(
        state: state,
        position: effectivePosition,
        duration: effectiveDuration,
        volume: volume,
        muted: muted,
      );

      // 设备上报位置停滞跟踪：PLAYING 且位置>0 时，若连续多帧位置不推进则记录停滞；
      // 用于「设备一直报 PLAYING 但实际已放完(位置卡死/重复回绕)」的场景。切歌/暂停时复位。
      // 位置出现明显回退(如 300s→290s)视为设备自环/重播而非停滞，仅清空计数不触发曲末。
      if (state == 'PLAYING' && posInfo.position > 0) {
        final pos = posInfo.position.toDouble();
        final wrapped = _lastDevicePosition >= 0 &&
            pos < _lastDevicePosition - _positionWrapDrift;
        if (wrapped) {
          _positionStaleFrames = 0;
        } else if (pos == _lastDevicePosition) {
          _positionStaleFrames += 1;
        } else {
          _positionStaleFrames = 0;
        }
        _lastDevicePosition = pos;
      } else {
        _positionStaleFrames = 0;
        _lastDevicePosition = -1;
      }

      // 自动续播检测：优先处理「设备已自切(SetNext)」与「已续播互斥」，否则曲末
      // 一律由客户端主动 `SetAVTransportURI(下一首直链) → Play` 推下一首。
      final nearEnd = prevState == 'PLAYING' &&
          prevDuration > 0 &&
          prevDuration - prevPosition <= 3;
      final startedOver = state == 'PLAYING' &&
          posInfo.position >= 0 &&
          posInfo.position < 5;

      // 有效时长：优先真实时长(Song.duration)，未知时退回设备 GetPositionInfo 上报的
      // TrackDuration 并回填 _currentRealDuration，确保往后各帧的墙钟兜底(wallDone)也能
      // 据此判定「放完 → 主动推下一首」，而不必等下个设备近尾回报。
      final advanceDuration = _currentRealDuration > 0
          ? _currentRealDuration
          : (posInfo.duration > 0 ? posInfo.duration : 0);
      if (_currentRealDuration <= 0 && advanceDuration > 0) {
        _currentRealDuration = advanceDuration;
      }

      // 墙钟兜底：已按有效时长播完（即便设备 RawHTTP 不报时长/位置）。到点即推。
      final wallDone = !_userPaused &&
          advanceDuration > 0 &&
          _playbackElapsed >= advanceDuration - 0.5;

      // 剩余时长(秒)：优先设备上报，退回墙钟/真实时长。据此前置「曲末到点」定时器，
      // 把续播从「被动等 2s 轮询撞上曲末」改成「按已知总长准点触发」。
      final remaining = posInfo.duration > 0
          ? (posInfo.duration - posInfo.position).toDouble()
          : (advanceDuration > 0
              ? (advanceDuration - _playbackElapsed).toDouble()
              : null);
      _rescheduleEndTimer(remaining, _queueIndex);

      // 设备自然放停：上一帧在播、本帧非播放/暂停，且非用户暂停。
      // 判定依据改用墙钟「确已实质播放过若干秒(playedEnough)」：修复曲毕正好落在
      // 轮询间隔之间时——上一帧距结束>3s 使 nearEnd 不触发、`clearlyMidTrack` 又拦截
      // deviceEnded、且设备停播后 `_playbackElapsed` 冻结在时长阈值之下让 wallDone 悬空——
      // 三路检测全部落空，导致「播放结束停止」。只要设备放完后停播且确已播放过，
      // 一律视为曲末，主动推下一首（刚开播即失败的短曲仍由下方 stall 分支兜底）。
      final playedEnough = _playbackElapsed >= 3.0;
      // 曲是否确已到尾：设备位置已抵近结束(如 259/259)，或墙钟已推进到有效时长末尾。
      // 不校验「到尾」就触发 deviceEnded 会把曲中段的 UNKNOWN(设备状态解析失败/慢响应)
      // 或 STOPPED 误判为「放完 → 推下一首」——实测 7s/185s、28s/279s、54s/320s
      // 就被急着切歌。此时应归入下方 _stallCount 曲中异常停播兜底(连停两次才跳)。
      final nearTrackEnd = (posInfo.duration > 0 &&
              posInfo.position >= posInfo.duration - 3.0) ||
          (advanceDuration > 0 &&
              _playbackElapsed >= advanceDuration - 3.0);
      // 时长是否可知：优先歌曲真实时长，退回设备上报。rawHTTP/纯 renderer(HiVi)常
      // 恒报 duration/position=0 且歌曲时长未知，此时无法用 nearTrackEnd 校验曲末——
      // 只能凭「确已实质播放过≥3s 后设备自然转停」判断放完，主动推下一首(deviceEnded)。
      // 已知时长则必须抵近末尾再推，避免把曲中段的 UNKNOWN/STOPPED 误判为放完(7s/185s
      // 等实测在播即切曲的回归)。二者只在「时长未知」这一种情况下放宽该闸。
      final durationKnown = posInfo.duration > 0 || _currentRealDuration > 0;
      final deviceEnded = !_userPaused &&
          prevState == 'PLAYING' &&
          state != 'PLAYING' &&
          state != 'PAUSED' &&
          playedEnough &&
          (durationKnown ? nearTrackEnd : true);

      // 曲末硬触发：设备一直报 PLAYING、但上报位置已连续多帧停滞(卡住不动/重复回绕)，
      // 且墙钟已推进到曲末附近——判定实际已放完，强制推下一首（覆盖「报 PLAYING 永不
      // 停播」的异常设备）。B 档自循环设备不在此列（advance 分支另行把关）。
      final positionStuck = !_userPaused &&
          state == 'PLAYING' &&
          advanceDuration > 0 &&
          _playbackElapsed >= advanceDuration - 4.0 &&
          _positionStaleFrames >= 2;

      // 最近 2s 内已续播过一次 → 本轮轮询仅回写状态、不再重复推进/对齐
      // （避免「近尾主动推」与「墙钟/设备停播」两路检测对同一曲重复推进到下一首）。
      final freshlyAdvanced = _isCompletionAdvanceFresh();

      // 设备已自循环整队列(B1 CDS/B2 连续流)时，客户端退化为纯遥控，不做逐首续播/看门狗。
      final selfLooping = false;

      // —— 自动续播决策追踪（排障用）——
      // 直投若出现「播放结束不推下一首」，靠此日志可定位三路触发(曲末/墙钟/自然停播)
      // 具体卡在哪一路、以及 device 上报的 position/duration/状态是否可用。
      // 走 Logger 内建缓冲：即便 release 也能在「诊断日志」窗口直接查看(控制台按级别过滤)。
      Logger.debugWithTag('DLNA-AUTO',
          'cur=$_queueIndex real=${_currentRealDuration}s '
          'elapsed=${_playbackElapsed.toStringAsFixed(1)}s '
          'prev($prevState ${prevPosition}s/${prevDuration}s) '
          'now($state ${posInfo.position}s/${posInfo.duration}s) '
          'adv=$advanceDuration near=$nearEnd started=$startedOver '
          'wall=$wallDone devEnd=$deviceEnded stuck=$positionStuck '
          'played=$playedEnough '
          'loop=$selfLooping fresh=$freshlyAdvanced '
          'paused=$_userPaused next=$_provisionedIndex');

      // 续播动作相互隔离：任一续播/对齐步骤抛错不得中断本帧的状态回写与后续轮询，
      // 否则会静默丢帧、错过下一轮续播判定。
      try {
        if (freshlyAdvanced) {
          // 已续播，交给下一轮轮询跟随新曲进度。
        } else if (!selfLooping &&
            nearEnd &&
            startedOver &&
            posInfo.position > 0) {
          // 设备已自行切到预置的下一首(SetNext 生效)——仅对齐游标与重算预置，避免重复下发。
          // 仅当设备上报有效位置(>0)时才信任其已真正切歌(RawHTTP 恒报 position=0，无法感知
          // 是否自切，须走下方 advance 由客户端主动推新 URI，否则游标前移而设备仍卡在旧曲)。
          await _alignToNext();
        } else if (!selfLooping &&
            (nearEnd || wallDone || deviceEnded || positionStuck)) {
          // 曲已到尾/已放完：客户端主动按播放模式推下一首直链(SetAVTransportURI → Play)。
          Logger.infoWithTag('DLNA-AUTO',
              '-> 触发续播 advance($_queueIndex) '
              'triggers: near=$nearEnd wall=$wallDone devEnd=$deviceEnded '
              'stuck=$positionStuck');
          await _advanceAfterCompletion();
        } else if (!_userPaused &&
            prevState == 'PLAYING' &&
            prevPosition > 0 &&
            prevDuration > 0 &&
            prevDuration - prevPosition > 5 &&
            state != 'PLAYING' &&
            state != 'PAUSED') {
          // 曲中段设备异常停止（拉流失败/音源中断）→ 自动跳过兜底。
          _stallCount++;
          if (_stallCount >= 2) {
            _stallCount = 0;
            await _handleCastPlaybackError();
          }
        } else {
          // 其余：暂停/跳转/同曲未到尾等，不触发任何续播/跳过。
          _stallCount = 0;
        }
      } catch (e) {
        Logger.errorWithTag('DLNA-AUTO', '续播动作异常', e);
      }

      onStatusChanged?.call(_currentStatus);
    } catch (e) {
      // 设备可能离线
      debugPrint('DLNA 状态轮询失败: $e');
    } finally {
      _polling = false;
    }
  }

  /// 设备已自行切到下一首（SetNext 自续播）时：仅对齐游标并重算预置，不重复下发播放。
  /// 无论是否真的切歌，都要重启墙钟并刷新互斥标记，避免 wallDone/曲末定时二次推进。
  Future<void> _alignToNext() async {
    final nextIndex = _provisionedIndex ?? (_queueIndex + 1);
    _restartPlaybackClock();
    _lastCompletionAdvance = DateTime.now();
    if (nextIndex < 0 ||
        nextIndex >= _queue.length ||
        nextIndex == _queueIndex) {
      return; // 单曲循环等自循环场景：仅重置墙钟与互斥标记。
    }
    _queueIndex = nextIndex;
    _currentRealDuration =
        _queue[_queueIndex].duration ?? _currentRealDuration;
    // 设备自切到新曲后同样立即刷新合成状态为「新曲刚开播(进度 0)」，
    // 避免下一帧轮询仍在 prev 读到旧曲近尾状态而再次触发对齐/推进(跳过头)。
    _currentStatus = DlnaDeviceStatus(
      state: 'PLAYING',
      position: 0,
      duration:
          _currentRealDuration > 0 ? _currentRealDuration : _currentStatus.duration,
      volume: _currentStatus.volume,
      muted: _currentStatus.muted,
    );
    onTrackChanged?.call(_queueIndex);
    await _provisionNextTrack();
  }

  /// 当前曲已到尾后的主动续播：按播放模式切到下一首/单曲循环。
  /// （对齐本机 `completed → shuffle/one/next` 分支；不依赖设备 SetNext 支持。）
  Future<void> _advanceAfterCompletion() async {
    if (_currentDevice == null || _queue.isEmpty) return;

    if (_playMode == 'one') {
      // 单曲循环：重放当前曲。
      await _playSwitch();
      return;
    }

    if (_playMode == 'shuffle') {
      if (_queue.length <= 1) return;
      _queueIndex = _randomOtherIndex();
    } else if (_playMode == 'all') {
      if (_queue.length <= 1) return;
      _queueIndex = (_queueIndex + 1) % _queue.length;
    } else {
      // order
      if (_queueIndex + 1 >= _queue.length) {
        return; // 队列末尾：保持停止（对齐本机 `state.hasNext` 为否时不再切歌）
      }
      _queueIndex++;
    }
    await _playSwitch();
    onTrackChanged?.call(_queueIndex);
    // 记录本次自动续播时间,供轮询/曲末定时检测互斥(1.5s 内不重复推进)。
    _lastCompletionAdvance = DateTime.now();
  }

  /// 最近 1.5s 内是否已做过一次自动续播/切歌（用于多路续播检测间互斥）。
  /// 取 1.5s 而非 2s：轮询周期恰为 2s，若也用 2s 会与下一帧边界几近重叠，
  /// 慢帧时易在「已推进」判定边缘重新放行导致双推/跳曲。
  bool _isCompletionAdvanceFresh() {
    final t = _lastCompletionAdvance;
    return t != null &&
        DateTime.now().difference(t).inMilliseconds < 1500;
  }

  /// 按当前曲剩余时长重排「曲末到点」一次性定时器。
  /// 到点后若仍是同一曲且在播/未暂停，则触发一次轮询，由轮询走确定性续播判据真正推下一首。
  /// 每个轮询帧都会用最新剩余时长重建，并对齐到当帧下标，防止旧曲残留定时器误触发。
  void _rescheduleEndTimer(double? remaining, int queueIndex) {
    _endScheduler?.cancel();
    // 已到曲末（剩余过短）或暂停/自循环：不排额外定时，交给轮询立即续播。
    if (remaining == null ||
        remaining <= 0.5 ||
        _userPaused ||
        isSelfLooping) {
      return;
    }
    _endScheduler = Timer(
      Duration(milliseconds: ((remaining - 0.2) * 1000).round()),
      () {
        // 到点时仅当仍是同一曲、未暂停、设备仍在投屏才触发收尾轮询；否则丢弃。
        if (_queueIndex == queueIndex &&
            !_userPaused &&
            _currentDevice?.avTransportUrl != null) {
          _pollStatus();
        }
      },
    );
  }

  /// 重启墙钟播放时钟：清空已累计播放时长，并从当前时刻重新起算。
  /// 用于「新一轮播放」开始时（手动切歌/自动续播/设备自切后对齐）。
  void _restartPlaybackClock() {
    _playbackElapsed = 0;
    _playSegmentStart = DateTime.now();
  }

  /// 播放失败/流中断兜底：记连击，达到上限则停止（防坏源死循环）；
  /// 否则自动跳到按播放模式计算的下一首（对齐链路 A 的失败自动跳过）。
  Future<void> _handleCastPlaybackError() async {
    _failStreak++;
    if (_failStreak >= _maxCastFailStreak) {
      // 连续失败过多：停止自动跳过，保持在当前（待机/停止）状态。
      return;
    }
    await _advanceAfterCompletion();
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
    _devices.clear();
    _initialized = false;
  }
}
