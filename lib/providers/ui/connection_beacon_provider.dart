import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/providers/api/connection_gate.dart';

/// 心跳提示的日志标签。
const String _beaconLogTag = 'CONN_BEACON';

/// 冷启动灰点的**显示延迟**：地址池刚建好时探测正在飞，等 400ms 再决定是否
/// 摆灰点。窗口内连上就永不显示（「快连不闪」）。
const Duration kBeaconShowDelay = Duration(milliseconds: 400);

/// 绿色「已连接」的停留时长：连上后绿色呼吸 5 秒，然后自动隐藏。
const Duration kBeaconConnectedLinger = Duration(seconds: 5);

/// 失联灰点的**防抖窗口**：断开后先等 2 秒，仍在断才变灰（防止抖动横跳）。
const Duration kBeaconLostDebounce = Duration(seconds: 2);

/// 冷启动灰点的**上限**：从未连通过的灰点最多显示 60 秒（地址池为空的新用户
/// 不该看一个转不完的圈）。
const Duration kBeaconColdStartDeadline = Duration(seconds: 60);

/// 冷启动灰点显示延迟（可注入，测试用）。
@visibleForTesting
Duration beaconShowDelay = kBeaconShowDelay;

/// 绿色停留时长（可注入，测试用）。
@visibleForTesting
Duration beaconConnectedLinger = kBeaconConnectedLinger;

/// 失联防抖窗口（可注入，测试用）。
@visibleForTesting
Duration beaconLostDebounce = kBeaconLostDebounce;

/// 冷启动灰点上限（可注入，测试用）。
@visibleForTesting
Duration beaconColdStartDeadline = kBeaconColdStartDeadline;

/// 测试隔离：把四个可注入阈值复位成默认值。
@visibleForTesting
void resetConnectionBeaconTimingsForTest() {
  beaconShowDelay = kBeaconShowDelay;
  beaconConnectedLinger = kBeaconConnectedLinger;
  beaconLostDebounce = kBeaconLostDebounce;
  beaconColdStartDeadline = kBeaconColdStartDeadline;
}

/// 心跳提示的可见状态。**只有两色**：灰=未连接，绿=已连接。
enum ConnectionBeaconPhase {
  /// 不渲染（已隐藏 / 还没到显示时机）。
  hidden,

  /// 灰：未连接（呼吸）。
  waiting,

  /// 绿：已连接（呼吸），[kBeaconConnectedLinger] 之后转 [hidden]。
  connected,
}

/// 灰色态的文案来源（两句话，语气不同）。
enum ConnectionBeaconReason {
  /// 冷启动：本次会话还没连上过 —— 「连接中…」。
  coldStart,

  /// 中途失联：本会话连上过又断了 —— 「连接已断开，正在重连」。
  lost,
}

/// 心跳提示的渲染状态。
///
/// 只携带「该不该显示 + 显示哪一句」；连通性真值不在这里，唯一来源是
/// `sessionConnectedProvider` / `sessionEverConnectedProvider`。
@immutable
class ConnectionBeaconState {
  const ConnectionBeaconState({
    this.phase = ConnectionBeaconPhase.hidden,
    this.reason = ConnectionBeaconReason.coldStart,
  });

  /// 当前可见阶段。
  final ConnectionBeaconPhase phase;

  /// 灰色态的文案来源（[ConnectionBeaconPhase.connected] 时无意义）。
  final ConnectionBeaconReason reason;

  /// 是否需要渲染（[ConnectionBeaconPhase.hidden] 之外都渲染）。
  bool get isVisible => phase != ConnectionBeaconPhase.hidden;

  /// 是否是「已连接」绿点。
  bool get isConnected => phase == ConnectionBeaconPhase.connected;

