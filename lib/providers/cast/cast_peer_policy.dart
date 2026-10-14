// ADR-2「阶段 2a：cast 域纯策略外提」——投屏/流转状态判定的纯函数。
//
// 这些判定原先内联在 `cast_peer_provider.dart` 的 `CastPeerController`（StateNotifier）
// 里，属**库私有**成员、单测只能经由整条控制器链路间接触达。外提为顶层纯函数后：
//   - 直接对边界（外推夹紧、陈旧采样窗口、影子合并、插值封顶、选举排序）做精确断言；
//   - 控制器只保留「读状态 → 调纯函数 → 写字段/记日志」的编排，不再内联判定。
//
// 与 `player_*_policy.dart`（阶段 1）同源手法：**纯函数**只依赖入参，时间/平台等外部
// 输入由调用方注入，保证可确定性测试。
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/player/peer_display_order.dart'
    show peerKindRank;

/// 「命令影子」保护窗口:本端下发控制命令后,在该窗口内忽略**采样早于命令**的
/// 滞后上报字段(音量 / 静音 / 进度 / 播放态)。
///
/// 取值依据:远端客户端的状态上报周期实测约 4s,取 8s = 一个上报周期 + 一倍余量,
/// 既覆盖最坏延迟,又不会在命令真的没生效时长时间掩盖真实状态(超时后自动恢复采纳)。
const int kCommandShadowWindowMs = 8000;

/// 把远端**客户端实例**上报的 position 采样外推到「此刻」（纯函数）。
///
/// 客户端实例的 position 是**周期性上报**的采样(实测约 4s 一次),不是实时值;
/// 采样时刻由 `/status` 的 `reportedAt`(服务端时钟,ms)给出。
///
/// 直接把采样值当「此刻」写进平滑进度,会把本地已在推进的时钟(250/500ms tick)
/// 每轮询**拽回**旧值 —— 表现为进度条/歌词「前进一段又回退」。修法:
/// `采样值 + (现在 − reportedAt)` 外推到此刻,两次上报之间连续推进。
///
/// 规则（与宿主内联实现逐字等价）:
///   1. 非播放态 → 原样返回（暂停时保持上报值,避免暂停态漂移）;
///   2. 无 `reportedAt`(设备型 peer 走实时查询)→ 原样返回,设备链路行为不变;
///   3. `age ≤ 0`(本端时钟落后) 或 `age > 30s`(上报过旧,见服务端 local-status TTL)
///      → 原样返回,不做外推;
///   4. 其余 → `采样值 + age`,有 duration 时夹紧到 `[0, duration]`。
double projectPolledPosition({
  required PeerStatus status,
  required int nowMs,
}) {
  if (!status.playing) return status.positionSeconds;
  final at = status.reportedAtMs;
  if (at == null || at <= 0) return status.positionSeconds;
  final ageSec = (nowMs - at) / 1000.0;
  if (ageSec <= 0 || ageSec > 30) return status.positionSeconds;
  final projected = status.positionSeconds + ageSec;
  return status.durationSeconds > 0
      ? projected.clamp(0.0, status.durationSeconds)
      : projected;
}

/// 该上报是不是「命令下发**之前**采的样」——即尚未包含本次命令结果（纯函数）。
///
/// 判据:采样时刻(`reportedAt`)早于命令下发时刻,且仍在保护窗口内。
/// 无 `reportedAt`(设备型 peer 走实时查询)→ 恒 false,设备链路不受影响。
bool isStaleSample({
  required PeerStatus status,
  required int commandAtMs,
  required int nowMs,
  int windowMs = kCommandShadowWindowMs,
}) {
  final at = status.reportedAtMs;
  if (at == null || commandAtMs <= 0) return false;
  if (nowMs - commandAtMs > windowMs) return false;
  return at < commandAtMs;
}

