// ADR-2 阶段 2b-2（[l18]）：位置轮询 / 看门狗驱动从 `PlayerNotifier` 家族的
// `PlayerPositionPollingInternals` mixin（原 player_provider.dart 的 part）抽成
// **独立协作者库**。
//
// 与旧 part mixin（共享整个 PlayerNotifier 库私有命名空间）不同，本驱动：
//   * 独立 Dart 库，只通过窄接口 [PlaybackPositionPollingHost] 触达宿主
//     （刻意不含 `Ref` 与任何 provider 直接依赖，可见性读取经宿主转发）；
//   * 全部轮询状态（轮询 Timer、上次轮询位置、停滞 / 0 秒卡死 / 近末尾 /
//     重载连击计数、不可见抽稀计数）收拢在本 mixin，宿主只在三个生命周期
//     点调用（startPositionPolling / stopPositionPolling / resetPositionTracking）；
//   * 看门狗纯判定沿用阶段 1 外提的 player_watchdog_policy.dart。
//
// ⚠️ 逻辑零改动：轮询体从 mixin 逐字搬运，只改成员访问方式
// （_ref.read→host.readIsRenderingActive、state 读写→host.state、
// 库私有方法→host 公开转发、跨流程字段→host 读写器）。
// 行为契约（500ms 基准周期、不可见 4 倍抽稀加权、停滞 10 tick、0 秒卡死
// 12 tick + 两级上界、近末尾 5 tick、重载容错 2 次）全部保持原样，
// 回归网是既有 b29a / b50e 轮询测试族 + 新增协作者窄接线测试。
import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/player_watchdog_policy.dart';

/// 停滞看门狗阈值：进度在播放状态下持续卡住达到该 tick 数(每 500ms 一 tick)
/// 即自动跳下一首，避免「进度一直不走却无自愈」。10 tick = 5 秒。
const int _stagnantSkipThresholdTicks = 10;

/// 0 秒卡死兜底阈值：播放意图存在且位置持续卡在起点(loading/buffering
/// 或 position 长期 <=0)，连续达到该 tick 数(每 500ms) 即重载当前曲目，
/// 模拟「切下一首再切回」的效果。12 tick = 6 秒。
const int _startupStuckSkipThresholdTicks = 12;

/// 0 秒卡死「连续重载」容错上限：同一首曲因卡在起点被看门狗连续重载达到
/// 该次数仍无任何进展(位置始终不前进)，判定为「后端确无可播源」而非
/// 瞬时挂起，转入既有失败跳歌逻辑(handlePlaybackError)标记死歌并跳下一首，
/// 避免对一首永远无法起播的歌无限重载原地空转。0 秒卡死重载走的是模拟
/// 「切下一首再切回」路径，瞬时可恢复的挂起在 1 次重载后即会推进位置并
/// 清零本计数；因此容错设为 2：允许 1 次自愈重试，若第 2 次连续重载仍无
/// 进展则判死跳歌。
const int _startupReloadTolerance = 2;

/// Windows 专项近末尾兜底计数阈值。5 tick ≈ 2.5s。
const int _nearEndStuckTicksThreshold = 5;

/// 位置轮询的**基准**周期（可见态）。
///
/// 所有累计型看门狗阈值（[_stagnantSkipThresholdTicks] 等）都以「该周期
/// 记 1 tick」标定，故此常量是对外契约的一部分，勿单独改动。
const Duration kPositionPollBaseInterval = Duration(milliseconds: 500);

/// 窗口不可见（最小化 / 隐藏到托盘）时的**抽稀因子**。
///
/// 不可见时用户看不到进度，无需 2Hz 写回 UI；每 [kHiddenPollDecimation] 个
/// 基准 tick 只做一次完整轮询（有效周期 = 500ms × 4 = 2s），其余物理 tick
/// 直接返回以省掉 `player.position` 读取与 `state` 写回带来的重建。
///
/// ⚠ 抽稀**不等于停摆**：一次完整轮询按本因子加权累计（见 `tickWeight`），
/// 使停滞 / 0 秒卡死 / 近末尾三道看门狗仍按**墙钟**阈值触发——后台播放遇到
/// 卡死照常自愈，不会因为降频被成倍拖慢。
@visibleForTesting
const int kHiddenPollDecimation = 4;