  ConnectionBeaconState copyWith({
    ConnectionBeaconPhase? phase,
    ConnectionBeaconReason? reason,
  }) {
    return ConnectionBeaconState(
      phase: phase ?? this.phase,
      reason: reason ?? this.reason,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConnectionBeaconState &&
        other.phase == phase &&
        other.reason == reason;
  }

  @override
  int get hashCode => Object.hash(phase, reason);

  @override
  String toString() => 'ConnectionBeaconState(phase: $phase, reason: $reason)';
}

/// 连接心跳提示的状态机。
///
/// 规则（编号与实现一一对应）：
///
/// | # | 输入变化 | 行为 |
/// |---|---|---|
/// | R1 | 首次构建，且此刻未连接、本会话从未连通过 | 延迟 [beaconShowDelay] 才置灰；窗口内连上则永不显示 |
/// | R2 | 未连接 → 已连接 | 立即绿；[beaconConnectedLinger] 后转 hidden |
/// | R3 | 已连接 → 未连接（本会话连通过） | 延迟 [beaconLostDebounce] 防抖，仍在断才置灰 |
/// | R4 | 绿色停留窗口内失联 | 立即置灰，不等防抖 |
/// | R5 | 灰（冷启动）累计 [beaconColdStartDeadline] 仍未连上 | 置 hidden 并记日志 |
/// | R6 | 本会话曾连通翻真 | 取消 R5 的 60 秒上限 |
///
/// 实现要点：用 [Ref.listen]（而不是 `watch`）装配，避免整个 provider 重算导致
/// 定时器字段丢失；每次写 [state] 前先判等，相等就不发，避免无意义重建。
class ConnectionBeaconController extends Notifier<ConnectionBeaconState> {
  /// R1 的显示延迟定时器。
  Timer? _showDelay;

  /// R2 的 5 秒隐藏定时器。
  Timer? _hideTimer;

  /// R3 的 2 秒失联防抖定时器。
  Timer? _lostDebounce;

  /// R5 的 60 秒冷启动上限定时器。
  Timer? _coldStartDeadline;

  /// 本会话是否曾真实连通过（镜像 [sessionEverConnectedProvider]，但只增不减）。
  bool _everConnected = false;

  @override
  ConnectionBeaconState build() {
    ref.onDispose(_disposeTimers);

    final connected = ref.read(sessionConnectedProvider);
    final everConnected = ref.read(sessionEverConnectedProvider);
    _everConnected = everConnected;

    // 只 listen 不 watch：watch 会让本 provider 在连通性变化时整体重算，
    // 定时器字段与 _everConnected 会被丢掉，状态机就断了。
    ref.listen<bool>(sessionConnectedProvider, (previous, next) {
      if (previous == next) return;
      _onConnectionChanged(next);
    });

    // R6：本会话曾连通翻真 → 冷启动灰点不再有 60 秒上限。
    ref.listen<bool>(sessionEverConnectedProvider, (previous, next) {
      if (previous == next) return;
      if (!next) return;
      _everConnected = true;
      _cancelColdStartDeadline();
    });

    return _resolveInitialState(
      connected: connected,
      everConnected: everConnected,
    );
  }

  /// 首次构建时的落点。
  ///
  /// - 此刻已连接（会话中途重建）：按「刚连上」处理 → 绿 + 5 秒窗口；
  /// - 已连通过后失联（会话中途重建）：灰（reconnecting）；
  /// - 冷启动：交给 R1 的 400ms 延迟，构建期先返回 hidden。
  ConnectionBeaconState _resolveInitialState({
    required bool connected,
    required bool everConnected,
  }) {
    if (connected) {
      _scheduleHide();
      return const ConnectionBeaconState(phase: ConnectionBeaconPhase.connected);
    }
    if (everConnected) {
      return const ConnectionBeaconState(
        phase: ConnectionBeaconPhase.waiting,
        reason: ConnectionBeaconReason.lost,
      );
    }
    _scheduleColdStartShow();
    return const ConnectionBeaconState();
  }

  /// 连通性翻转的入口。
  void _onConnectionChanged(bool connected) {
    if (connected) {
      _onBecameConnected();
    } else {
      _onBecameDisconnected();
    }
  }

  /// R2：未连接 → 已连接。立即绿，并起 5 秒窗口。
  void _onBecameConnected() {
    _cancelShowDelay();
    _cancelLostDebounce();
    _cancelColdStartDeadline();
    _emit(ConnectionBeaconPhase.connected, ConnectionBeaconReason.coldStart);
    _scheduleHide();
  }