/// 把「本端刚下发的**音量类**命令」叠加到滞后上报上（纯函数）。
///
/// 远端客户端的音量与 position 一样是**周期上报**的。连续拖动(20 → 50 → 30)时,
/// 上报回来的可能还是上一拍的 50,直接采纳会把手中的 30 **顶掉**。判据:采样时刻
/// 早于命令下发 → 该采样不含本次命令结果,volume / muted 一律沿用本地值;采样时刻
/// 追上命令后自动恢复采纳。无 `reportedAt` → 原样返回。
PeerStatus applyVolumeShadow({
  required PeerStatus incoming,
  required PeerStatus current,
  required int commandAtMs,
  required int nowMs,
  int windowMs = kCommandShadowWindowMs,
}) {
  if (!isStaleSample(
    status: incoming,
    commandAtMs: commandAtMs,
    nowMs: nowMs,
    windowMs: windowMs,
  )) {
    return incoming;
  }
  return PeerStatus(
    state: incoming.state,
    positionSeconds: incoming.positionSeconds,
    durationSeconds: incoming.durationSeconds,
    volume: current.volume,
    muted: current.muted,
    active: incoming.active,
    reportedAtMs: incoming.reportedAtMs,
  );
}

/// 播放/暂停(传输类)命令的影子,与音量同因（纯函数）。
///
/// 点暂停后,陈旧上报仍是 `state=PLAYING` 且 position 还在前进,不仅会覆盖本地乐观
/// 置位,还会触发 `_tick` 里的 advancing 自愈把 PAUSED **强制改回 PLAYING**。故在窗口内:
/// 沿用在地 `state`/`active`,并停用 advancing 自愈(见 `_tick`)。
PeerStatus applyTransportShadow({
  required PeerStatus incoming,
  required PeerStatus current,
  required int commandAtMs,
  required int nowMs,
  int windowMs = kCommandShadowWindowMs,
}) {
  if (!isStaleSample(
    status: incoming,
    commandAtMs: commandAtMs,
    nowMs: nowMs,
    windowMs: windowMs,
  )) {
    return incoming;
  }
  return PeerStatus(
    state: current.state,
    positionSeconds: incoming.positionSeconds,
    durationSeconds: incoming.durationSeconds,
    volume: incoming.volume,
    muted: incoming.muted,
    active: current.active,
    reportedAtMs: incoming.reportedAtMs,
  );
}

/// 平滑进度插值下一拍的值（纯函数）：播放中按 [tickMs] 递增并夹紧到 duration。
///
/// 非播放态 / duration 非法 → 原样返回（调用方据此判断「无变化」跳过写状态）。
double nextSmoothPosition({
  required double smoothPositionSeconds,
  required PeerStatus status,
  required int tickMs,
}) {
  if (!status.playing || status.durationSeconds <= 0) {
    return smoothPositionSeconds;
  }
  return (smoothPositionSeconds + tickMs / 1000)
      .clamp(0.0, status.durationSeconds);
}

/// 平滑进度插值间隔(ms)：桌面 500ms(降低 Windows 高频重建),手机 250ms（纯函数）。
///
/// Web 恒 250ms;桌面三平台 500ms;其余(Android/iOS/fuchsia)250ms。
int resolveProgressTickMs({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return 250;
  return switch (platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux =>
      500,
    _ => 250,
  };
}

/// 可见播放端:`available` 或 `self`（纯函数）。
///
/// 服务端还没报上来任何端时返回**空列表** —— 调用方据此「等下一轮再评估」,
/// 不置位「已评估」标记。
List<PeerInfo> visiblePeers(List<PeerInfo> peers) =>
    peers.where((p) => p.available || p.self).toList();

/// 启动自动选中的**候选目标**（纯函数）:在 [visible] 中取「有活跃队列、可用、非本机自身」
/// 的端,按 `类别序(本机类别 > 群组 > 独立播放器) → 名称` 升序排列。
///
/// 本机自身(self)不进候选:有队列但不在播时它天然排在所有在播端之后,
/// 即「无在播端则保持本机」。
List<PeerInfo> selectAutoSelectCandidates(List<PeerInfo> visible) {
  return visible.where((p) => p.queueActive && p.available && !p.self).toList()
    ..sort((a, b) {
      final k = peerKindRank(a) - peerKindRank(b);
      if (k != 0) return k;
      return a.name.compareTo(b.name);
    });
}
