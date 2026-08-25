import 'package:flutter/material.dart';

import '../design/components/music_flow_message.dart';
import 'logger.dart';

/// MaterialApp 的 ScaffoldMessenger 关键帧（兼容旧用法 / 测试）。
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// 根导航器关键帧：用于在 Widget 树之外也能拿到根 Overlay 弹出右上角 Toast。
final rootNavigatorKey = GlobalKey<NavigatorState>();

class ToastNotifier {
  static const _tag = 'TOAST';
  static String? _pendingMessage;
  static MusicFlowMessageKind _pendingKind = MusicFlowMessageKind.info;

  static void show(
    String message, {
    MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  }) {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) {
      // 导航器尚未就绪：记录下来，等待 flush() 补发。
      _pendingMessage = message;
      _pendingKind = kind;
      return;
    }
    insertMusicFlowToast(overlay, message, kind: kind);
  }

  static void flush() {
    final message = _pendingMessage;
    if (message == null) return;
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) {
      Logger.warnWithTag(_tag, 'MusicFlow toast host is not ready');
      return;
    }
    final kind = _pendingKind;
    _pendingMessage = null;
    _pendingKind = MusicFlowMessageKind.info;
    insertMusicFlowToast(overlay, message, kind: kind);
  }
}