  /// 已连接 → 未连接。分三种情形（R4 / R3 / 冷启动路径）。
  void _onBecameDisconnected() {
    if (!_everConnected) {
      // 从未连通过：仍走冷启动路径（延迟 400ms 才摆灰点）。
      _emit(ConnectionBeaconPhase.hidden, ConnectionBeaconReason.coldStart);
      _scheduleColdStartShow();
      return;
    }
    if (state.phase == ConnectionBeaconPhase.connected) {
      // R4：绿色 5 秒窗口内又失联 → 立即变灰，不等防抖，并取消隐藏定时器。
      _cancelHideTimer();
      _cancelLostDebounce();
      _emit(ConnectionBeaconPhase.waiting, ConnectionBeaconReason.lost);
      return;
    }
    // R3：已经不在绿色窗口内（hidden / 已经是灰）→ 2 秒防抖。
    _scheduleLostDebounce();
  }

  /// R1：延迟 [beaconShowDelay] 后若仍未连上，才摆冷启动灰点。
  void _scheduleColdStartShow() {
    _cancelShowDelay();
    _cancelColdStartDeadline();
    _showDelay = Timer(beaconShowDelay, () {
      _showDelay = null;
      if (ref.read(sessionConnectedProvider)) return;
      _emit(ConnectionBeaconPhase.waiting, ConnectionBeaconReason.coldStart);
      _armColdStartDeadline();
    });
  }

  /// R2：绿色呼吸 [beaconConnectedLinger] 后自动隐藏。
  void _scheduleHide() {
    _cancelHideTimer();
    _hideTimer = Timer(beaconConnectedLinger, () {
      _hideTimer = null;
      // 窗口内失联由 R4 抢先处理（已把 phase 改成 waiting 并取消本定时器）；
      // 这里再判一次连通性，避免把刚变灰的状态覆盖成 hidden。
      if (!ref.read(sessionConnectedProvider)) return;
      _emit(ConnectionBeaconPhase.hidden, ConnectionBeaconReason.coldStart);
    });
  }

  /// R3：失联防抖 [beaconLostDebounce]，到期仍在断才变灰。
  void _scheduleLostDebounce() {
    _cancelLostDebounce();
    _lostDebounce = Timer(beaconLostDebounce, () {
      _lostDebounce = null;
      // 防抖窗口内恢复 → 维持原状态（恢复本身会经 R2 走绿色路径）。
      if (ref.read(sessionConnectedProvider)) return;
      _emit(ConnectionBeaconPhase.waiting, ConnectionBeaconReason.lost);
    });
  }

  /// R5：冷启动灰点累计 [beaconColdStartDeadline] 仍未连上 → 隐藏并记日志。
  ///
  /// R6：本会话已连通（_everConnected）时不装这个上限 —— 失联态常驻是合理的。
  void _armColdStartDeadline() {
    _cancelColdStartDeadline();
    if (_everConnected) return;
    _coldStartDeadline = Timer(beaconColdStartDeadline, () {
      _coldStartDeadline = null;
      if (ref.read(sessionConnectedProvider)) return;
      if (state.phase != ConnectionBeaconPhase.waiting ||
          state.reason != ConnectionBeaconReason.coldStart) {
        return;
      }
      Logger.infoWithTag(
        _beaconLogTag,
        'cold-start beacon hidden after '
        '${beaconColdStartDeadline.inSeconds}s without connection',
      );
      _emit(ConnectionBeaconPhase.hidden, ConnectionBeaconReason.coldStart);
    });
  }

  /// 唯一的写状态入口：值相同就不发，避免无意义重建。
  void _emit(ConnectionBeaconPhase phase, ConnectionBeaconReason reason) {
    final next = ConnectionBeaconState(phase: phase, reason: reason);
    if (next == state) return;
    state = next;
  }

  void _cancelShowDelay() {
    _showDelay?.cancel();
    _showDelay = null;
  }

  void _cancelHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _cancelLostDebounce() {
    _lostDebounce?.cancel();
    _lostDebounce = null;
  }

  void _cancelColdStartDeadline() {
    _coldStartDeadline?.cancel();
    _coldStartDeadline = null;
  }

  void _disposeTimers() {
    _cancelShowDelay();
    _cancelHideTimer();
    _cancelLostDebounce();
    _cancelColdStartDeadline();
  }
}

/// 连接心跳提示的状态机 provider。
///
/// 刻意**不** autoDispose：整个 app 生命周期只有一个心跳提示，重建会丢掉
/// 「已证明能连上过」的时序上下文。
final connectionBeaconProvider =
    NotifierProvider<ConnectionBeaconController, ConnectionBeaconState>(
      ConnectionBeaconController.new,
    );
