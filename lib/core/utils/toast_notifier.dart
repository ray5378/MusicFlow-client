import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/components/music_flow_message.dart';
import 'package:musicflow_client/core/utils/logger.dart';

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
    // [D-037] 缺陷（严重）：rootNavigatorKey.currentState 内部访问 WidgetsBinding.instance，
    //   绑定未初始化（或已销毁）时抛「Binding has not yet been initialized」，
    //   导致 fetch_with_cache_fallback 的「远程失败 + 无缓存」这条最常见兜底路径在置失败标记前崩掉。
    //   建议：读 currentState 用 try/catch 包住，或先判绑定可用性再取 overlay。
    //   守卫用例：test/providers/api/b30p_fetch_with_cache_fallback_cov_test.dart 兜底失败路径用例。
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