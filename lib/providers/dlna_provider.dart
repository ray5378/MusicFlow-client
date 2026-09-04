import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/dlna/cast_http.dart';
import '../core/dlna/dlna_keepalive.dart';
import '../core/dlna/dlna_manager.dart';
import '../core/utils/logger.dart';
import '../core/dlna/dlna_models.dart';
import '../data/models/audio_quality.dart';
import '../data/models/peer.dart';
import '../data/models/song.dart';
import 'api_provider.dart';
import 'audio_quality_provider.dart';
import 'library_provider.dart';
import 'player_provider.dart';

/// 直投专用 http 拉流基地址；null = 当前媒体库没有可用 http 地址（禁止直投）。
///
/// 规则见 [resolveDlnaCastHttpBase]：交给 DLNA 设备的拉流 URL 一律强制 http
/// （很多 DLNA 设备不支持 https），控制面维持当前线路。watch 当前媒体库 +
/// 活跃地址：编辑媒体库地址 / 探测切换线路都会触发重算，面板打开与每次
/// 换 token 拿到的都是最新判定。
final dlnaCastHttpBaseProvider = Provider<String?>((ref) {
  final library = ref.watch(activeLibraryProvider);
  final active = ref.watch(activeAddressProvider);
  return resolveDlnaCastHttpBase(library: library, activeAddress: active);
});

/// DLNA 原生平台通道（Android：MulticastLock / 电池优化豁免等系统级能力）
const MethodChannel _dlnaPlatformChannel = MethodChannel(
  'com.musicflow.app/dlna',
);

/// 直投后台保活引用计数（纯 Dart，见 DlnaKeepaliveController）。
/// 0→1 才向原生挂锁、1→0 才向原生摘锁，重叠加/减不重复调用原生。
final DlnaKeepaliveController _keepalive = DlnaKeepaliveController();

/// 持有 Wi-Fi 多播锁（SSDP 需要；引用计数防重叠释放）。仅 Android、幂等。
Future<void> acquireMulticastLock() async {
  if (!Platform.isAndroid) return;
  final needsHold = _keepalive.acquireMulticastLock();
  if (!needsHold) return; // 已持有，引用数增加即可，不重复 acquire
  try {
    await _dlnaPlatformChannel.invokeMethod('acquireMulticastLock');
  } catch (_) {
    // 通道不可用（如未接原生实现）时静默降级，不阻断扫描/投屏
  }
}

/// 释放 Wi-Fi 多播锁（引用计数归零才真正释放）。仅 Android、幂等。
Future<void> releaseMulticastLock() async {
  if (!Platform.isAndroid) return;
  final needRelease = _keepalive.releaseMulticastLock();
  if (!needRelease) return; // 引用数仍在 1 之上，不真正释放
  try {
    await _dlnaPlatformChannel.invokeMethod('releaseMulticastLock');
  } catch (_) {}
}

/// 持有 PARTIAL WakeLock（直投后台保活）：屏幕熄灭 / Doze 下 CPU 仍保持活跃，
/// 保证 DLNA 2s 状态轮询 timer 持续触发，曲末看门狗能在后台主动推下一首。
/// 引用计数防重叠释放。仅 Android、幂等。
Future<void> acquireCastWakeLock() async {
  if (!Platform.isAndroid) return;
  final needsHold = _keepalive.acquireWakeLock();
  if (!needsHold) return; // 已持有，引用数增加即可，不重复 acquire
  try {
    await _dlnaPlatformChannel.invokeMethod('acquireWakeLock');
  } catch (_) {}
}

/// 释放 PARTIAL WakeLock（引用计数归零才真正释放）。仅 Android、幂等。
Future<void> releaseCastWakeLock() async {
  if (!Platform.isAndroid) return;
  final needRelease = _keepalive.releaseWakeLock();
  if (!needRelease) return; // 引用数仍在 1 之上，不真正释放
  try {
    await _dlnaPlatformChannel.invokeMethod('releaseWakeLock');
  } catch (_) {}
}

