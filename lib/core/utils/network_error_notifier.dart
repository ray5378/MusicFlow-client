import 'dart:async';

import '../design/components/music_flow_message.dart';
import 'toast_notifier.dart';

/// 网络异常提示（带节流，避免同一时刻重复弹出）。
///
/// 为避免「应用刚打开」时因探测/首屏请求尚未就绪而立刻误报连接失败，
/// 自 [markAppStarted] 起的 [startupGrace] 秒内，错误会先进入「待确认」
/// 阶段：只有持续连接不上、期间未恢复时才真正弹出提示；若其间连接恢复
/// （调用 [cancelPending]），则取消该提示。
class NetworkErrorNotifier {
  /// 启动后延迟确认的时长：只有持续连接不上才弹出提示。
  static const Duration startupGrace = Duration(seconds: 10);

  /// 同一时刻重复提示的节流窗口。
  static const Duration _throttle = Duration(seconds: 2);

  static DateTime? _startedAt;
  static DateTime? _lastShownAt;
  static DateTime? _pendingSince;
  static Timer? _pendingTimer;
  static String? _pendingMessage;

  /// 在应用启动时调用一次，开启启动宽限期。
  ///
  /// 未调用时保持旧的即时提示行为（测试/非启动场景兼容）。
  static void markAppStarted() {
    _startedAt ??= DateTime.now();
  }

  static void show([String message = '网络异常']) {
    final now = DateTime.now();
    final start = _startedAt;
    if (start != null && now.difference(start) < startupGrace) {
      _schedulePending(now, message);
      return;
    }
    _showNow(now, message);
  }

  static void _schedulePending(DateTime now, String message) {
    _pendingMessage = message;
    if (_pendingTimer != null) {
      return; // 已有待确认计时，沿用最早触发时间即可
    }
    _pendingSince ??= now;
    final remaining = startupGrace - now.difference(_pendingSince!);
    _pendingTimer = Timer(remaining, () {
      _pendingTimer = null;
      final msg = _pendingMessage ?? '网络异常';
      _pendingMessage = null;
      _pendingSince = null;
      _showNow(DateTime.now(), msg);
    });
  }

  /// 连接已恢复时调用，取消「待确认」的失败提示。
  static void cancelPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingMessage = null;
    _pendingSince = null;
  }

  static void _showNow(DateTime now, String message) {
    final last = _lastShownAt;
    if (last != null && now.difference(last) < _throttle) {
      return;
    }
    _lastShownAt = now;
    ToastNotifier.show(message, kind: MusicFlowMessageKind.error);
  }
}