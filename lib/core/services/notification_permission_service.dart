import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:permission_handler/permission_handler.dart';

import 'package:musicflow_client/core/utils/logger.dart';

bool _requested = false;
bool _updateRequested = false;

/// Android 13+ 媒体通知权限申请（幂等，全静默失败降级）。
///
/// 背景：audio_service 的 BaseAudioHandler 不只投屏用——**纯本地播放**同样
/// 依赖媒体前台服务通知；Android 13+ 若未授予 POST_NOTIFICATIONS，媒体通知
/// 会被系统抑制，进程退后台即可能被冻结（后台续播/曲末推送随之中断）。
///
/// 只在 Android 上生效（旧版本 API 由插件自动放行；其他平台直接跳过）。
/// 用 [defaultTargetPlatform] 而非 dart:io Platform，避免测试/web 环境踩 io 断言。
Future<void> ensureMediaNotificationPermission() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  if (_requested) return;
  _requested = true;
  try {
    final status = await Permission.notification.request();
    if (!status.isGranted) {
      Logger.infoWithTag(
        'PERMISSION',
        'notification permission not granted: $status',
      );
    }
  } catch (e) {
    // 平台通道不可用（如测试环境）时静默降级，绝不阻断播放链路。
    Logger.debugWithTag(
      'PERMISSION',
      'request notification permission failed: $e',
    );
  }
}

/// Android 13+ **下载进度通知**权限申请，返回是否已授权。
///
/// 与 [ensureMediaNotificationPermission] 刻意分开，两点不同：
///
/// 1. **语义不同**：那个是播放链路的前置条件（拿不到要降级后台策略）；
///    这个纯粹是「进度条能不能显示在通知栏」的体验项 —— 拿不到**绝不阻断**
///    下载，只是提前如实告诉用户「本次下载在通知栏看不到进度」。
/// 2. **必须回传结果**：调用方要据此决定是否显示「去开启」提示，所以不能用
///    `Future<void>` 吞掉结论。
///
/// 同一次会话里只弹一次系统对话框（第二次起直接查当前状态），避免用户每次
/// 点更新都被弹一次权限框。
Future<bool> ensureUpdateNotificationPermission() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  if (_updateRequested) return _notificationGranted();
  _updateRequested = true;
  try {
    final status = await Permission.notification.request();
    if (!status.isGranted) {
      Logger.infoWithTag(
        'PERMISSION',
        'update notification not granted: $status (download continues)',
      );
    }
    return status.isGranted;
  } catch (e) {
    Logger.debugWithTag(
      'PERMISSION',
      'request update notification permission failed: $e',
    );
    return false;
  }
}

/// 打开系统「应用通知」设置页（Android 上用户点了「不再询问」后的唯一出路）。
///
/// 返回是否成功拉起设置页；插件不可用时静默返回 false。
Future<bool> openNotificationPermissionSettings() async {
  try {
    return await openAppSettings();
  } catch (e) {
    Logger.debugWithTag('PERMISSION', 'open app settings failed: $e');
    return false;
  }
}

Future<bool> _notificationGranted() async {
  try {
    return await Permission.notification.isGranted;
  } catch (e) {
    Logger.debugWithTag('PERMISSION', 'read notification status failed: $e');
    return false;
  }
}