/// 后台投屏续播的前置权限/豁免（幂等、全静默失败降级，不阻断投屏）：
///  1. Android 13+ 请求通知权限 —— 音乐播放通知（AudioService 媒体前台服务）
///     若被系统拦截/不显示，进程退回后台即可能被冻结，曲末轮询随之中断。
///  2. 请求电池优化豁免 —— 相对国产 ROM 后台冻结最有效的糖衣手段，
///     用户确认后应用列入白名单，退后台/锁屏仍持续轮询 → 到点准点推下一首。
Future<void> _requestBackgroundCastPerms() async {
  // 1) POST_NOTIFICATIONS（Android 13+；旧版本 API 由插件自动放行）
  try {
    final status = await Permission.notification.request();
    if (!status.isGranted) {
      Logger.infoWithTag(
        'DLNA-KEEPALIVE',
        l10nNowCurrent().provider_cast_notify_permission,
      );
    }
  } catch (_) {}

  // 2) 电池优化豁免（Android 6+；未豁免时弹出系统授权框，用户确认一次即可）
  try {
    final ignoring = await _dlnaPlatformChannel
        .invokeMethod<bool>('isIgnoringBatteryOptimization');
    if (ignoring != true) {
      await _dlnaPlatformChannel.invokeMethod('requestIgnoreBatteryOptimization');
    }
  } catch (_) {}
}

/// DLNA 管理器 Provider（单例）
final dlnaManagerProvider = Provider<DlnaManager>((ref) {
  final manager = DlnaManager();
  ref.onDispose(() => manager.dispose());
  return manager;
});

/// 确保链路 B 管理器已初始化（幂等）：接入服务端直连流 URL 构建。
/// A 档·直传直连：先经服务端 `getDlnaCastStreamUrl` 换**无鉴权** token 流 URL
/// （`<baseUrl>/rest/dlna/stream/:token`），再交给 DLNA 设备让其直连服务器自拉流。
/// 设备不连本机、无本地中继/监听端口；无鉴权 URL 与 GMediaRender 等渲染器兼容，
/// 避免带 `u/t/s` 鉴权的 /rest/stream URL 被设备拉流失败而无声。
///
/// 强制 http 拉流：换 token 的请求仍走客户端当前连接（https 也可以），
/// 但拼接给设备的流 URL 一律用投流专用 http 基地址（[dlnaCastHttpBaseProvider]），
/// 很多 DLNA 设备不支持 https。无可用 http 地址时抛
/// [DlnaCastHttpUnavailableException]，由 startCast 捕获返回失败——
/// 正常情况下面板打开时已拦截，这里是兜底防线。
Future<void> ensureDlnaManagerReady(Ref ref) async {
  final manager = ref.read(dlnaManagerProvider);
  await manager.init(
    streamUrlBuilder: (songId) async {
      final client = ref.read(subsonicApiClientProvider);
      final quality = ref.read(effectiveQualityProvider);
      final castBase = ref.read(dlnaCastHttpBaseProvider);
      if (castBase == null) {
        throw const DlnaCastHttpUnavailableException();
      }
      final url = await client.getDlnaCastStreamUrl(
        songId,
        maxBitRate: quality.maxBitRate,
      );
      if (url.isEmpty) return '';
      // 回退路径（getStreamUrl 带 u/t/s）同样被 origin 重写覆盖：鉴权参数
      // 与主机无关，重写后仍有效。
      return rewriteUrlToBase(url, castBase);
    },
  );
}

/// 将业务 Song 映射为链路 B 投屏曲目
DlnaCastTrack dlnaCastTrackFromSong(Song song) {
  return DlnaCastTrack(
    songId: song.id,
    title: song.title,
    artist: song.artist,
    album: song.album,
    duration: song.duration,
    mimeHint: song.contentType,
  );
}

