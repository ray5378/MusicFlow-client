part of 'player_provider.dart';

/// 「连续失败自动跳」连跳段的网络加载节流时长。
///
/// 只把真正发起音频加载（setUrl/setAudioSource 的 GET）这一步延后，绝不冻结
/// next() / state / currentSong 的推进，避免 v5.0.9「Future.delayed 冻结跳转
/// 导致流转上报读不到歌」的回归。
const _kLoadThrottleOnFailStreak = Duration(milliseconds: 300);

mixin PlayerSeekInternals on PlayerNotifier {
  Duration _normalizeSeekPosition(Duration position) => normalizeSeekPosition(
      position,
      state.duration,
    );

  Future<void> _applyPendingSeekIfNeeded() async {
    if (_isApplyingPendingSeek) return;

    final player = _audioPlayer;
    final pending = _pendingSeekPosition;
    final pendingSongId = _pendingSeekSongId;
    final currentSongId = state.currentSong?.id;
    if (player == null ||
        pending == null ||
        pendingSongId == null ||
        currentSongId == null) {
      return;
    }
    if (pendingSongId != currentSongId) return;

    final canSeekNow = canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    );
    if (!canSeekNow) return;

    _isApplyingPendingSeek = true;
    final seekGeneration = ++_seekRequestGeneration;
    final playbackSession = _playDebugSession;
    bool isCurrentSeek() => _isSeekRequestCurrent(
      seekGeneration: seekGeneration,
      playbackSession: playbackSession,
      songId: currentSongId,
    );
    bool ownsSource() => _isPlaybackContextCurrent(
      session: playbackSession,
      songId: currentSongId,
    );
    final target = _normalizeSeekPosition(pending);
    _activeSeekGeneration = seekGeneration;
    _activeSeekSongId = currentSongId;
    _seekDbg(
      'applyPendingSeek song=$currentSongId target=$target '
      'playerPos=${player.position} state=${player.processingState.name}',
    );
    _clearPendingSeek();
    try {
      await _seekWithFallback(
        target,
        songId: currentSongId,
        isCurrentSeek: isCurrentSeek,
        ownsSource: ownsSource,
      );
      if (isCurrentSeek() && mounted) {
        state = state.copyWith(position: target);
      }
    } finally {
      _releaseSeekAnchor(seekGeneration);
      _isApplyingPendingSeek = false;
      _schedulePendingSeekIfReady();
    }
  }

  /// seek 重拉后的温和恢复:只补一次 play(),被拒(新源仍在 loading/
  /// buffering 的首包瞬态)仅记日志,不走 _handlePlaybackError→next()。
  /// 背景:reload 成功后调 _startPlayback,一旦 play() 因首包未到被拒就会把
  /// 一次正常拖动变成「拖一下就跳歌」。真失败由停滞/0秒卡死看门狗接力。
  void _softResumePlayback() {
    final player = _audioPlayer;
    if (player == null || player.playing) return;
    unawaited(
      player.play().catchError((Object e) {
        Logger.warn('seek resume play() rejected (transient?), watchdog covers: $e');
      }),
    );
  }

  Future<void> _seekWithFallback(
    Duration target, {
    required String songId,
    required bool Function() isCurrentSeek,
    required bool Function() ownsSource,
  }) async {
    final player = _audioPlayer;
    if (player == null || !isCurrentSeek()) return;

    if (_seekByReloadStream &&
        _currentStreamSongId == songId &&
        _currentStreamUrl != null) {
      final shouldResume = player.playing;
      final seekTarget = TranscodedStreamSeekTarget.fromLogical(target);
      if (seekTarget.serverOffset != _sourcePositionOffset) {
        await _reloadStreamForSeek(
          player: player,
          songId: songId,
          target: target,
          seekTarget: seekTarget,
          streamFormat: _currentStreamFormat,
          streamMaxBitRate: _currentStreamMaxBitRate,
          shouldResume: shouldResume,
          isCurrentSeek: isCurrentSeek,
          ownsSource: ownsSource,
        );
        return;
      }
      // 同段微调(目标与当前流同一逻辑段,常发生在拖动连续触发时):源内 seek
      // 足够,不必每次重拉(省 setUrl + 服务端转码首包等待);源拒收(转码流不
      // 可字节 seek)则升级全量重拉。
      try {
        await player.seek(seekTarget.sourcePosition);
      } catch (_) {
        if (!isCurrentSeek()) return;
        _seekDbg('same-segment seek rejected, upgrading to reload');
        await _reloadStreamForSeek(
          player: player,
          songId: songId,
          target: target,
          seekTarget: seekTarget,
          streamFormat: _currentStreamFormat,
          streamMaxBitRate: _currentStreamMaxBitRate,
          shouldResume: shouldResume,
          isCurrentSeek: isCurrentSeek,
          ownsSource: ownsSource,
        );
        return;
      }
    }
    final sourceTarget = _sourceSeekPosition(target);
    _seekDbg(
      'seek execute target=$target sourceTarget=$sourceTarget '
      'sourceFrom=${player.position} '
      'from=${_logicalPlayerPosition(player.position)} '
      'sourceOffset=$_sourcePositionOffset '
      'state=${player.processingState.name}',
    );
    await player.seek(sourceTarget);
    if (!isCurrentSeek()) return;

    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!isCurrentSeek()) return;
    final actual = _logicalPlayerPosition(player.position);
    final drift = (actual - target).inMilliseconds.abs();
    _seekDbg(
      'seek verify target=$target sourceActual=${player.position} '
      'actual=$actual driftMs=$drift',
    );
    if (drift <= 2000) return;

    // 直连流/本地文件也做一次强制重试，规避解码器刚起播时的 seek 抖动。
    final shouldResume = player.playing;
    Logger.warn(
      'Seek drift detected on non-lock source (target=$target, actual=$actual), '
      'retrying seek',
    );
    if (shouldResume) {
      await player.pause();
      if (!isCurrentSeek()) return;
    }
    await player.seek(sourceTarget);
    if (!isCurrentSeek()) return;
    if (shouldResume) {
      _startPlayback(fadeIn: false);
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!isCurrentSeek()) return;
    _seekDbg('seek retry completed now=${player.position}');
  }

  /// 全量重拉(C5 分发目标):按 serverOffset 重建流 URL 并 setUrl,offset 同步更新。
  /// 调用方保证:跨逻辑段(或同段微调被拒)才进这里;全部路径 return,无 fallthrough。
  Future<void> _reloadStreamForSeek({
    required AudioPlayer player,
    required String songId,
    required Duration target,
    required TranscodedStreamSeekTarget seekTarget,
    required String? streamFormat,
    required int? streamMaxBitRate,
    required bool shouldResume,
    required bool Function() isCurrentSeek,
    required bool Function() ownsSource,
  }) async {
    final reloadUrl = _apiClient.getStreamUrl(
      songId,
      maxBitRate: streamMaxBitRate,
      format: streamFormat,
      timeOffset: seekTarget.serverOffset.inSeconds,
    );
    _seekDbg(
      'seek reload-stream song=$songId '
      'target=$target serverOffset=${seekTarget.serverOffset} '
      'sourcePosition=${seekTarget.sourcePosition} format=$streamFormat '
      'maxBitRate=$streamMaxBitRate wasPlaying=$shouldResume',
    );
    try {
      final sourceReady = await _replaceLoadedSource(
        songId: songId,
        label: 'seek_reload_stream',
        ownsSource: ownsSource,
        setSource: (sourcePlayer) async {
          await sourcePlayer.setUrl(
            reloadUrl,
            initialPosition: seekTarget.sourcePosition,
          );
        },
      );
      if (!sourceReady) return;
      _currentStreamUrl = reloadUrl;
      _setStreamContext(
        songId: songId,
        format: streamFormat,
        maxBitRate: streamMaxBitRate,
        seekByReloadStream: true,
        sourcePositionOffset: seekTarget.serverOffset,
      );
      // 新源从余数起步,给看门狗一个落位宽限(否则 0 秒卡死会把本次 seek 当卡死重载掉)。
      _seekSettleUntil = DateTime.now().add(const Duration(seconds: 15));
      if (!isCurrentSeek()) {
        _schedulePendingSeekIfReady();
        return;
      }
      if (mounted) {
        state = state.copyWith(position: target, bufferedPosition: target);
      }
      if (shouldResume) {
        _softResumePlayback();
      }
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!isCurrentSeek()) return;
      final actualReload = _logicalPlayerPosition(player.position);
      final reloadDrift = (actualReload - target).inMilliseconds.abs();
      _seekDbg(
        'seek reload-stream verify target=$target '
        'sourceActual=${player.position} actual=$actualReload '
        'sourceOffset=$_sourcePositionOffset driftMs=$reloadDrift',
      );
      if (reloadDrift <= 2000) return;
      Logger.warn(
        'Reload-stream seek drift still high '
        '(target=$target, actual=$actualReload), retrying plain seek',
      );
      if (!isCurrentSeek()) return;
      await player.seek(seekTarget.sourcePosition);
      return;
    } catch (e) {
      if (!isCurrentSeek()) return;
      Logger.warn('Reload-stream seek failed, fallback to plain seek', e);
      await player.seek(_sourceSeekPosition(target));
      return;
    }
  }

  void _clearPendingSeek() {
    if (_pendingSeekPosition != null || _pendingSeekSongId != null) {
      _seekDbg(
        'clearPendingSeek pending=$_pendingSeekPosition pendingSong=$_pendingSeekSongId',
      );
    }
    _pendingSeekPosition = null;
    _pendingSeekSongId = null;
  }

  void _setStreamContext({
    required String songId,
    required String? format,
    required int? maxBitRate,
    required bool seekByReloadStream,
    Duration sourcePositionOffset = Duration.zero,
  }) {
    _currentStreamSongId = songId;
    _currentStreamFormat = format;
    _currentStreamMaxBitRate = maxBitRate;
    _seekByReloadStream = seekByReloadStream;
    _setSourcePositionOffset(sourcePositionOffset);
  }

  void _clearStreamContext() {
    _currentStreamSongId = null;
    _currentStreamFormat = null;
    _currentStreamMaxBitRate = null;
    _seekByReloadStream = false;
    _seekSettleUntil = null;
    _setSourcePositionOffset(Duration.zero);
  }

  void _setSourcePositionOffset(Duration offset) {
    final normalized = offset < Duration.zero ? Duration.zero : offset;
    if (_sourcePositionOffset == normalized) return;
    _sourcePositionOffset = normalized;
    _audioHandler?.setPositionOffset(normalized);
    _seekDbg('source timeline offset updated: $normalized');
  }

  Duration _logicalPlayerPosition(Duration sourcePosition) {
    return addPlaybackPositionOffset(
      sourcePosition,
      _sourcePositionOffset,
      maximum: state.duration > Duration.zero ? state.duration : null,
    );
  }

  Duration _sourceSeekPosition(Duration logicalPosition) {
    final sourcePosition = logicalPosition - _sourcePositionOffset;
    return sourcePosition < Duration.zero ? Duration.zero : sourcePosition;
  }

  bool _isPlaybackContextCurrent({
    required int session,
    required String songId,
  }) {
    return _playDebugSession == session && state.currentSong?.id == songId;
  }

  void _invalidateLoadedSource({required String reason}) {
    _sourceGeneration += 1;
    _loadedSourceSongId = null;
    _playDbg('source invalidated generation=$_sourceGeneration reason=$reason');
  }

  Future<bool> _replaceLoadedSource({
    required String songId,
    required String label,
    required bool Function() ownsSource,
    required Future<void> Function(AudioPlayer player) setSource,
  }) async {
    final player = _audioPlayer;
    if (player == null || !ownsSource()) {
      _playDbg('source=$label setup abandoned before load song=$songId');
      return false;
    }

    final generation = ++_sourceGeneration;
    _loadedSourceSongId = null;
    _playDbg('source=$label load begin song=$songId generation=$generation');

    // 网络加载节流闸口（2026-09-17）：当正处于「连续失败自动跳」的连跳段且已
    // 连错 >= 2 首时，在每次真实加载前短暂 sleep，压低坏源成片时对反代的拉流/
    // 探测并发冲击。此处不冻结 next()——游标/state/currentSong 已在
    // _handlePlaybackError 里同步推进并照常上报，仅这一下网络 GET 被轻微延后。
    // 单次失败（_consecutiveFailSkips==1）立即重试、不 gate，避免拖慢轻量重试。
    if (_consecutiveFailSkips >= 2) {
      await Future<void>.delayed(_kLoadThrottleOnFailStreak);
    }

    try {
      await setSource(player);
    } catch (_) {
      if (_sourceGeneration == generation) {
        _loadedSourceSongId = null;
      }
      rethrow;
    }

    if (_sourceGeneration != generation ||
        !ownsSource() ||
        player.audioSource == null) {
      _playDbg(
        'source=$label load abandoned song=$songId generation=$generation '
        'currentGeneration=$_sourceGeneration',
      );
      return false;
    }

    _loadedSourceSongId = songId;
    _playDbg('source=$label load ready song=$songId generation=$generation');
    return true;
  }

  void _invalidateSeekRequests() {
    _seekRequestGeneration += 1;
    _activeSeekGeneration = null;
    _activeSeekSongId = null;
  }

  bool _isSeekRequestCurrent({
    required int seekGeneration,
    required int playbackSession,
    required String songId,
  }) {
    return _seekRequestGeneration == seekGeneration &&
        _isPlaybackContextCurrent(session: playbackSession, songId: songId);
  }

  void _releaseSeekAnchor(int seekGeneration) {
    if (_activeSeekGeneration != seekGeneration) return;
    _activeSeekGeneration = null;
    _activeSeekSongId = null;
  }

  void _schedulePendingSeekIfReady() {
    if (!mounted || _isApplyingPendingSeek) return;
    final player = _audioPlayer;
    final currentSongId = state.currentSong?.id;
    if (player == null || currentSongId == null) return;
    if (!shouldPreservePendingSeekPosition(
      pendingPosition: _pendingSeekPosition,
      pendingSongId: _pendingSeekSongId,
      currentSongId: currentSongId,
    )) {
      return;
    }
    if (!canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    )) {
      return;
    }
    unawaited(_applyPendingSeekIfNeeded());
  }

  bool _shouldPreserveSeekPosition() {
    final currentSongId = state.currentSong?.id;
    return shouldPreservePendingSeekPosition(
          pendingPosition: _pendingSeekPosition,
          pendingSongId: _pendingSeekSongId,
          currentSongId: currentSongId,
        ) ||
        (_activeSeekGeneration == _seekRequestGeneration &&
            _activeSeekSongId != null &&
            _activeSeekSongId == currentSongId);
  }

}
