import 'package:flutter/material.dart';

import '../design/components/music_flow_message.dart';
import 'logger.dart';

final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class ToastNotifier {
  static const _tag = 'TOAST';
  static String? _pendingMessage;
  static MusicFlowMessageKind _pendingKind = MusicFlowMessageKind.info;

  static void show(
    String message, {
    MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  }) {
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null) {
      _pendingMessage = message;
      _pendingKind = kind;
      return;
    }
    showEchoMessage(
      messenger.context,
      message,
      kind: kind,
      messenger: messenger,
    );
  }

  static void flush() {
    final message = _pendingMessage;
    if (message == null) return;
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null) {
      Logger.warnWithTag(_tag, 'Echo message host is not ready');
      return;
    }
    final kind = _pendingKind;
    _pendingMessage = null;
    _pendingKind = MusicFlowMessageKind.info;
    showEchoMessage(
      messenger.context,
      message,
      kind: kind,
      messenger: messenger,
    );
  }
}
