import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../dlna/dlna_manager.dart';
import '../dlna/dlna_models.dart';

/// DLNA 管理器 Provider（单例）
final dlnaManagerProvider = Provider<DlnaManager>((ref) {
  final manager = DlnaManager();
  ref.onDispose(() => manager.dispose());
  return manager;
});

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
    state = state.copyWith(isScanning: true);
    try {
      final manager = _ref.read(dlnaManagerProvider);
      await manager.scanDevices();
    } finally {
      state = state.copyWith(isScanning: false);
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

/// DLNA 投屏状态
class DlnaCastState {
  final DlnaDevice? currentDevice;
  final DlnaDeviceStatus status;
  final bool isCasting;

  const DlnaCastState({
    this.currentDevice,
    this.status = const DlnaDeviceStatus(),
    this.isCasting = false,
  });

  DlnaCastState copyWith({
    DlnaDevice? currentDevice,
    DlnaDeviceStatus? status,
    bool? isCasting,
    bool clearDevice = false,
  }) {
    return DlnaCastState(
      currentDevice: clearDevice ? null : (currentDevice ?? this.currentDevice),
      status: status ?? this.status,
      isCasting: isCasting ?? this.isCasting,
    );
  }
}

/// DLNA 投屏状态 Provider
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
    manager.onCastDisconnected = () {
      state = state.copyWith(clearDevice: true, isCasting: false);
    };
  }

  /// 开始投屏
  Future<bool> startCast(DlnaDevice device, String songId) async {
    state = state.copyWith(isCasting: true);
    final manager = _ref.read(dlnaManagerProvider);
    final success = await manager.startCast(device, songId);
    if (success) {
      state = state.copyWith(currentDevice: device, isCasting: true);
    } else {
      state = state.copyWith(isCasting: false);
    }
    return success;
  }

  /// 停止投屏
  Future<void> stopCast() async {
    await _ref.read(dlnaManagerProvider).stopCast();
    state = state.copyWith(clearDevice: true, isCasting: false);
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
