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

/// 持有 Wi-Fi 高性能锁（投屏后台保活的另一半）：熄屏后 Wi-Fi 射频不进省电模式。
///
/// **为什么唤醒锁不够**：[acquireCastWakeLock] 只保证 CPU 不挂起 —— Dart 的
/// 300ms 歌词 timer、250ms 平滑进度 tick、2s 状态轮询都还能触发，但每一次
/// HTTP 请求都要过 Wi-Fi。息屏后 Wi-Fi 进 power-save，内网 RTT 从个位数 ms
/// 涨到秒级，状态轮询的 6s 预算直接 TimeoutException。
///
/// 症状：退到后台几秒后，通知栏的进度条/歌词/歌名同时冻住（三者都读轮询结果），
/// 而回前台 Wi-Fi 恢复全速后一切自动接上。这把锁就是针对它。
///
/// 引用计数防重叠释放。仅 Android、幂等。
Future<void> acquireCastWifiLock() async {
  if (!Platform.isAndroid) return;
  final needsHold = _keepalive.acquireWifiLock();
  if (!needsHold) return; // 已持有，引用数增加即可，不重复 acquire
  try {
    await _dlnaPlatformChannel.invokeMethod('acquireWifiLock');
  } catch (e) {
    Logger.debugWithTag('DLNA-KEEPALIVE', 'acquireWifiLock failed: $e');
  }
}

/// 释放 Wi-Fi 高性能锁（引用计数归零才真正释放）。仅 Android、幂等。
Future<void> releaseCastWifiLock() async {
  if (!Platform.isAndroid) return;
  final needRelease = _keepalive.releaseWifiLock();
  if (!needRelease) return; // 引用数仍在 1 之上，不真正释放
  try {
    await _dlnaPlatformChannel.invokeMethod('releaseWifiLock');
  } catch (e) {
    Logger.debugWithTag('DLNA-KEEPALIVE', 'releaseWifiLock failed: $e');
  }
}

/// 投屏保活「锁」的合体入口：唤醒锁（保 CPU）+ Wi-Fi 高性能锁（保射频）。
///
/// 两支锁必须成对持有：只持唤醒锁 → timer 会触发但请求超时；只持 Wi-Fi 锁 →
/// 射频醒着但 CPU 睡下去，timer 根本不跑。两条链路（A 服务端投流 / B 局域网
/// 直投）共用本入口，成对 acquire / release。
///
/// 权限类（通知权限、电池优化豁免）不在本函数里做，见
/// [requestBackgroundCastPerms] —— 那个会弹系统框，只在用户主动发起投屏时调用。
Future<void> acquireCastKeepAlive() async {
  await acquireCastWakeLock();
  await acquireCastWifiLock();
}

/// 释放 [acquireCastKeepAlive] 持有的两支锁（顺序无关，各自引用计数）。
Future<void> releaseCastKeepAlive() async {
  await releaseCastWifiLock();
  await releaseCastWakeLock();
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