/// 宿主窄接口：位置轮询驱动触达播放器宿主的**最小面**。
///
/// 刻意不含 `Ref` 与任何 provider 直接依赖（可见性真值经宿主
/// [readIsRenderingActive] 转发），既断开库间耦合，也让本驱动可以用一个
/// 几十行的 fake host 独立构造单测。
///
/// 跨流程字段（seek 落位宽限、自动播放意图、在途流加载标记、完成处理重入
/// 标记）的真值仍归宿主所有——它们同时被 seek / 播放 / 完成等其它流程读写；
/// 本驱动仅按原轮询体的读写面暴露（标记为只读或读写的成员即原访问面）。
abstract class PlaybackPositionPollingHost {
  /// 播放状态读写（轮询体读 currentSong/position/duration/queue/currentIndex，
  /// drift≥250 时写回 position）。
  PlayerState get state;
  set state(PlayerState value);

  /// StateNotifier.mounted 透传：dispose 后轮询 tick 直接早退。
  bool get mounted;

  /// 渲染可见性真值（前台激活且未隐藏到托盘）。
  ///
  /// 宿主实现需保证：容器未就绪等异常按「可见」处理——宁可按原 500ms
  /// 轮询，也不因一次读取失败把看门狗拖慢。
  bool readIsRenderingActive();

  /// 源位置 → 逻辑位置换算（流转/续播 timeOffset 场景）。
  Duration logicalPlayerPosition(Duration sourcePosition);

  /// seek 位置保护期（pendingSeek 未落位）期间轮询早退。
  bool shouldPreserveSeekPosition();

  /// seek 落位宽限窗（宿主所有、seek 流程写；轮询体读 + 到期清空）。
  DateTime? get seekSettleUntil;
  set seekSettleUntil(DateTime? value);

  /// 期望正在自动播放的意图标记（宿主所有；轮询体读 + 起播后清除）。
  bool get expectingAutoplay;
  set expectingAutoplay(bool value);

  /// 在途网络流加载标记（宿主所有、seek/加载流程写；轮询体读 + 超界清空）。
  int? get streamLoadInFlightGeneration;
  set streamLoadInFlightGeneration(int? value);
  String? get streamLoadInFlightSongId;
  set streamLoadInFlightSongId(String? value);
  int? get streamLoadInFlightSinceMs;
  set streamLoadInFlightSinceMs(int? value);

  /// 当前源的流偏移（轮询体只读：保位重载换算用）。
  Duration get sourcePositionOffset;

  /// 标记「近末尾看门狗已接管完成处理」（完成处理重入守卫，宿主字段）。
  void markCompletionHandling(String songId);

  /// 抗断网延后三级上界的可调试配置（宿主可写字段，@visibleForTesting）。
  int get debugStreamLoadLoadingCeilingMs;
  int get debugStreamLoadIdleStuckCeilingMs;
  int get debugStreamLoadNoProgressCeilingMs;

  /// 播放调试日志。
  void playDbg(String message);

  /// seek/完成调试日志。
  void seekDbg(String message);

  /// 播放指定曲目（0 秒卡死看门狗的保位重载出口）。
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    Duration? initialPosition,
  });

  /// 跳下一首（停滞看门狗自愈出口）。
  Future<void> next();

  /// 按播完处理当前曲（近末尾看门狗出口，尊重随机/单曲循环/顺序）。
  Future<void> onSongCompleted(String completedSongId);

  /// 播放失败路径（0 秒卡死判死歌后的跳歌出口）。
  void handlePlaybackError(String? songId);
}

