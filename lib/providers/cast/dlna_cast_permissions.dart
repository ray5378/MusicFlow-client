import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:musicflow_client/core/services/notification_permission_service.dart';
import 'package:musicflow_client/core/dlna/dlna_keepalive.dart';
import 'package:musicflow_client/core/utils/logger.dart';

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
  } catch (e) {
    // 通道不可用（如未接原生实现）时静默降级，不阻断扫描/投屏
    Logger.debugWithTag('DLNA-KEEPALIVE', 'acquireMulticastLock failed: $e');
  }
}

/// 释放 Wi-Fi 多播锁（引用计数归零才真正释放）。仅 Android、幂等。
Future<void> releaseMulticastLock() async {
  if (!Platform.isAndroid) return;
  final needRelease = _keepalive.releaseMulticastLock();
  if (!needRelease) return; // 引用数仍在 1 之上，不真正释放
  try {
    await _dlnaPlatformChannel.invokeMethod('releaseMulticastLock');
  } catch (e) {
    Logger.debugWithTag('DLNA-KEEPALIVE', 'releaseMulticastLock failed: $e');
  }
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
  } catch (e) {
    Logger.debugWithTag('DLNA-KEEPALIVE', 'acquireWakeLock failed: $e');
  }
}

/// 释放 PARTIAL WakeLock（引用计数归零才真正释放）。仅 Android、幂等。
Future<void> releaseCastWakeLock() async {
  if (!Platform.isAndroid) return;
  final needRelease = _keepalive.releaseWakeLock();
  if (!needRelease) return; // 引用数仍在 1 之上，不真正释放
  try {
    await _dlnaPlatformChannel.invokeMethod('releaseWakeLock');
  } catch (e) {
    Logger.debugWithTag('DLNA-KEEPALIVE', 'releaseWakeLock failed: $e');
  }
}

/// 后台投屏续播的前置权限/豁免（幂等、全静默失败降级，不阻断投屏）：
///  1. Android 13+ 请求通知权限 —— 音乐播放通知（AudioService 媒体前台服务）
///     若被系统拦截/不显示，进程退回后台即可能被冻结，曲末轮询随之中断。
///  2. 请求电池优化豁免 —— 相对国产 ROM 后台冻结最有效的糖衣手段，
///     用户确认后应用列入白名单，退后台/锁屏仍持续轮询 → 到点准点推下一首。
Future<void> requestBackgroundCastPerms() async {
  // 1) POST_NOTIFICATIONS（Android 13+；旧版本 API 由插件自动放行）
  //    复用全局幂等 helper：本地播放首启已申请过则直接跳过。
  await ensureMediaNotificationPermission();

  // 2) 电池优化豁免（Android 6+；未豁免时弹出系统授权框，用户确认一次即可）
  try {
    final ignoring = await _dlnaPlatformChannel
        .invokeMethod<bool>('isIgnoringBatteryOptimization');
    if (ignoring != true) {
      await _dlnaPlatformChannel.invokeMethod('requestIgnoreBatteryOptimization');
    }
  } catch (e) {
    Logger.debugWithTag('DLNA-KEEPALIVE', 'request battery optimization exemption failed: $e');
  }
}