/// DLNA 设备列表状态
class DlnaDevicesState {
  final List<DlnaDevice> devices;
  final bool isScanning;

  const DlnaDevicesState({
    this.devices = const [],
    this.isScanning = false,
  });

  DlnaDevicesState copyWith({
    List<DlnaDevice>? devices,
    bool? isScanning,
  }) {
    return DlnaDevicesState(
      devices: devices ?? this.devices,
      isScanning: isScanning ?? this.isScanning,
    );
  }
}

/// DLNA 设备列表 Provider
final dlnaDevicesProvider =
    StateNotifierProvider<DlnaDevicesNotifier, DlnaDevicesState>((ref) {
  return DlnaDevicesNotifier(ref);
});

class DlnaDevicesNotifier extends StateNotifier<DlnaDevicesState> {
  final Ref _ref;

  DlnaDevicesNotifier(this._ref) : super(const DlnaDevicesState()) {
    // 监听管理器的设备变化
    final manager = _ref.read(dlnaManagerProvider);
    manager.onDevicesChanged = (devices) {
      state = state.copyWith(devices: devices);
    };
  }

  /// 扫描设备
  Future<void> scan() async {
    await ensureDlnaManagerReady(_ref);
    await acquireMulticastLock();
    state = state.copyWith(isScanning: true);
    try {
      await _ref.read(dlnaManagerProvider).scanDevices();
    } finally {
      state = state.copyWith(isScanning: false);
      await releaseMulticastLock();
    }
  }

  /// 设置设备别名
  void setAlias(String deviceId, String alias) {
    _ref.read(dlnaManagerProvider).setDeviceAlias(deviceId, alias);
  }

  /// 禁用/启用设备
  void setDisabled(String deviceId, bool disabled) {
    _ref.read(dlnaManagerProvider).setDeviceDisabled(deviceId, disabled);
  }

  /// 删除设备
  void remove(String deviceId) {
    _ref.read(dlnaManagerProvider).removeDevice(deviceId);
  }
}

/// DLNA 投屏状态（链路 B，独立于链路 A cast_peer_provider）
class DlnaCastState {
  final DlnaDevice? currentDevice;
  final DlnaDeviceStatus status;
  final bool isCasting;
  final List<DlnaCastTrack> queue;
  final int currentIndex;

  /// 投屏播放模式(order|one|all|shuffle),对齐链路 A cast.playMode。
  final String playMode;

  /// 平滑进度(秒):插值 tick 递增,设备轮询回写修正 —— 对齐链路 A [CastPeerState]。
  final double smoothPositionSeconds;

  /// 当前投屏路径档位(A direct 直传 / B cdsList CDS 清单)。空则为未投屏。
  final DlnaCastPath? castPath;

  const DlnaCastState({
    this.currentDevice,
    this.status = const DlnaDeviceStatus(),
    this.isCasting = false,
    this.queue = const [],
    this.currentIndex = -1,
    this.playMode = 'all',
    this.smoothPositionSeconds = 0,
    this.castPath,
  });

  /// 当前投屏曲目
  DlnaCastTrack? get currentTrack =>
      currentIndex >= 0 && currentIndex < queue.length
          ? queue[currentIndex]
          : null;

  DlnaCastState copyWith({
    DlnaDevice? currentDevice,
    DlnaDeviceStatus? status,
    bool? isCasting,
    List<DlnaCastTrack>? queue,
    int? currentIndex,
    String? playMode,
    double? smoothPositionSeconds,
    DlnaCastPath? castPath,
    bool clearDevice = false,
  }) {
    return DlnaCastState(
      currentDevice: clearDevice ? null : (currentDevice ?? this.currentDevice),
      status: status ?? this.status,
      isCasting: isCasting ?? this.isCasting,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      playMode: playMode ?? this.playMode,
      smoothPositionSeconds:
          smoothPositionSeconds ?? this.smoothPositionSeconds,
      castPath: castPath ?? this.castPath,
    );
  }
}

