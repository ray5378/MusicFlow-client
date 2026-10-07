import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';

/// 音质设置状态 Provider
final audioQualitySettingsProvider =
    StateNotifierProvider<AudioQualitySettingsNotifier, AudioQualitySettings>(
      (ref) => AudioQualitySettingsNotifier(),
    );

class AudioQualitySettingsNotifier extends StateNotifier<AudioQualitySettings> {
  AudioQualitySettingsNotifier() : super(const AudioQualitySettings()) {
    _load();
  }

  Future<void> _load() async {
    state = await LocalStorage.getAudioQualitySettings();
  }

  Future<void> setWifiQuality(AudioQualityLevel quality) async {
    state = state.copyWith(wifiQuality: quality);
    await LocalStorage.setAudioQualitySettings(state);
  }

  Future<void> setMobileQuality(AudioQualityLevel quality) async {
    state = state.copyWith(mobileQuality: quality);
    await LocalStorage.setAudioQualitySettings(state);
  }

  Future<void> setAutoSwitch(bool value) async {
    state = state.copyWith(autoSwitch: value);
    await LocalStorage.setAudioQualitySettings(state);
  }
}

/// 当前网络类型 Provider（基于 api_provider 中共享的 ConnectivityMonitor）
final currentNetworkTypeProvider = StreamProvider<NetworkType>((ref) async* {
  final monitor = ref.watch(connectivityMonitorProvider);
  // 先同步发出当前值，避免首次订阅时拿到 null（被误判为 none）。
  yield monitor.currentNetworkType;
  yield* monitor.networkTypeStream;
});

/// 当前生效音质 Provider（结合网络类型和设置计算）
final effectiveQualityProvider = Provider<AudioQualityLevel>((ref) {
  final settings = ref.watch(audioQualitySettingsProvider);
  final networkType = ref.watch(currentNetworkTypeProvider);
  final monitorType = ref.watch(connectivityMonitorProvider).currentNetworkType;

  if (!settings.autoSwitch) {
    // 不自动切换时，使用 Wi-Fi 设置作为全局设置
    return settings.wifiQuality;
  }

  // 启动阶段 StreamProvider 可能短暂为 loading，回退到监控器的实时值；
  // 两者都未知（none）时走 switch 的 none 臂按 Wi-Fi 音质处理，避免误用移动网络限码率。
  // （原 none 前置 early-return 与 switch none 臂二选一：保留穷尽 switch，
  //   删除恒不可达的 early-return —— 2026-10-07 死代码清理。）
  final type = networkType.valueOrNull ?? monitorType;
  return switch (type) {
    NetworkType.wifi => settings.wifiQuality,
    NetworkType.mobile => settings.mobileQuality,
    NetworkType.none => settings.wifiQuality,
  };
});
