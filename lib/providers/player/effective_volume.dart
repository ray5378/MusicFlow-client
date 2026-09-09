import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 统一「本机 / 后端投流 peer / 局域网 DLNA 直投」的音量显示与下发入口。
///
/// 与 effective_playback_provider 同一链路优先级(直投 > peer > 本机):
/// - 显示:迷你播放条音量按钮、桌面歌词浮窗音量滑条共用
///   [effectiveVolumeProvider];
/// - 下发:[setEffectiveVolume] 按当前链路路由;
/// - 拖动场景(滑杆高频回调)经 [ThrottledVolumeSender] 节流,
///   防止 SOAP/HTTP 高频请求刷爆设备/网络。

/// 纯函数:有效音量(0..1)。
///
/// 投屏链路优先用设备/peer 回报音量(0-100);直投未回报(0)或 peer 未回报
/// (null)时回退本机音量,避免显示成假的 0%。
double resolveEffectiveVolume({
  required bool dlnaCasting,
  required int dlnaVolume,
  required bool peerActive,
  required int? peerVolume,
  required double localVolume,
}) {
  if (dlnaCasting && dlnaVolume > 0) {
    return (dlnaVolume / 100).clamp(0.0, 1.0).toDouble();
  }
  if (peerActive && peerVolume != null) {
    return (peerVolume / 100).clamp(0.0, 1.0).toDouble();
  }
  return localVolume.clamp(0.0, 1.0).toDouble();
}

/// 当前有效音量(0..1):投屏取设备/peer 回报值,未回报回退本机。
/// select 窄化为元组,投屏状态其余字段变化不触发本 provider 重建。
final effectiveVolumeProvider = Provider<double>((ref) {
  final dlna = ref.watch(
    dlnaCastProvider.select(
      (s) => (casting: s.isCasting, volume: s.status.volume),
    ),
  );
  final cast = ref.watch(
    castPeerControllerProvider.select(
      (s) => (active: s.activePeer != null, volume: s.status.volume),
    ),
  );
  return resolveEffectiveVolume(
    dlnaCasting: dlna.casting,
    dlnaVolume: dlna.volume,
    peerActive: cast.active,
    peerVolume: cast.volume,
    localVolume: ref.watch(playerProvider.select((s) => s.volume)),
  );
});

/// 统一音量下发入口(对齐 effective_playback_provider 的 WidgetRef 模式):
/// 链路 B 直投→SOAP SetVolume;链路 A 投屏→POST 后端转发;本机→just_audio。
/// [live] 为 true 时本机走 setVolumeLive(实时跟手、不逐次落盘),供拖动
/// 节流回调;松手/最终值以 live:false 提交并落盘。
Future<void> setEffectiveVolume(
  WidgetRef ref,
  double v, {
  bool live = false,
}) async {
  final clamped = v.clamp(0.0, 1.0).toDouble();
  if (ref.read(dlnaCastProvider).isCasting) {
    await ref
        .read(dlnaCastProvider.notifier)
        .setVolume((clamped * 100).round());
    return;
  }
  final cast = ref.read(castPeerControllerProvider);
  if (cast.activePeer != null) {
    await ref
        .read(castPeerControllerProvider.notifier)
        .setVolume((clamped * 100).round());
    return;
  }
  if (live) {
    // setVolumeLive 是同步 void(内部自带节流合并),不 await。
    ref.read(playerProvider.notifier).setVolumeLive(clamped);
  } else {
    await ref.read(playerProvider.notifier).setVolume(clamped);
  }
}

/// 拖动场景的高频音量下发节流:≤ [interval] 一次,静默 [interval] 后尾部
/// 补发最新值——桌面歌词滑条的原生层没有「松手」消息,靠尾部补发保证
/// 最终值到达。[onSend] 由调用方提供(通常包装 [setEffectiveVolume])。
class ThrottledVolumeSender {
  ThrottledVolumeSender({
    required this.onSend,
    this.interval = const Duration(milliseconds: 100),
  });

  final Future<void> Function(double v) onSend;
  final Duration interval;

  Timer? _flushTimer;
  DateTime? _lastSend;
  double? _pending;

  void send(double v) {
    _pending = v;
    final now = DateTime.now();
    if (_lastSend != null && now.difference(_lastSend!) < interval) {
      _flushTimer ??= Timer(interval, () {
        _flushTimer = null;
        final pending = _pending;
        if (pending != null) {
          _lastSend = DateTime.now();
          unawaited(onSend(pending));
        }
      });
      return;
    }
    _lastSend = now;
    unawaited(onSend(v));
  }

  /// 复位节流状态(松手提交最终值前调用,提交本身不经节流)。
  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _lastSend = null;
    _pending = null;
  }

  void dispose() => reset();
}