/// DLNA 投屏状态 Provider（链路 B）
final dlnaCastProvider =
    StateNotifierProvider<DlnaCastNotifier, DlnaCastState>((ref) {
  return DlnaCastNotifier(ref);
});

class DlnaCastNotifier extends StateNotifier<DlnaCastState> {
  final Ref _ref;

  /// 平滑进度插值 tick:播放中按现实时间递增,设备轮询回写修正(对齐链路 A)。
  Timer? _tickTimer;

  /// 投屏开始时本机的完整歌单(含封面/时长等),供镜像到 playerProvider,
  /// 让全屏页封面跟随 DLNA 设备(等价于链路 A 的后端队列镜像)。
  List<Song>? _sourceQueue;

  /// 曲末提醒的客户端本地 Dart Timer：进程存活期间到点触发，配合曲末看门狗(2s 轮询)
  /// 判定是否推下一首。进程存活时即唯一可靠机制（关闭了 Android 系统闹钟兜底）。
  Timer? _endTimer;

  /// 最近一次预约的唤醒时刻(毫秒)：用于去抖，避免 status 每 2s 更新时反复重设闹钟。
  int _lastHeartbeatTrigger = 0;

  DlnaCastNotifier(this._ref) : super(const DlnaCastState()) {
    final manager = _ref.read(dlnaManagerProvider);

    // 用户手动清理 App（划掉任务）时释放客户端保活：由音频 handler 的
    // onTaskRemoved 触发，避免划掉后仍在后台轮询/持唤醒锁/自动切歌。
    final handler = _ref.read(playerProvider.notifier).audioHandler;
    if (handler != null) {
      handler.onTaskRemovedCallback = detachOnAppRemoved;
    }

    manager.onStatusChanged = (status) {
      state = state.copyWith(
        status: status,
        smoothPositionSeconds: status.position.toDouble(),
      );
      _syncNotificationCast();
      _armEndHeartbeat(status);
    };
    manager.onTrackChanged = (index) {
      state = state.copyWith(currentIndex: index);
      _mirrorCastToLocal();
      _syncNotificationCast();
    };
    manager.onCastDisconnected = () {
      _sourceQueue = null;
      state = state.copyWith(
        clearDevice: true,
        isCasting: false,
        queue: const [],
        currentIndex: -1,
        smoothPositionSeconds: 0,
        castPath: null,
      );
      _stopTick();
      _cancelHeartbeat();
      _disableNotificationCast();
      releaseCastWakeLock();
    };
  }

  /// 将投屏进度同步给系统播控中心（通知/锁屏进度条）：本机已暂停，
  /// 用插值后的 smoothPositionSeconds 驱动，否则播控进度定住在投屏那一刻。
  void _syncNotificationCast() {
    final st = state;
    if (!st.isCasting || st.currentDevice == null) return;
    _ref.read(playerProvider.notifier).updateNotificationCastProgress(
          active: true,
          playing: st.status.state == 'PLAYING',
          position: Duration(seconds: st.smoothPositionSeconds.round()),
        );
  }

  /// 退出投屏态时让播控中心回到本机播放器驱动。
  void _disableNotificationCast() {
    _ref.read(playerProvider.notifier).updateNotificationCastProgress(
          active: false,
          playing: false,
          position: Duration.zero,
        );
  }

  /// App 被用户手动清理（划掉任务）时释放「客户端保活」：停 500ms 平滑 tick、
  /// 取消曲末心跳、释放唤醒锁、隐藏投屏通知，并停止管理器轮询/摘回调。
  /// 不向设备发 STOP——设备把当前曲放完自然结束，客户端不再自动切歌。
  Future<void> detachOnAppRemoved() async {
    _stopTick();
    _cancelHeartbeat();
    releaseCastWakeLock();
    _disableNotificationCast();
    _ref.read(dlnaManagerProvider).detachClientKeepalive();
  }

