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
      // 合成进度兜底正在承担推进时(锁缓存流可能以 0 上报真实位置但音频在播),
      // 不把“定位在起点”当作 0 秒卡死,否则看门狗会重载一首正常在播的歌。
      // 已移除边播边缓存(LockCachingAudioSource)，不再需要对锁缓存流做
      // “位置报 0 但音频在播”的合成进度护航，相关分支恒为 false。
      final syntheticCarrying =
          _syntheticPositionFallbackActive &&
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50);
      if (wantsPlaying &&
          atStart &&
          hasNoProgress &&
          !syntheticCarrying &&
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
      if (endEngaged && deltaFromLast <= 150) {
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

      // 正常情况下用底层播放器位置对齐 UI 进度。
      final drift = (playerPos - state.position).inMilliseconds.abs();
      final keepSyntheticProgress =
          _syntheticPositionFallbackActive &&
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50);
      final preserveSyntheticPosition =
          _syntheticPositionFallbackActive &&
          state.position > const Duration(milliseconds: 250) &&
          (!isReadyPlaying ||
              playerPos + const Duration(seconds: 5) < state.position);

      if (drift >= 250 &&
          !keepSyntheticProgress &&
          !preserveSyntheticPosition) {
        final canDeactivateSynthetic =
            _syntheticPositionFallbackActive &&
            isReadyPlaying &&
            sourcePlayerPos > Duration.zero &&
            drift <= 3000;
        if (canDeactivateSynthetic) {
          _syntheticPositionFallbackActive = false;
          _seekDbg('position fallback deactivated, player position recovered');
        }
        state = state.copyWith(position: playerPos);
        return;
      }
      if (drift >= 250 &&
          preserveSyntheticPosition &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _playDbg(
          'position sync skipped to preserve synthetic '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'driftMs=$drift playing=${player.playing} '
          'processing=${processing.name} song=${state.currentSong?.id}',
        );
      }
      if (drift >= 250 &&
          keepSyntheticProgress &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _playDbg(
          'position drift sync skipped while synthetic active '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'driftMs=$drift song=${state.currentSong?.id}',
        );
      }

      // iOS + LockCachingAudioSource 某些流上 position 可能卡在 0。
      // 当确认持续卡住时，按时间片推进 UI 进度，避免进度条一直 0:00。
      final shouldUseSyntheticPosition =
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50) &&
          state.duration > Duration.zero &&
          _stagnantPositionTicks >= 6;
      if (shouldUseSyntheticPosition &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _lastStagnantLogTick = _stagnantPositionTicks;
        _playDbg(
          'position_stagnant ticks=$_stagnantPositionTicks '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'buffered=${player.bufferedPosition} duration=${state.duration} '
          'processing=${processing.name} playing=${player.playing} '
          'song=${state.currentSong?.id} '
          'format=$_currentStreamFormat maxBitRate=$_currentStreamMaxBitRate '
          'stream=${_summarizeStreamUrl(_currentStreamUrl)}',
        );
      }
      // 近末尾守卫(Windows 专项增强)：某些源尾段 position 会停在 duration
      // 前一小段不再前推，或到达/越过声明末尾而 completed 永不触发 → 末尾永久
      // 卡死、不自动接续。Windows 解码器(via just_audio/media_kit)撞到容器 EOF
      // 常见三种异常：processing 停在 buffering；或 playing 被置 false、processing
      // 搁到 idle/其他 ≠completed。因此这里用与 processing 无关的
      // `_nearEndStuckTicks`——只要「(确实在播) 或 (位置已到声明末尾)」且位置停在
      // 末段 2.5s 窗口内不前进，累计满阈值即视为播完并走正式完成流程
      // (尊重 随机/单曲循环/顺序)。
      if (!shouldUseSyntheticPosition &&
          state.duration > const Duration(seconds: 3) &&
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

      // 停滞看门狗：确实在播但进度持续不走(非合成进度场景)，
      // 达到阈值即自动跳下一首自愈。统一作用于本机与远程试听，
      // 保持继续跳直到找到能前進的歌曲。
      // (stallSignal 在 Windows 上为 player.playing、移动端为 isReadyPlaying，
      //  避免 Windows 因 processing 卡在 buffering 而被看门狗漏判)
      if (stallSignal &&
          !shouldUseSyntheticPosition &&
          _stagnantPositionTicks >= _stagnantSkipThresholdTicks) {
        final stuckTicks = _stagnantPositionTicks;
        _stagnantPositionTicks = 0;
        _playDbg(
          'stall_watchdog skip_to_next song=${state.currentSong?.id} '
          'ticks=$stuckTicks sourcePlayerPos=$sourcePlayerPos '
          'statePos=${state.position} '
          'processing=${processing.name} playing=${player.playing}',
        );
        // 注意：本函数作用域内存在局部变量 `next`(Duration)，其声明在下方，
        // Dart 中局部变量会遮蔽同名成员方法，故必须显式用 this.next() 调用跳歌方法。
        unawaited(this.next());
        return;
      }

      // 非合成进度在此结束(两个守卫都要求非合成，不会在这里触发)；
      // 合成进度才继续往下，按时间片推进 UI 进度。
      if (!shouldUseSyntheticPosition) return;

      final next = _normalizeSeekPosition(
        state.position + const Duration(milliseconds: 500),
      );
      if (next <= state.position) return;

      if (!_syntheticPositionFallbackActive) {
        _syntheticPositionFallbackActive = true;
        _seekDbg(
          'position fallback activated song=${state.currentSong?.id}',
        );
      }
      state = state.copyWith(position: next);
    });
  }

}