/// 位置轮询 / 看门狗驱动：`Timer.periodic(500ms)` 驱动的看门狗集合。
///
/// 宿主（PlayerNotifier 家族）`with` 本 mixin 并实现
/// [PlaybackPositionPollingHost]；轮询状态全部内聚于此。
mixin PlaybackPositionPollingDriver on PlaybackPositionPollingHost {
  /// 位置轮询定时器。随 [startPositionPolling] 重建、[stopPositionPolling] 释放。
  Timer? _positionPollTimer;
  Duration _lastPolledPlayerPosition = Duration.zero;
  int _stagnantPositionTicks = 0;

  /// 不可见降频用的物理 tick 计数（见 [kHiddenPollDecimation]）：
  /// 每累计 [kHiddenPollDecimation] 个基准 tick 才做一次完整轮询。
  int _hiddenPollCounter = 0;

  /// 0 秒卡死兜底计数：播放意图存在但长时间卡在 loading/buffering 且
  /// 位置无进展时累计；一旦离开该状态或超出阈值即清零/reset。
  int _startupStuckTicks = 0;

  /// 当前正在被 0 秒卡死看门狗重载的曲目 id 与该曲的连续重载次数。
  /// 用于区分「瞬时挂起可自愈」与「真无可播源应放弃」。
  String? _startupStuckSongId;
  int _startupReloadStreak = 0;

  /// Windows 专项近末尾兜底计数阈值。
  ///
  /// Android 正常播完时 just_audio 会上报 completed，走常规完成流程；但
  /// Windows(just_audio 走 media_kit 后端)对部分容器的表现是：解码到字节末
  /// 后 position 顶到接近/等于声明的 duration，而 processing 却进入 buffering
  /// 而非 completed——于是 `isReadyPlaying`(要求 processing==ready)恒为 false，
  /// 导致上面的 `_stagnantPositionTicks` 每个 tick 都被清零，近末尾守卫与停滞
  /// 看门狗对 Windows 全部失效 → 「某一首歌固定的末尾卡死」。
  ///
  /// 专用于本守卫的计数不与 processing 绑定：只要「确实在播(player.playing)
  /// + 位置落在末段窗口内不再前进」就累计，到阈值即按播完处理(尊重随机/单曲
  /// 循环/顺序)。进程真正比播放引擎更可靠地表达“用户还在播但要结束了”。
  /// 5 tick ≈ 2.5s。暂停/前进/离开末段任一情况都会清零，避免误判。
  int _nearEndStuckTicks = 0;

  /// 起播/切歌时重置轮询基线：上次轮询位置对齐到本次起播进度、停滞计数清零。
  ///
  /// （原 playSong / 预览起播路径的两行内联重置，抽驱动后收拢为本入口。）
  void resetPositionTracking(Duration lastPolledPosition) {
    _lastPolledPlayerPosition = lastPolledPosition;
    _stagnantPositionTicks = 0;
  }

  /// 释放轮询定时器（宿主 dispose 等终止点调用）。
  void stopPositionPolling() {
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
  }

  void startPositionPolling(AudioPlayer player) {
    _positionPollTimer?.cancel();
    _hiddenPollCounter = 0;
    _positionPollTimer = Timer.periodic(kPositionPollBaseInterval, (_) {
      if (!mounted) return;
      // 不可见降频：抽稀掉的物理 tick 直接返回，不读取位置、不写回 UI。
      // 完整轮询用 tickWeight 加权累计，保持看门狗墙钟阈值不变。
      int tickWeight = 1;
      if (!readIsRenderingActive()) {
        _hiddenPollCounter += 1;
        if (_hiddenPollCounter < kHiddenPollDecimation) return;
        _hiddenPollCounter = 0;
        tickWeight = kHiddenPollDecimation;
      } else {
        _hiddenPollCounter = 0;
      }
      if (state.currentSong == null) return;
      if (shouldPreserveSeekPosition()) {
        return;
      }

      final sourcePlayerPos = player.position;
      final playerPos = logicalPlayerPosition(sourcePlayerPos);
      final processing = player.processingState;
      final isReadyPlaying =
          player.playing && processing == ProcessingState.ready;

      // seek 落位宽限:宽限内 source 未前进不算卡死/不计近末尾完成;source 一旦
      // 前进过 1500ms 或宽限到期即自动解除,真卡死仍由看门狗接力。
      bool inSeekSettle = false;
      if (seekSettleUntil != null) {
        if (DateTime.now().isAfter(seekSettleUntil!) ||
            sourcePlayerPos > const Duration(milliseconds: 1500)) {
          seekSettleUntil = null;
        } else {
          inSeekSettle = true;
        }
      }

      // 「确实在播」信号按平台归一化：
      // - 移动端维持 isReadyPlaying(仅 processing==ready 累计)，避免长期缓冲
      //   被误跳；这是原实现、不影响 Android/iOS。
      // - Windows(media_kit 后端)对 processing 判定更“粗”：撞容器比特末或长时间
      //   缓冲时会停留在 buffering 而非 ready，导致依赖 isReadyPlaying 的停滞
      //   看门狗计数被恒清零 → 失效。故 Windows 上改用 player.playing(播放意图，
      //   不会随 processing 变成 false) 作为停滞累计信号，与近末尾守卫同理。
      // 注意：仍保留 delta>150 才前进即重置，避免把 Windows 正常的粗粒度位置
      // 采样(每 500ms 报 150~300ms 前移)误当作停滞而误跳下一首。
      final isWinDesktop = !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.windows;
      final stallSignal = isWinDesktop ? player.playing : isReadyPlaying;

      final deltaFromLast = (sourcePlayerPos - _lastPolledPlayerPosition)
          .inMilliseconds
          .abs();
      // 0 秒卡死独立计数：播放意图存在但卡在起点(loading/buffering 或位置
      // 长期 <=0)且位置无进展时累计；一旦真的开始播/位置前进/暂停即清零。
      // just_audio 在 buffering/loading 时 player.playing 仍保持 true。
      // 播放意图 = playing 或「尚未真正开始播放但期望自动播放」(expectingAutoplay)：
      // 源加载本身若挂起不返回,player.playing 恒为 false,仅凭 playing 会漏判。
      final atStart =
          sourcePlayerPos <= const Duration(milliseconds: 1500) ||
          state.position <= const Duration(milliseconds: 1500);
      final hasNoProgress = deltaFromLast <= 150 ||
          (processing == ProcessingState.loading ||
              processing == ProcessingState.buffering);
      final wantsPlaying = player.playing || expectingAutoplay;
      // 判定外提（ADR-2 阶段 1，[nextStartupStuckTicks]）：只搬运计数转移，字段仍在驱动内。
      _startupStuckTicks = nextStartupStuckTicks(
        current: _startupStuckTicks,
        tickWeight: tickWeight,
        wantsPlaying: wantsPlaying,
        atStart: atStart,
        hasNoProgress: hasNoProgress,
        inSeekSettle: inSeekSettle,
        preserveSeekPosition: shouldPreserveSeekPosition(),
      );
      // 一旦位置确有前进(迈出起点)，视为已恢复，清空期望意图标记与计数，
      // 避免后续看门狗仅凭旧标记误判。
      if (hasLeftStartup(sourcePlayerPos)) {
        expectingAutoplay = false;
        // 真正开始播放：清零「连续重载」计数与标记，同曲后续再停滞从 1 重新计，
        // 不会因历史卡死而被立刻判死。
        if (_startupReloadStreak > 0 || _startupStuckSongId != null) {
          _startupReloadStreak = 0;
          _startupStuckSongId = null;
        }
      }
      // 仅「确实在播」状态累计停滞计数；暂停/缓冲/加载一律清零，
      // 否则暂停很久后恢复会因计数已越阈值而被看门狗误跳下一首。
      // (stallSignal 在 Windows 上为 player.playing、移动端为 isReadyPlaying)
      // 起点阶段(atStart)一律清零：0 秒卡死由 _startupStuckTicks 重载路径
      // 负责；若这里也累计,Windows 上加载/buffering 阶段(playing 仍 true)会
      // 提前攒到阈值,用「跳下一首」取代更温和的「重载自愈」+死歌判定。
      // [D-053] 合成进度兜底（synthetic position fallback）已按用户决策整体删除
      // （2026-10-07：合成进度回退功能不要）。原激活条件（sourcePlayerPos<=50ms
      // 且 _stagnantPositionTicks>=6）与本分支 atStart 清零逻辑互斥，属不可达
      // 死代码；源卡死时 UI 进度本就冻结（无合成推进），自愈由 0 秒卡死/停滞/
      // 近末尾三道看门狗接管。
      // 判定外提（ADR-2 阶段 1，[nextStagnantTicks]）。
      _stagnantPositionTicks = nextStagnantTicks(
        current: _stagnantPositionTicks,
        tickWeight: tickWeight,
        atStart: atStart,
        stallSignal: stallSignal,
        deltaMs: deltaFromLast,
      );
      // Windows 专项近末尾计数：不依赖 processing==ready(见字段注释)。
      // Windows 撞到容器 EOF 常把 processing 置于 buffering 而非 completed，
      // 通用计数随之被清零，导致看门狗对 Windows 末尾卡死失效。这里只要
      // 「确实在播 + 位置停在末段 2.5s 窗口内不再前进」就累计；暂停/前进/
      // 离开末段任一情况立即清零，避免误判。
      // 附加：另有部分容器与媒体后端在 EOF 处会把 playing 置 false、processing
      // 搁到 idle/其他 ≠completed，同样不上报 completed —— 此时 position 恰好
      // 到达/越过声明 duration。故「位置已到声明末尾」也计为「该结束了」，覆盖
      // 0秒/中途/近末尾三道看门狗(都要求 playing)原本都漏判的 Windows 场景。
      final endEngaged = isNearEndCompletionEngaged(
        duration: state.duration,
        position: state.position,
        playing: player.playing,
      );
      // 判定外提（ADR-2 阶段 1，[nextNearEndStuckTicks]）。
      _nearEndStuckTicks = nextNearEndStuckTicks(
        current: _nearEndStuckTicks,
        tickWeight: tickWeight,
        endEngaged: endEngaged,
        deltaMs: deltaFromLast,
        inSeekSettle: inSeekSettle,
      );
      _lastPolledPlayerPosition = sourcePlayerPos;

      // 0 秒卡死兜底看门狗：播放意图存在但长时间(≥阈值)卡在起点
      // (loading/buffering 或位置长期 ≤0)且位置无进展时，重载当前曲目，
      // 等效于「切下一首再切回」——同一歌手动操作被确认能恢复播放。
      // 与 _stagnantPositionTicks 语义不同：后者仅在「就绪播放」累计，
      // 而 0 秒卡死恰恰发生在 loading/buffering 阶段(player.playing 仍 true)，
      // 若复用旧看门狗，该阶段计数会被恒清零、永不触发。
      if (_startupStuckTicks >= _startupStuckSkipThresholdTicks) {
        // 抗断网守卫（batch44）：当前曲的网络流加载仍在途（setUrl 未返回）
        // 时，「卡在起点」正是服务端在挂起重试窗口内等上游（总窗口 30 分钟，
        // 前 1 分钟每 10s →之后每分钟）—— 此刻不得 reload（会拆掉在途请求
        // 并让服务端重开整个重试窗口，也是无节流紧凑重试）也不得跳歌。
        // 清零计数延迟介入，等服务端窗口落定：成功则位置前进自然解除；
        // 显式失败则 setUrl 抛错，照常走播放失败路径（转码重试 →
        // handlePlaybackError 自动跳歌），客户端不抢在服务端之前掐断。
        // 仅守卫「流加载在途」本身：真正起播后仍卡死（服务端已响应但源坏）
        // 的场景不受影响，计数从零重新累计、看门狗照常接力。
        //
        // ★ 上限 + **状态判别**兜底（修「Windows 卡死在歌曲开头」，2026-10-11）：
        //   用户实测日志（v5.8.0 / Windows / media_kit）坐实：反代对慢首字节回
        //   502 时，平台层**压根没接管音源** —— `processingState` 由 loading 落到
        //   `idle` 并**永远**停住，`setUrl` 的 Future 既不 resolve 也不 reject，
        //   于是本守卫被无限期触发 → 播放永久冻结在 0 秒且无任何用户可见报错。
        //   这与「服务端挂起重试窗口」（平台应为 `loading`）是**可区分**的形态：
        //     · `loading` + 播放意图 + 位置零前进：平台已接管，但可能长期停在加载态
        //       等数据 —— 30s 无进展上限（★★ 两级上界，详见下方）。
        //     · `idle` + 仍有播放意图 + 位置≈0 + duration=0：平台未接管，判为
        //       真实起播失败 —— 用短上限(10s)超界即**清在途标记**（只是不再拿它
        //       当挡箭牌，并不拆掉在途 HTTP 请求）→ 既有升级链
        //       （reload 当前曲 → 连续达容错上限判死歌 → handlePlaybackError 跳歌）。
        final inFlightSongId = streamLoadInFlightSongId;
        final loadInFlight =
            inFlightSongId != null && inFlightSongId == state.currentSong?.id;
        final playerDuration = player.duration;
        // 为什么用 `processing` + **位置零前进** 来判「真实起播失败」？
        //   `player.processingState` 并非平台上报值的直通，而是被 just_audio 的
        //   `_platformLoading` 掩码位统一过：只要平台已声明「加载中」，应用侧一律
        //   看到 `loading`，**绝不会**看到 `idle`：
        //     if (_platformLoading && message.processingState != idle)
        //       _platformLoading = false;                 // just_audio 本体掩码
        //     processingState: _platformLoading
        //         ? loading
        //         : values[message.processingState.index];
        //   （见 third_party/just_audio 内 `_setPlatformActive`/`_platformLoading` 一带）
        //   于是可据此二分：
        //     · `idle`    ⟺ 平台不在加载态（含其自报错误 / 停止）→ 判为「压根没接管」。
        //     · `loading` ⟺ 平台已接管音源，但可能停在加载态等数据（不保证会推进）。
        //
        // ★★ 两级上界（修「Windows loading 态永久卡死」，2026-10-12）：
        //   把 `loading` **整体**当作「合法长等待、唯一上界 30min」是错误的。
        //   just_audio_media_kit 给 libmpv 传了 **`network-timeout=0`（无限等网络）**：
        //   当反代/上游慢、或反代 10s 超时把连接搞坏时，libmpv **不报错**，只长期停在
        //   `loading@0:00` 等数据 —— 应用侧看到 `loading`（掩码清除分支），若沿用
        //   30min 上界 → 表现为**永久卡死**（用户实测：「歌单第一首会卡在开始，手动
        //   切歌才能正常播放」「我不难过 这首还是没正常播放」；歌单第一首没有前一首，
        //   无预取可用、只能冷抓，冷抓首字节实测 5.1s、慢时超时）。
        //   故按 processing 分**两级**上界：
        //     · `idle` + 播放意图 + 位置≈0：平台压根没接管 → 短上限(idle 档 10s)。
        //     · `loading` + 播放意图 + 位置**零前进**：平台已接管但等不到数据
        //       → 中上限(loading 档 30s)。超界**同样**清在途标记 → 交给既有升级链
        //       （reload 当前曲 → 连续达容错上限判死歌 → handlePlaybackError 跳歌），
        //       不新增第二套恢复逻辑。
        //     · 其余：兜底 30min 安全网（真实服务端重试窗口 ≤30min 内必然落定）。
        //   30s 依据：合法冷启动最坏 ≈ membuf 18s 硬顶 + ffmpeg 起播，实测正常
        //   冷抓首字节 5-8s；30s 不会误杀慢歌，又能救 loading 卡死。
        //
        //   ⚠ 为什么**不能**用 `duration == 0` 当 loading 档的必要条件？libmpv/flac
        //   一打开（拿到响应头）通常就知道总时长，`duration` 很快变为非 0；若把
        //   `duration == 0` 当必要条件，看门狗会被解除 → 又退回永久卡死。故 loading
        //   档**只基于位置零前进**（`sourcePlayerPos <= 1.5s`），不看 duration。
        //
        //   两端真实包对得上：
        //     · 合法慢加载：just_audio_media_kit 的 `load()`（mediakit_player.dart
        //       L236 置 `_processingState = ProcessingStateMessage.loading`、
        //       L239 `_updatePlaybackEvent()` 发出）**先发 loading** → 掩码被清 →
        //       应用看到 loading → 走 loading 档(30s)；最坏冷启动亦在 30s 内起播，
        //       不误杀。
        //     · 502 失败：media_kit 错误回调（同文件 L144-151）回 `idle`，而掩码已被
        //       前面的 loading 清掉 → 应用**真的看到 `idle`** → 走 idle 档(10s)。
        //   ⚠ 前提假设：平台**先发 loading、后发 error**。若某实现顺序反转（先 error
        //   后首个非 idle），掩码仍为真 → 应用看到 loading → 落入 loading 档(30s)
        //   兜住（不再是 30min 永久冻结，属可接受的自愈时延）。
        // 档位判定外提（ADR-2 阶段 1）：[classifyStreamLoadStuck] 归一三档，
        // [streamLoadStuckCeilingMs] 选择在途等待上界；宿主仅注入可调试配置。
        final stuckLevel = classifyStreamLoadStuck(
          processing: processing,
          wantsPlaying: wantsPlaying,
          sourcePlayerPos: sourcePlayerPos,
          playerDuration: playerDuration,
        );
        final platformNeverTookSource =
            stuckLevel == StreamLoadStuckLevel.idleNeverTookSource;
        final inLoadingNoProgress =
            stuckLevel == StreamLoadStuckLevel.loadingNoProgress;
        // 三档优先级：idle 档(10s) > loading 档(30s) > 兜底(30min)。
        final ceilingMs = streamLoadStuckCeilingMs(
          level: stuckLevel,
          idleNeverTookSourceMs: debugStreamLoadIdleStuckCeilingMs,
          loadingNoProgressMs: debugStreamLoadNoProgressCeilingMs,
          fallbackMs: debugStreamLoadLoadingCeilingMs,
        );
        final inFlightMs = loadInFlight && streamLoadInFlightSinceMs != null
            ? DateTime.now().millisecondsSinceEpoch -
                streamLoadInFlightSinceMs!
            : 0;
        final deferInFlight = loadInFlight && inFlightMs < ceilingMs;
        if (deferInFlight) {
          _startupStuckTicks = 0;
          playDbg(
            'startup_stuck_watchdog deferred: stream load in flight '
            'song=$inFlightSongId inFlightMs=$inFlightMs ceilingMs=$ceilingMs '
            'idleStuck=$platformNeverTookSource '
            'loadingNoProgress=$inLoadingNoProgress '
            'processing=${processing.name} playing=${player.playing}',
          );
        } else {
          if (loadInFlight) {
            // 自愈：无论 setUrl 的 Future 是否完成，在途标记都不得永久为真。
            // 仅停止「当挡箭牌」，不拆在途请求（请求终态由平台自理）。
            streamLoadInFlightGeneration = null;
            streamLoadInFlightSongId = null;
            streamLoadInFlightSinceMs = null;
            playDbg(
              'startup_stuck_watchdog defer ceiling exceeded -> act '
              'song=$inFlightSongId inFlightMs=$inFlightMs ceilingMs=$ceilingMs '
              'idleStuck=$platformNeverTookSource '
              'loadingNoProgress=$inLoadingNoProgress '
              'processing=${processing.name} playing=${player.playing} '
              'duration=$playerDuration',
            );
          }
          final stuckSong = state.currentSong;
          final startTicks = _startupStuckTicks;
          final stuckSongId = stuckSong?.id;
          _startupStuckTicks = 0;
          // 区分「瞬时挂起」(重载一次即恢复)与「真无可播源」(重载仍卡 0 秒):
          // 同一首连续达到重载容错上限仍无进展,判定为不可播,转入既有失败跳歌
          // 逻辑(handlePlaybackError)标记死歌并跳下一首,而非无限重载同一首
          // 原地空转——若后端确无可播源,重载多少次都无济于事。
          if (stuckSongId != null && _startupStuckSongId == stuckSongId) {
            _startupReloadStreak += 1;
          } else {
            _startupStuckSongId = stuckSongId;
            _startupReloadStreak = 1;
          }
          if (stuckSongId != null &&
              _startupReloadStreak >= _startupReloadTolerance) {
            playDbg(
              'startup_stuck_watchdog GIVE_UP reload_streak=$_startupReloadStreak '
              'song=$stuckSongId ticks=$startTicks sourcePlayerPos=$sourcePlayerPos '
              'processing=${processing.name} — judged unplayable, skip to next',
            );
            _startupStuckSongId = null;
            _startupReloadStreak = 0;
            handlePlaybackError(stuckSongId);
            return;
          }
          playDbg(
            'startup_stuck_watchdog reload song=$stuckSongId '
            'reload_streak=$_startupReloadStreak/$_startupReloadTolerance '
            'ticks=$startTicks sourcePlayerPos=$sourcePlayerPos '
            'statePos=${state.position} processing=${processing.name} '
            'playing=${player.playing}',
          );
          if (stuckSong != null) {
            // 保位重载（流转/续播接收端「从头播放」根因修复）：带 timeOffset
            // 的首载流解码 timeline 自 0 起，换算后的逻辑进度 playerPos 才是用户
            // 真实进度。此前这里不传 initialPosition，重载落回 timeOffset=0 从头播
            // —— Windows(media_kit) 慢起播被 0 秒卡死看门狗误判并重载时必然从头
            // 出声。仅在有流偏移时保位，普通曲目卡死的重载语义保持不变。
            unawaited(
              playSong(
                stuckSong,
                queue: state.queue,
                index: state.currentIndex,
                initialPosition:
                    sourcePositionOffset > Duration.zero ? playerPos : null,
              ),
            );
            return;
          }
        }
      }

      // 正常情况下用底层播放器位置对齐 UI 进度。
      final drift = (playerPos - state.position).inMilliseconds.abs();
      if (drift >= 250) {
        state = state.copyWith(position: playerPos);
        return;
      }
      // 近末尾守卫(Windows 专项增强)：某些源尾段 position 会停在 duration
      // 前一小段不再前推，或到达/越过声明末尾而 completed 永不触发 → 末尾永久
      // 卡死、不自动接续。Windows 解码器(via just_audio/media_kit)撞到容器 EOF
      // 常见三种异常：processing 停在 buffering；或 playing 被置 false、processing
      // 搁到 idle/其他 ≠completed。因此这里用与 processing 无关的
      // `_nearEndStuckTicks`——只要「(确实在播) 或 (位置已到声明末尾)」且位置停在
      // 末段 2.5s 窗口内不前进，累计满阈值即视为播完并走正式完成流程
      // (尊重 随机/单曲循环/顺序)。
      if (isNearEndCompletionEngaged(
            duration: state.duration,
            position: state.position,
            playing: player.playing,
          ) &&
          _nearEndStuckTicks >= _nearEndStuckTicksThreshold) {
        final doneSongId = state.currentSong?.id;
        final hasPartialStuckTicks = _nearEndStuckTicks;
        if (doneSongId != null) {
          _nearEndStuckTicks = 0;
          markCompletionHandling(doneSongId);
          seekDbg(
            'near-end(win) stuck -> treat as completed song=$doneSongId '
            'pos=${state.position} dur=${state.duration} '
            'ticks=$hasPartialStuckTicks processing=${processing.name}',
          );
          unawaited(onSongCompleted(doneSongId));
          return;
        }
      }

      // 停滞看门狗：确实在播但进度持续不走，
      // 达到阈值即自动跳下一首自愈。统一作用于本机与远程试听，
      // 保持继续跳直到找到能前進的歌曲。
      // (stallSignal 在 Windows 上为 player.playing、移动端为 isReadyPlaying，
      //  避免 Windows 因 processing 卡在 buffering 而被看门狗漏判)
      if (stallSignal &&
          _stagnantPositionTicks >= _stagnantSkipThresholdTicks) {
        final stuckTicks = _stagnantPositionTicks;
        _stagnantPositionTicks = 0;
        playDbg(
          'stall_watchdog skip_to_next song=${state.currentSong?.id} '
          'ticks=$stuckTicks sourcePlayerPos=$sourcePlayerPos '
          'statePos=${state.position} '
          'processing=${processing.name} playing=${player.playing}',
        );
        unawaited(next());
        return;
      }

    });
  }
}