  /// 把当前投屏队列/游标镜像进 playerProvider,让全屏页的曲目/封面/歌词
  /// 跟随 DLNA 设备(对齐链路 A 经 syncQueueForCast 镜像后端队列),本机不自动播放。
  void _mirrorCastToLocal() {
    if (!state.isCasting) return;
    final queue = _sourceQueue;
    if (queue == null || queue.isEmpty) return;
    final index = state.currentIndex.clamp(0, queue.length - 1);
    final items = queue.map(songToQueueItem).toList();
    _ref.read(playerProvider.notifier).syncQueueForCast(items, index);
  }

  void _startTick() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _advanceSmooth();
    });
  }

  void _stopTick() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  /// 取消曲末提醒（客户端本地 Dart Timer）。
  void _cancelHeartbeat() {
    _endTimer?.cancel();
    _endTimer = null;
    _lastHeartbeatTrigger = 0;
    Logger.debugWithTag('DLNA-HB', 'cancel heartbeat (local Dart timer)');
  }

  /// 按当前曲目剩余时长预约「曲末提醒」——客户端本地 Dart Timer：
  /// 进程存活时到点触发，续播交给曲末看门狗(2s 轮询)处理。
  /// 去抖：status 每 2s 更新，仅当预计唤醒时刻变化 >2s 才重设，减少无谓调度。
  void _armEndHeartbeat(DlnaDeviceStatus status) {
    if (!state.isCasting || status.state != 'PLAYING') {
      Logger.debugWithTag(
        'DLNA-HB',
        'arm skip: isCasting=${state.isCasting} state=${status.state}',
      );
      _cancelHeartbeat();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final durationSec = status.duration;
    int trigger;
    if (durationSec > 0) {
      final remaining = durationSec - status.position;
      if (remaining <= 0) {
        Logger.infoWithTag(
          'DLNA-HB',
          'arm skip: reached end of track duration=${durationSec}s position=${status.position}s remaining=${remaining}s',
        );
        _cancelHeartbeat();
        return;
      }
      // 结束前最多提前 3s 唤醒；至少留 2s 给平台去抖/调度余量。
      final lead = remaining >= 3 ? 3 : remaining;
      trigger = now + ((remaining - lead) * 1000).toInt();
      Logger.debugWithTag(
        'DLNA-HB',
        'arm calc: duration=${durationSec}s position=${status.position}s '
            'remaining=${remaining.toStringAsFixed(1)}s lead=${lead}s '
            'trigger=${DateTime.fromMillisecondsSinceEpoch(trigger).toIso8601String()}',
      );
    } else {
      // 设备不报时长(RawHTTP)：退化到固定间隔兜底，靠看门狗轮询最终收敛。
      trigger = now + 45 * 1000;
      Logger.debugWithTag(
        'DLNA-HB',
        'arm fallback: device duration unknown, fixed 45s heartbeat trigger=${DateTime.fromMillisecondsSinceEpoch(trigger)}',
      );
    }
    final delayMs = (trigger - now).clamp(1000, 24 * 60 * 60 * 1000);
    if ((trigger - _lastHeartbeatTrigger).abs() <= 2000 &&
        _endTimer != null &&
        _endTimer!.isActive) {
      Logger.debugWithTag(
        'DLNA-HB',
        'arm debounce skip: trigger=$trigger last=$_lastHeartbeatTrigger '
            'Δ=${trigger - _lastHeartbeatTrigger}ms keep existing reservation',
      );
      return;
    }
    _lastHeartbeatTrigger = trigger;

    _endTimer?.cancel();
    _endTimer = Timer(Duration(milliseconds: delayMs.toInt()), () {
      // 本地 Dart 计时到点：进程存活。续播是否触发由曲末看门狗(2s 轮询)
      // 依据当前状态判断（已切歌则忽略 / 未切则推下一首）。
      _endTimer = null;
      Logger.infoWithTag(
        'DLNA-HB',
        'local Dart timer fired (process alive) trigger=$trigger',
      );
    });
  }

  /// 播放中按现实时间平滑推进进度(0.5s 步进),设备轮询(2s)回写修正。
  /// 设备不报时长(RawHTTP)时 duration=0,仍须按墙钟推进,否则播控中心进度条
  /// 会定住在投屏那一刻;仅在时长已知时封顶,避免越过曲末等自动续播。
  void _advanceSmooth() {
    final st = state;
    if (!st.isCasting) return;
    final status = st.status;
    if (status.state != 'PLAYING') return;
    final since = st.smoothPositionSeconds + 0.5;
    final next = status.duration > 0
        ? since.clamp(0.0, status.duration.toDouble())
        : since;
    if (next == st.smoothPositionSeconds) return;
    state = st.copyWith(smoothPositionSeconds: next);
    _syncNotificationCast();
  }

  /// 开始投屏整个队列（链路 B，独立投屏队列）
  Future<bool> startCast(
    DlnaDevice device,
    List<DlnaCastTrack> tracks, {
    int startIndex = 0,
  }) async {
    await ensureDlnaManagerReady(_ref);
    await acquireMulticastLock();
    final sourceQueue = List<Song>.of(_ref.read(playerProvider).queue);
    _sourceQueue = sourceQueue;
    state = state.copyWith(
      isCasting: true,
      queue: List.unmodifiable(tracks),
      currentIndex: startIndex,
    );
    final manager = _ref.read(dlnaManagerProvider);
    final success = await manager.startCast(
      device,
      tracks,
      startIndex: startIndex,
    );
    if (success) {
      state = state.copyWith(
        currentDevice: device,
        isCasting: true,
        castPath: manager.castPath,
      );
      // 后台保活（仅 Android）：唤醒锁 + 前台服务双重保障，熄屏/退后台时
      // 进程不被冻结或杀死，2s 轮询持续触发 → 曲毕自动推下一首。
      acquireCastWakeLock();
      await _requestBackgroundCastPerms();
      _mirrorCastToLocal();
      _startTick();
      _syncNotificationCast();
      // 直投进行中，本机退化为「遥控器」：暂停本地播放（不出声），
      // 队列/索引保留，停止投屏时从投屏进度续播。
      // 仅投屏成功后暂停，失败则不打断本机播放。
      await _ref.read(playerProvider.notifier).pause();
    } else {
      _sourceQueue = null;
      state = state.copyWith(
        isCasting: false,
        queue: const [],
        currentIndex: -1,
        smoothPositionSeconds: 0,
      );
      _stopTick();
    }
    return success;
  }

  /// 切到队列某首
  Future<void> playAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _ref.read(dlnaManagerProvider).playAt(index);
    state = state.copyWith(currentIndex: index);
    _mirrorCastToLocal();
  }

  /// 下一首
  Future<void> next() async {
    final manager = _ref.read(dlnaManagerProvider);
    await manager.next();
    if (state.currentIndex != manager.castQueueIndex) {
      state = state.copyWith(currentIndex: manager.castQueueIndex);
      _mirrorCastToLocal();
    }
  }

  /// 上一首
  Future<void> previous() async {
    final manager = _ref.read(dlnaManagerProvider);
    await manager.previous();
    if (state.currentIndex != manager.castQueueIndex) {
      state = state.copyWith(currentIndex: manager.castQueueIndex);
      _mirrorCastToLocal();
    }
  }

  /// 设置投屏播放模式(对齐链路 A cast.setPlayMode)。
  Future<void> setPlayMode(String mode) async {
    final manager = _ref.read(dlnaManagerProvider);
    manager.setPlayMode(mode);
    state = state.copyWith(playMode: mode);
  }

  /// 循环切换投屏播放模式:order → one → all → shuffle(对齐链路 A cast.cyclePlayMode)。
  Future<void> cyclePlayMode() async {
    const modes = <String>['order', 'one', 'all', 'shuffle'];
    final idx = modes.indexOf(state.playMode);
    final next = modes[(idx < 0 ? 2 : idx + 1) % modes.length];
    await setPlayMode(next);
  }

  /// 直投中播放专辑/歌单/列表(对齐链路 A cast.playQueueOnPeer):
  /// 复用本地中转会话,直接切队列播放,本机保持遥控器态不打断。
  Future<bool> playQueueOnDevice(
    List<Song> songs, {
    int startIndex = 0,
  }) async {
    final device = state.currentDevice;
    if (device == null || songs.isEmpty) return false;
    final tracks = songs.map(dlnaCastTrackFromSong).toList();
    final start = startIndex.clamp(0, tracks.length - 1);
    _sourceQueue = List<Song>.of(songs);
    state = state.copyWith(
      isCasting: true,
      queue: List.unmodifiable(tracks),
      currentIndex: start,
      smoothPositionSeconds: 0,
    );
    final manager = _ref.read(dlnaManagerProvider);
    final success = await manager.startCast(device, tracks, startIndex: start);
    if (success) {
      state = state.copyWith(
        currentDevice: device,
        isCasting: true,
        castPath: manager.castPath,
      );
      acquireCastWakeLock();
      await _requestBackgroundCastPerms();
      _mirrorCastToLocal();
      _startTick();
      _syncNotificationCast();
      await _ref.read(playerProvider.notifier).pause();
    } else {
      _sourceQueue = null;
      state = state.copyWith(
        isCasting: false,
        queue: const [],
        currentIndex: -1,
        smoothPositionSeconds: 0,
      );
      _stopTick();
    }
    return success;
  }

  /// 直投中点歌(对齐链路 A cast.playSongOnPeer):
  /// 携带队列上下文按整队播放;否则优先在已投屏队列中跳播,未命中则单曲重投。
  Future<bool> playSongOnDevice(
    Song song, {
    List<Song>? queue,
    int? index,
  }) async {
    if (state.currentDevice == null) return false;
    if (queue != null && queue.isNotEmpty) {
      return playQueueOnDevice(
        queue,
        startIndex: (index ?? 0).clamp(0, queue.length - 1),
      );
    }
    final found = state.queue.indexWhere((t) => t.songId == song.id);
    if (found >= 0) {
      await playAt(found);
      return true;
    }
    return playQueueOnDevice(<Song>[song]);
  }

  /// 投屏中加歌：追加到投屏队列末尾（不中断当前播放，对齐链路 A cast.enqueueSongs）。
  Future<void> enqueueSongs(List<Song> songs) async {
    if (songs.isEmpty || !state.isCasting) return;
    final tracks = songs.map(dlnaCastTrackFromSong).toList(growable: false);
    final manager = _ref.read(dlnaManagerProvider);
    await manager.enqueueSongs(tracks);
    final src = _sourceQueue;
    _sourceQueue = (src == null ? List<Song>.of(songs) : [...src, ...songs]);
    state = state.copyWith(queue: [...state.queue, ...tracks]);
    _mirrorCastToLocal();
  }

  /// 投屏中从队列移除指定下标（播放保持连贯，对齐链路 A cast.removeQueueItem）。
  Future<void> removeQueueItem(int index) async {
    if (!state.isCasting) return;
    final manager = _ref.read(dlnaManagerProvider);
    await manager.removeQueueItem(index);
    final queue = List<DlnaCastTrack>.of(state.queue);
    if (index >= 0 && index < queue.length) queue.removeAt(index);
    final src = _sourceQueue;
    if (src != null && index >= 0 && index < src.length) {
      _sourceQueue = List<Song>.of(src)..removeAt(index);
    }
    state = state.copyWith(
      queue: List.unmodifiable(queue),
      currentIndex: manager.castQueueIndex,
    );
    _mirrorCastToLocal();
  }

  /// 投屏队列拖拽排序 from → to（对齐链路 A cast.reorderQueue）。
  Future<void> reorderQueue(int from, int to) async {
    if (!state.isCasting) return;
    final manager = _ref.read(dlnaManagerProvider);
    await manager.reorderQueue(from, to);
    final queue = List<DlnaCastTrack>.of(state.queue);
    if (from >= 0 &&
        from < queue.length &&
        to >= 0 &&
        to <= queue.length &&
        from != to) {
      final item = queue.removeAt(from);
      queue.insert(to > from ? to - 1 : to, item);
    }
    final src = _sourceQueue;
    if (src != null &&
        from >= 0 &&
        from < src.length &&
        to >= 0 &&
        to <= src.length &&
        from != to) {
      final newSrc = List<Song>.of(src);
      final item = newSrc.removeAt(from);
      newSrc.insert(to > from ? to - 1 : to, item);
      _sourceQueue = newSrc;
    }
    state = state.copyWith(
      queue: List.unmodifiable(queue),
      currentIndex: manager.castQueueIndex,
    );
    _mirrorCastToLocal();
  }

  /// 投屏静音开关。
  Future<void> setMuted(bool muted) async {
    final manager = _ref.read(dlnaManagerProvider);
    if (muted != manager.isMuted) {
      await manager.toggleMute();
    }
  }

  /// 停止投屏
  Future<void> stopCast() async {
    _stopTick();
    _sourceQueue = null;
    // 取消曲末提醒（客户端本地 Dart Timer），避免停止后残留定时器。
    _cancelHeartbeat();
    // 停止前记录投屏当前曲目与进度，用于停止后在本机续播。
    final castIndex = state.currentIndex;
    final castPosition = state.status.position;

    await _ref.read(dlnaManagerProvider).stopCast();
    state = state.copyWith(
      clearDevice: true,
      isCasting: false,
      smoothPositionSeconds: 0,
    );
    await releaseMulticastLock();

    await _resumeLocalPlayback(castIndex: castIndex, position: castPosition);
  }

  /// 停止直投后，把本机恢复到投屏结束时所在曲目/进度并继续播放。
  Future<void> _resumeLocalPlayback({
    int castIndex = -1,
    int position = 0,
  }) async {
    final playerNotifier = _ref.read(playerProvider.notifier);
    final localQueue = _ref.read(playerProvider).queue;
    if (localQueue.isEmpty) return;

    if (castIndex >= 0 && castIndex < localQueue.length) {
      // 先装载投屏结束时所在的本地曲目（不自动播放），再 seek 到投屏进度，
      // 最后开始播放，实现「从当前投屏进度继续放」。
      await playerNotifier.playSong(
        localQueue[castIndex],
        queue: localQueue,
        index: castIndex,
        autoPlay: false,
      );
      if (position > 0) {
        await playerNotifier.seek(Duration(seconds: position));
      }
    }
    await playerNotifier.play();
  }

  /// 暂停
  Future<void> pause() async {
    await _ref.read(dlnaManagerProvider).pause();
  }

  /// 恢复
  Future<void> resume() async {
    await _ref.read(dlnaManagerProvider).resume();
  }

  /// 播放/暂停(对齐链路 A 的 toggle,供全屏播放控件统一路由)。
  Future<void> toggle() async {
    if (state.status.state == 'PLAYING') {
      await pause();
    } else {
      await resume();
    }
  }

  /// 跳转
  Future<void> seek(int seconds) async {
    await _ref.read(dlnaManagerProvider).seek(seconds);
  }

  /// 设置音量
  Future<void> setVolume(int volume) async {
    await _ref.read(dlnaManagerProvider).setVolume(volume);
  }

  /// 静音
  Future<void> toggleMute() async {
    await _ref.read(dlnaManagerProvider).toggleMute();
  }
}