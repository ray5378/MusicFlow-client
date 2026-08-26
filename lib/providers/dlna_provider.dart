import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/dlna/dlna_manager.dart';
import '../core/dlna/dlna_models.dart';
import '../data/models/audio_quality.dart';
import '../data/models/song.dart';
import 'api_provider.dart';
import 'audio_quality_provider.dart';

/// DLNA 原生平台通道（Android：MulticastLock / Android 13+ 附近设备权限）
const MethodChannel _dlnaPlatformChannel = MethodChannel(
  'com.musicflow.app/dlna',
);

int _multicastLockRefs = 0;

/// 持有 Wi-Fi 多播锁（SSDP 需要；引用计数防重叠释放）。仅 Android、幂等。
Future<void> acquireMulticastLock() async {
  if (!Platform.isAndroid) return;
  _multicastLockRefs++;
  try {
    await _dlnaPlatformChannel.invokeMethod('acquireMulticastLock');
  } catch (_) {
    // 通道不可用（如未接原生实现）时静默降级，不阻断扫描/投屏
  }
}

/// 释放 Wi-Fi 多播锁（引用计数归零才真正释放）。仅 Android、幂等。
Future<void> releaseMulticastLock() async {
  if (!Platform.isAndroid) return;
  if (_multicastLockRefs > 0) _multicastLockRefs--;
  if (_multicastLockRefs == 0) {
    try {
      await _dlnaPlatformChannel.invokeMethod('releaseMulticastLock');
    } catch (_) {}
  }
}

/// DLNA 管理器 Provider（单例）
final dlnaManagerProvider = Provider<DlnaManager>((ref) {
  final manager = DlnaManager();
  ref.onDispose(() => manager.dispose());
  return manager;
});

/// 确保链路 B 管理器已初始化（幂等）：接入服务器流 URL 构建
/// 流 URL 复用 `SubsonicApiClient.getStreamUrl`（当前生效音质 maxBitRate），与 just_audio 解耦。
Future<void> ensureDlnaManagerReady(Ref ref) async {
  final manager = ref.read(dlnaManagerProvider);
  await manager.init(
    streamUrlBuilder: (songId) {
      final client = ref.read(subsonicApiClientProvider);
      final quality = ref.read(effectiveQualityProvider);
      return client.getStreamUrl(songId, maxBitRate: quality.maxBitRate);
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

  const DlnaCastState({
    this.currentDevice,
    this.status = const DlnaDeviceStatus(),
    this.isCasting = false,
    this.queue = const [],
    this.currentIndex = -1,
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
    bool clearDevice = false,
  }) {
    return DlnaCastState(
      currentDevice: clearDevice ? null : (currentDevice ?? this.currentDevice),
      status: status ?? this.status,
      isCasting: isCasting ?? this.isCasting,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
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

  DlnaCastNotifier(this._ref) : super(const DlnaCastState()) {
    final manager = _ref.read(dlnaManagerProvider);
    manager.onStatusChanged = (status) {
      state = state.copyWith(status: status);
    };
    manager.onTrackChanged = (index) {
      state = state.copyWith(currentIndex: index);
    };
    manager.onCastDisconnected = () {
      state = state.copyWith(
        clearDevice: true,
        isCasting: false,
        queue: const [],
        currentIndex: -1,
      );
    };
  }

  /// 开始投屏整个队列（链路 B，独立投屏队列）
  Future<bool> startCast(
    DlnaDevice device,
    List<DlnaCastTrack> tracks, {
    int startIndex = 0,
  }) async {
    await ensureDlnaManagerReady(_ref);
    await acquireMulticastLock();
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
      state = state.copyWith(currentDevice: device, isCasting: true);
    } else {
      state = state.copyWith(
        isCasting: false,
        queue: const [],
        currentIndex: -1,
      );
    }
    return success;
  }

  /// 切到队列某首
  Future<void> playAt(int index) async {
    await _ref.read(dlnaManagerProvider).playAt(index);
  }

  /// 下一首
  Future<void> next() async {
    await _ref.read(dlnaManagerProvider).next();
  }

  /// 上一首
  Future<void> previous() async {
    await _ref.read(dlnaManagerProvider).previous();
  }

  /// 停止投屏
  Future<void> stopCast() async {
    await _ref.read(dlnaManagerProvider).stopCast();
    state = state.copyWith(clearDevice: true, isCasting: false);
    await releaseMulticastLock();
  }

  /// 暂停
  Future<void> pause() async {
    await _ref.read(dlnaManagerProvider).pause();
  }

  /// 恢复
  Future<void> resume() async {
    await _ref.read(dlnaManagerProvider).resume();
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