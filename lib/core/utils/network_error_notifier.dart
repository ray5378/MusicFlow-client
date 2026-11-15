import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:musicflow_client/core/design/components/music_flow_message.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';

/// 网络异常提示（带节流，避免同一时刻重复弹出）。
///
/// 为避免「应用刚打开」时因探测/首屏请求尚未就绪而立刻误报连接失败，
/// 自 [markAppStarted] 起的 [startupGrace] 秒内，错误会先进入「待确认」
/// 阶段：只有持续连接不上、期间未恢复时才真正弹出提示；若其间连接恢复
/// （调用 [cancelPending]），则取消该提示。
class NetworkErrorNotifier {
  /// 启动后延迟确认的时长：只有持续连接不上才弹出提示。
  /// 调大以覆盖探测/首屏尚未就绪的更长启动期，避免刚打开就误报。
  static const Duration startupGrace = Duration(seconds: 30);

  /// 同一时刻重复提示的节流窗口。
  /// 调大以降低「线路瞬时抖动」导致的重复弹窗频率。
  static const Duration _throttle = Duration(seconds: 20);

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

  static void show([String? message]) {
    final now = DateTime.now();
    final start = _startedAt;
    final msg = message ?? l10nNowCurrent().core_network_error;
    if (start != null && now.difference(start) < startupGrace) {
      _schedulePending(now, msg);
      return;
    }
    _showNow(now, msg);
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
      final msg = _pendingMessage ?? l10nNowCurrent().core_network_error;
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

  /// 测试专用：清空全部 static 状态（启动宽限期起点、节流时间戳、待确认定时器）。
  ///
  /// **同一文件的第 2 条用例起必须调用**，否则会静默产生假绿：
  /// - `_startedAt` 只赋值一次且永不重置 → 后续用例全落在 30s 宽限期内；
  /// - `_lastShownAt` 带 20s 节流 → 「应当弹 toast」会被吞掉；
  /// - `_pendingTimer` 未取消 → fake-async 直接判 pending timer 报错。
  ///
  /// 特别是「后台刷新失败**不**弹 toast」这类断言：不重置的话，
  /// 上一条用例刚弹过窗，节流会让它「确实没弹」，用例永远绿。
  @visibleForTesting
  static void resetForTest() {
    _startedAt = null;
    _lastShownAt = null;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingMessage = null;
    _pendingSince = null;
  }
}