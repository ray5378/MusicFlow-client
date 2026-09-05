import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cast_peer_provider.dart';
import 'dlna_provider.dart';
import 'player_provider.dart';

/// 定时停止（暂停）Provider。
///
/// 保存倒计时剩余时长；到点后暂停当前播放。`state == null` 表示未开启定时。
///
/// 计时归属（按当前播放目标自动路由）：
/// - **链路 A（投屏/群组）**：由**服务器**自己倒计时并在到点暂停，命令后端
///   `POST/DELETE /v1/peers/:peerId/sleep-timer`——客户端 App 关闭/掉线后定时
///   依然生效；客户端仅在本地模拟一段倒计时用于 UI 显示剩余时长（到点不再本地暂停，
///   服务器会停）。
/// - **本机 / 链路 B（DLNA 直投）**：客户端本地倒计时，到点路由到对应目标暂停。
///
/// 「播完整首歌曲再关闭」（[finishSong]）：
/// - 链路 A 由服务器实现（后端在下一曲切歌前暂停）。
/// - 本机 / 链路 B 由客户端实现：到点不停，进入「等当前曲播完」阶段
///   （[finishingCurrentTrack]），等目标曲目自然推进到下一首（或已停止）后再暂停。
final sleepTimerProvider =
    StateNotifierProvider<SleepTimerNotifier, Duration?>((ref) {
  return SleepTimerNotifier(ref);
});

/// 定时停止（暂停）状态管理器。
///
/// [state] 为 `Duration?`：非 null 为倒计时剩余时长（每秒刷新），null 为未开启。
class SleepTimerNotifier extends StateNotifier<Duration?> {
  SleepTimerNotifier(this._ref) : super(null);

  final Ref _ref;

  Timer? _timer;
  DateTime? _deadline;
  // 是否为链路 A（服务器计时）。此时到点由服务器暂停,客户端不重复暂停。
  bool _serverTracked = false;
  bool _finishSong = false;
  // 本机 / 链路 B 的「等当前曲播完」阶段：倒计时已归零，等待目标曲目推进一步再暂停。
  bool _finishingEnd = false;
  int _endBaseIndex = -1;

  /// 是否在倒计时中。
  bool get isActive => _timer != null;

  /// 是否为链路 A（服务器计时）。UI 可据此区别展示。
  bool get serverTracked => _serverTracked;

  /// 是否「播完整首歌曲再关闭」。
  bool get finishSong => _finishSong;

  /// 本机 / 链路 B 下是否正处于「等当前曲播完再暂停」阶段（倒计时已归零）。
  bool get finishingCurrentTrack => _finishingEnd;

  /// 开启定时暂停；重复调用会重置为新时长。[finishSong] 为 true 时到点后
  /// 等当前曲自然播完再暂停（链路 A 由服务器实现，本机/链路 B 由本 Provider 实现）。
  Future<void> start(Duration duration, {bool finishSong = false}) async {
    _cancelTimer();
    _finishSong = finishSong;
    final castCtrl = _ref.read(castPeerControllerProvider.notifier);
    final isCast = _ref.read(castPeerControllerProvider).activePeer != null;
    _serverTracked = isCast;
    if (isCast) {
      // 链路 A：命令服务器自己计时。失败则回退为本地计时（至少 UI 可用）。
      try {
        await castCtrl.setSleepTimer(duration, finishSong: finishSong);
      } catch (_) {
        _serverTracked = false;
      }
    }
    _deadline = DateTime.now().add(duration);
    state = duration;
    // 每秒刷新剩余时长驱动 UI 倒计时；到点后若需「播完当前曲」则转为等曲末观察。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_finishingEnd) {
        await _watchTrackEnd();
        return;
      }
      final left = _deadline!.difference(DateTime.now());
      if (left.isNegative) {
        if (_finishSong && !_serverTracked) {
          // 「播完整首再关闭」的本机/链路 B 路径：不立即暂停，
          // 进入等当前曲播完阶段（记录当前曲目索引，待其推进或停止）。
          _finishingEnd = true;
          _endBaseIndex = _currentTargetIndex();
          if (_ref.read(dlnaCastProvider).isCasting) {
            // 链路 B：给 DLNA 管理器设「曲毕暂停」意图，使曲毕续播处改暂停而非切下一首。
            _ref.read(dlnaManagerProvider).pendingPauseAtTrackEnd = true;
          }
          state = Duration.zero;
        } else {
          _cancelTimer();
          // 链路 A 由服务器暂停;仅本机/链路 B 需要本地暂停。
          if (!_serverTracked) {
            await _pauseLocal();
          }
        }
      } else {
        state = left;
      }
    });
  }

  /// 目标曲目恰好播完的时刻（player/DLNA 曲毕处）被调用：立即暂停并结束定时，
  /// 不自动切到下一首。仅在本机/链路 B 的「等当前曲播完」阶段有效。
  Future<void> finishAtTrackEndNow() async {
    if (!_finishingEnd) return;
    _cancelTimer();
    state = null;
    await _pauseLocal();
  }

  /// 取消已设置/已下发的定时。链路 A 同时取消服务器侧定时。
  Future<void> cancel() async {
    final wasServer = _serverTracked;
    final castCtrl = _ref.read(castPeerControllerProvider.notifier);
    final isCast = _ref.read(castPeerControllerProvider).activePeer != null;
    _cancelTimer();
    if (wasServer || isCast) {
      try {
        await castCtrl.setSleepTimer(null);
      } catch (_) {}
    }
  }

  /// 「等当前曲播完」阶段的逐秒观察：
  /// - 目标曲目索引已推进（当前曲已播完、正要播下一首）→ 暂停；
  /// - 目标已停止播放（不会自然推进，避免悬挂）→ 暂停；
  /// - 否则保持原曲播放，等待下一拍。
  Future<void> _watchTrackEnd() async {
    final stillPlaying = _isTargetPlaying();
    if (!stillPlaying || _currentTargetIndex() != _endBaseIndex) {
      _cancelTimer();
      state = null;
      await _pauseLocal();
    } else {
      state = Duration.zero;
    }
  }

  /// 当前播放目标的 currentIndex（曲末推进信号）。
  int _currentTargetIndex() {
    if (_ref.read(dlnaCastProvider).isCasting) {
      return _ref.read(dlnaCastProvider).currentIndex;
    }
    return _ref.read(playerProvider).currentIndex;
  }

  /// 当前播放目标是否仍在播放（避免等曲末时若目标已停则无法推进，形成悬挂）。
  bool _isTargetPlaying() {
    if (_ref.read(dlnaCastProvider).isCasting) {
      return _ref.read(dlnaCastProvider).status.state == 'PLAYING';
    }
    return _ref.read(playerProvider).isPlaying;
  }

  Future<void> _pauseLocal() async {
    // 链路 B 直投:指挥 DLNA 设备;否则经 cast_peer(无 activePeer 自动回退本机)。
    if (_ref.read(dlnaCastProvider).isCasting) {
      await _ref.read(dlnaCastProvider.notifier).pause();
      return;
    }
    await _ref.read(castPeerControllerProvider.notifier).pause();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    _serverTracked = false;
    _finishSong = false;
    _finishingEnd = false;
    _endBaseIndex = -1;
    state = null;
    // 兜底清掉 DLNA 曲毕暂停意图（正常触发后已复位,幂等）。
    if (_ref.read(dlnaCastProvider).isCasting) {
      _ref.read(dlnaManagerProvider).pendingPauseAtTrackEnd = false;
    }
  }
}
