import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cast_peer_provider.dart';
import 'dlna_provider.dart';

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

  /// 是否在倒计时中。
  bool get isActive => _timer != null;

  /// 是否为链路 A（服务器计时）。UI 可据此区别展示。
  bool get serverTracked => _serverTracked;

  /// 是否「播完整首歌曲再关闭」。
  bool get finishSong => _finishSong;

  /// 开启定时暂停；重复调用会重置为新时长。[finishSong] 为 true 时到点后
  /// 等当前曲自然播完再暂停（链路 A 由服务器实现，本机/链路 B 同步该标志）。
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
    // 每秒刷新剩余时长驱动 UI 倒计时。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final left = _deadline!.difference(DateTime.now());
      if (left.isNegative) {
        _cancelTimer();
        // 链路 A 由服务器暂停;仅本机/链路 B 需要本地暂停。
        if (!_serverTracked) {
          await _pauseLocal();
        }
      } else {
        state = left;
      }
    });
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
    state = null;
  }
}