// ADR-2「阶段 1：策略/协作者外提」——看门狗（watchdog）协作者。
//
// 位置轮询里的三道看门狗（0 秒卡死 / 停滞 / 近末尾）长期内联在
// `player_position_polling.dart` 的 `Timer` 回调里，阈值语义只能靠重型的
// provider 用例间接覆盖。这里把其中**纯判定**的部分外提为独立、无副作用、
// 可零成本单测的纯函数；宿主 mixin 只负责读状态、调用、按下标动字段。
//
// 行为等价性：本文件的函数是原内联逻辑的逐字搬运（含 150ms 前进阈值、
// tickWeight 加权、各清零分支），仅把「读私有字段」改为「入参」。宿主侧
// 仍持有全部计数器与状态。
import 'package:just_audio/just_audio.dart';

/// 判定「位置确有前进」的毫秒阈值。
///
/// Windows 端 media_kit 的位置采样较粗（每 500ms 可能只前进 150~300ms），
/// 故用 150ms 作为「未前进」的容差；超过即视为在推进、清空卡死计数。
/// 与 [_kStartupProgressResetThreshold] 的 1500ms 语义不同：后者是「已真正
/// 离开起点」的绝对位置门限。
const int kPositionProgressEpsilonMs = 150;

/// 「已真正离开起点」的绝对位置门限（毫秒）。
const int kStartupProgressResetThresholdMs = 1500;

/// 流加载卡死档位（三档优先级：idle 档 > loading 档 > 兜底）。
///
/// 详见 `player_position_polling.dart` 内对 just_audio `_platformLoading`
/// 掩码的推导注释：`idle` ⟺ 平台压根没接管音源；`loading` ⟺ 平台已接管但
/// 停在加载态等数据；两者之外走 30min 兜底安全网。
enum StreamLoadStuckLevel {
  /// 未命中卡死特征——沿用兜底上界。
  none,

  /// `idle` + 播放意图 + 位置≈0 + duration=0：平台未接管，用短上限。
  idleNeverTookSource,

  /// `loading` + 播放意图 + 位置零前进：平台已接管但等不到数据，用中上限。
  loadingNoProgress,
}

/// 按 processing / 播放意图 / 位置归一流加载卡死档位（纯函数）。
///
/// 与宿主内联判定逐字等价：
///   · [StreamLoadStuckLevel.idleNeverTookSource] =
///       `processing == idle` && [wantsPlaying] && [sourcePlayerPos] ≤ 1.5s &&
///       `duration` 为空或零；
///   · [StreamLoadStuckLevel.loadingNoProgress] =
///       `processing == loading` && [wantsPlaying] && [sourcePlayerPos] ≤ 1.5s；
///   · 其余 [StreamLoadStuckLevel.none]。
///
/// 注意 loading 档**刻意不看 duration**：libmpv 一打开（拿到响应头）通常就
/// 带总时长，若把 `duration == 0` 当必要条件会把该档误解除、退回永久卡死。
StreamLoadStuckLevel classifyStreamLoadStuck({
  required ProcessingState processing,
  required bool wantsPlaying,
  required Duration sourcePlayerPos,
  required Duration? playerDuration,
}) {
  final atStart =
      sourcePlayerPos <= const Duration(milliseconds: kStartupProgressResetThresholdMs);
  if (processing == ProcessingState.idle &&
      wantsPlaying &&
      atStart &&
      (playerDuration == null || playerDuration == Duration.zero)) {
    return StreamLoadStuckLevel.idleNeverTookSource;
  }
  if (processing == ProcessingState.loading && wantsPlaying && atStart) {
    return StreamLoadStuckLevel.loadingNoProgress;
  }
  return StreamLoadStuckLevel.none;
}

/// 服务端「整曲缓冲·首字节有界等待」上限的**客户端镜像**（权威定义见服务端
/// `backend/src/routes/rest/index.ts` 的 `STREAM_BUFFER_HEAD_WAIT_MS`）。
///
/// **跨仓契约（ADR-4 相邻项）**：服务端在冷启动整曲缓冲时最多挂起本时长，之后回退
/// 直通（首字节优先）。因此客户端在「平台未接管音源(idle)」一档的判死上界
/// [kStreamLoadIdleCeilingMs] 必须**严格大于**本值——否则服务端仍在合法缓冲窗口内，
/// 客户端已抢先判死并触发 reload/跳歌（无谓重载、且会拆掉在途请求让服务端重开窗口）。
/// 两侧由各自单测断言此不变式（客户端见 `b50g_watchdog_queue_policy_test.dart`，
/// 服务端见 `tests/source/bufferHeadWait.test.ts`）。
///
/// 2026-10-13（起播缓冲标定）：服务端分两档——总大小已知 8s / 未知（chunked）6s，
/// 另对慢源做投影早退（观测 ≥1.2s 且 ≥256KB，推算整曲超上界即提前回退直通）。
/// 本镜像取**已知档 8000**（= 服务端可能的最长合法等待）；改服务端常量必须同步改这里。
const int kServerStreamBufferHeadWaitMs = 8000;

