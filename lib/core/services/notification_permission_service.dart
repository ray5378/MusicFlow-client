import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:permission_handler/permission_handler.dart';

import 'package:musicflow_client/core/utils/logger.dart';

bool _requested = false;

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
    Logger.debugWithTag('PERMISSION', 'request notification permission failed: $e');
  }
}
