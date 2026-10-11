part of 'player_provider.dart';

const int _stagnantSkipThresholdTicks = 10;
const int _startupStuckSkipThresholdTicks = 12;
const int _startupReloadTolerance = 2;
const int _nearEndStuckTicksThreshold = 5;

mixin PlayerPositionPollingInternals on PlayerNotifier {
  void _startPositionPolling(AudioPlayer player) {
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (state.currentSong == null) return;
      if (_shouldPreserveSeekPosition()) {
        return;
      }

      final sourcePlayerPos = player.position;
      final playerPos = _logicalPlayerPosition(sourcePlayerPos);
      final processing = player.processingState;
      final isReadyPlaying =
          player.playing && processing == ProcessingState.ready;

      // seek 落位宽限:宽限内 source 未前进不算卡死/不计近末尾完成;source 一旦
      // 前进过 1500ms 或宽限到期即自动解除,真卡死仍由看门狗接力。
      bool inSeekSettle = false;
      if (_seekSettleUntil != null) {
        if (DateTime.now().isAfter(_seekSettleUntil!) ||
            sourcePlayerPos > const Duration(milliseconds: 1500)) {
          _seekSettleUntil = null;
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
      // 播放意图 = playing 或「尚未真正开始播放但期望自动播放」(_expectingAutoplay)：
      // 源加载本身若挂起不返回,player.playing 恒为 false,仅凭 playing 会漏判。
      final atStart =
          sourcePlayerPos <= const Duration(milliseconds: 1500) ||
          state.position <= const Duration(milliseconds: 1500);
      final hasNoProgress = deltaFromLast <= 150 ||
          (processing == ProcessingState.loading ||
              processing == ProcessingState.buffering);
      final wantsPlaying = player.playing || _expectingAutoplay;
      if (wantsPlaying &&
          atStart &&
          hasNoProgress &&
          !inSeekSettle &&
          !_shouldPreserveSeekPosition()) {
        _startupStuckTicks += 1;
      } else {
        _startupStuckTicks = 0;
      }
      // 一旦位置确有前进(迈出起点)，视为已恢复，清空期望意图标记与计数，
      // 避免后续看门狗仅凭旧标记误判。
      if (sourcePlayerPos > const Duration(milliseconds: 1500)) {
        _expectingAutoplay = false;
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
      if (atStart) {
        _stagnantPositionTicks = 0;
      } else if (!stallSignal || deltaFromLast > 150) {
        _stagnantPositionTicks = 0;
      } else {
        _stagnantPositionTicks += 1;
      }

      // Windows 专项近末尾计数：不依赖 processing==ready(见字段注释)。
      // Windows 撞到容器 EOF 常把 processing 置于 buffering 而非 completed，
      // 通用计数随之被清零，导致看门狗对 Windows 末尾卡死失效。这里只要
      // 「确实在播 + 位置停在末段 2.5s 窗口内不再前进」就累计；暂停/前进/
      // 离开末段任一情况立即清零，避免误判。
      // 附加：另有部分容器与媒体后端在 EOF 处会把 playing 置 false、processing
      // 搁到 idle/其他 ≠completed，同样不上报 completed —— 此时 position 恰好
      // 到达/越过声明 duration。故「位置已到声明末尾」也计为「该结束了」，覆盖
      // 0秒/中途/近末尾三道看门狗(都要求 playing)原本都漏判的 Windows 场景。
      final inNearEndWindow =
          state.duration > const Duration(seconds: 3) &&
          state.duration - state.position <=
              const Duration(milliseconds: 2500);
      final endEngaged =
          inNearEndWindow &&
          (player.playing || state.position >= state.duration);
      if (endEngaged && deltaFromLast <= 150 && !inSeekSettle) {
        _nearEndStuckTicks += 1;
      } else {
        _nearEndStuckTicks = 0;
      }
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
        // _handlePlaybackError 自动跳歌），客户端不抢在服务端之前掐断。
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
        //       （reload 当前曲 → 连续达容错上限判死歌 → _handlePlaybackError 跳歌）。
        final inFlightSongId = _streamLoadInFlightSongId;
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
        //       （reload 当前曲 → 连续达容错上限判死歌 → _handlePlaybackError 跳歌），
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
        final platformNeverTookSource =
            processing == ProcessingState.idle &&
                wantsPlaying &&
                sourcePlayerPos <= const Duration(milliseconds: 1500) &&
                (playerDuration == null || playerDuration == Duration.zero);
        // loading 档（无进展）：已请求播放 && 平台处于 loading && 位置始终没越过 1.5s。
        // 依据「位置零前进」而非 `duration == 0`（libmpv 一打开就带时长，见上）。
        final inLoadingNoProgress = wantsPlaying &&
            processing == ProcessingState.loading &&
            sourcePlayerPos <= const Duration(milliseconds: 1500);
        // 三档优先级：idle 档(10s) > loading 档(30s) > 兜底(30min)。
        final ceilingMs = platformNeverTookSource
            ? debugStreamLoadIdleStuckCeilingMs
            : (inLoadingNoProgress
                ? debugStreamLoadNoProgressCeilingMs
                : debugStreamLoadLoadingCeilingMs);
        final inFlightMs = loadInFlight && _streamLoadInFlightSinceMs != null
            ? DateTime.now().millisecondsSinceEpoch -
                _streamLoadInFlightSinceMs!
            : 0;
        final deferInFlight = loadInFlight && inFlightMs < ceilingMs;
        if (deferInFlight) {
          _startupStuckTicks = 0;
          _playDbg(
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
            _streamLoadInFlightGeneration = null;
            _streamLoadInFlightSongId = null;
            _streamLoadInFlightSinceMs = null;
            _playDbg(
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
          // 逻辑(_handlePlaybackError)标记死歌并跳下一首,而非无限重载同一首
          // 原地空转——若后端确无可播源,重载多少次都无济于事。
          if (stuckSongId != null && _startupStuckSongId == stuckSongId) {
            _startupReloadStreak += 1;
          } else {
            _startupStuckSongId = stuckSongId;
            _startupReloadStreak = 1;
          }
          if (stuckSongId != null &&
              _startupReloadStreak >= _startupReloadTolerance) {
            _playDbg(
              'startup_stuck_watchdog GIVE_UP reload_streak=$_startupReloadStreak '
              'song=$stuckSongId ticks=$startTicks sourcePlayerPos=$sourcePlayerPos '
              'processing=${processing.name} — judged unplayable, skip to next',
            );
            _startupStuckSongId = null;
            _startupReloadStreak = 0;
            _handlePlaybackError(stuckSongId);
            return;
          }
          _playDbg(
            'startup_stuck_watchdog reload song=$stuckSongId '
            'reload_streak=$_startupReloadStreak/$_startupReloadTolerance '
            'ticks=$startTicks sourcePlayerPos=$sourcePlayerPos '
            'statePos=${state.position} processing=${processing.name} '
            'playing=${player.playing}',
          );
          if (stuckSong != null) {
            unawaited(
              playSong(
                stuckSong,
                queue: state.queue,
                index: state.currentIndex,
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
      if (state.duration > const Duration(seconds: 3) &&
          state.duration - state.position <=
              const Duration(milliseconds: 2500) &&
          (player.playing || state.position >= state.duration) &&
          _nearEndStuckTicks >= _nearEndStuckTicksThreshold) {
        final doneSongId = state.currentSong?.id;
        final hasPartialStuckTicks = _nearEndStuckTicks;
        if (doneSongId != null) {
          _nearEndStuckTicks = 0;
          _isHandlingCompletion = true;
          _completionHandlingSongId = doneSongId;
          _seekDbg(
            'near-end(win) stuck -> treat as completed song=$doneSongId '
            'pos=${state.position} dur=${state.duration} '
            'ticks=$hasPartialStuckTicks processing=${processing.name}',
          );
          unawaited(this._onSongCompleted(doneSongId));
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
        _playDbg(
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