/// 「平台未接管音源(idle)」档的判死上界默认值（ms）——宿主可经
/// `debugStreamLoadIdleStuckCeilingMs` 覆写。
/// 约束：> [kServerStreamBufferHeadWaitMs]，且余量 ≥ [kStreamLoadHeadWaitAlignmentMarginMs]。
const int kStreamLoadIdleCeilingMs = 10000;

/// 「平台已接管音源但位置零前进(loading)」档的判死上界默认值（ms）。
/// 该档须容纳「首字节等待 + ffmpeg 起播」的合法冷启动（实测 5~8s），故远大于
/// [kServerStreamBufferHeadWaitMs]。
const int kStreamLoadNoProgressCeilingMs = 30000;

/// 兜底上界默认值（ms）：不命中前两档时的安全网，保证在途标记不会永久为真。
const int kStreamLoadFallbackCeilingMs = 1800000;

/// [kStreamLoadIdleCeilingMs] 相对 [kServerStreamBufferHeadWaitMs] 的最小余量（ms）。
/// 供两侧单测断言；低于此值即视为契约回归（网络/反代抖动会吃掉余量）。
const int kStreamLoadHeadWaitAlignmentMarginMs = 1500;

/// 按档位取「在途加载」的等待上界（毫秒）：idle 档 > loading 档 > 兜底。
///
/// 三个上界由宿主从可调试配置注入（`debugStreamLoadIdleStuckCeilingMs` /
/// `debugStreamLoadNoProgressCeilingMs` / `debugStreamLoadLoadingCeilingMs`），
/// 纯函数只负责选择，不持有配置。
int streamLoadStuckCeilingMs({
  required StreamLoadStuckLevel level,
  required int idleNeverTookSourceMs,
  required int loadingNoProgressMs,
  required int fallbackMs,
}) {
  switch (level) {
    case StreamLoadStuckLevel.idleNeverTookSource:
      return idleNeverTookSourceMs;
    case StreamLoadStuckLevel.loadingNoProgress:
      return loadingNoProgressMs;
    case StreamLoadStuckLevel.none:
      return fallbackMs;
  }
}

/// 「位置落在末段窗口内」（剩余 ≤ 2.5s 且总时长 > 3s）。
bool isInNearEndWindow({
  required Duration duration,
  required Duration position,
}) {
  return duration > const Duration(seconds: 3) &&
      duration - position <= const Duration(milliseconds: 2500);
}

/// 「末段已应结束」：在末段窗口内，且（确实在播或位置已到/越过声明末尾）。
///
/// 覆盖 Windows 解码器撞容器 EOF 时 `completed` 不上报的场景。
bool isNearEndCompletionEngaged({
  required Duration duration,
  required Duration position,
  required bool playing,
}) {
  return isInNearEndWindow(duration: duration, position: position) &&
      (playing || position >= duration);
}

/// 0 秒卡死计数的下一步：命中「播放意图存在但卡在起点且位置无进展」则加权
/// 累加，否则清零。
///
/// [inSeekSettle] / [preserveSeekPosition] 为真时**不累计也不清零以外的动作**——
/// 与宿主一致：命中守卫时直接回到 0（seek 宽限内不把「未前进」当卡死）。
int nextStartupStuckTicks({
  required int current,
  required int tickWeight,
  required bool wantsPlaying,
  required bool atStart,
  required bool hasNoProgress,
  required bool inSeekSettle,
  required bool preserveSeekPosition,
}) {
  final shouldAccumulate = wantsPlaying &&
      atStart &&
      hasNoProgress &&
      !inSeekSettle &&
      !preserveSeekPosition;
  return shouldAccumulate ? current + tickWeight : 0;
}

/// 停滞计数的下一步：起点阶段一律清零（交由 0 秒卡死看门狗负责）；非起点时
/// 「在播且位置未前进」加权累加，否则清零。
int nextStagnantTicks({
  required int current,
  required int tickWeight,
  required bool atStart,
  required bool stallSignal,
  required int deltaMs,
}) {
  if (atStart) return 0;
  if (!stallSignal || deltaMs > kPositionProgressEpsilonMs) return 0;
  return current + tickWeight;
}

/// 近末尾卡死计数的下一步：末段已应结束且位置未前进且不在 seek 宽限内则加权
/// 累加，否则清零。
int nextNearEndStuckTicks({
  required int current,
  required int tickWeight,
  required bool endEngaged,
  required int deltaMs,
  required bool inSeekSettle,
}) {
  if (endEngaged && deltaMs <= kPositionProgressEpsilonMs && !inSeekSettle) {
    return current + tickWeight;
  }
  return 0;
}

/// 「已真正离开起点」（位置越过 1.5s 门限）。
bool hasLeftStartup(Duration sourcePlayerPos) =>
    sourcePlayerPos > const Duration(milliseconds: kStartupProgressResetThresholdMs);
