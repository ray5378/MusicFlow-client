import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/audio_quality_provider.dart';
import 'package:musicflow_client/providers/api_provider.dart';

/// 离线缓存管理器单例（懒初始化；写操作前调用方应先 `await offlineCacheReadyProvider.future`）。
final offlineCacheManagerProvider = Provider<OfflineCacheManager>((ref) {
  final manager = OfflineCacheManager();
  unawaited(manager.init());
  return manager;
});

/// 确保离线缓存已初始化完成（幂等，可多次 await）。
final offlineCacheReadyProvider = FutureProvider<void>((ref) {
  return ref.watch(offlineCacheManagerProvider).init();
});

/// 离线判定：
/// - 物理网络断开（connectivity none）；
/// - 或已探测到地址但处于 failed（不可达）。
///
/// 活跃地址为 null（仍在探测/未配置）时不判为离线，避免冷启动误切缓存。
final isOfflineProvider = Provider<bool>((ref) {
  final netType =
      ref.watch(currentNetworkTypeProvider).valueOrNull ??
      ref.watch(connectivityMonitorProvider).currentNetworkType;
  if (netType == NetworkType.none) return true;
  final addr = ref.watch(activeAddressProvider);
  return addr != null && addr.status == ServerAddressStatus.failed;
});