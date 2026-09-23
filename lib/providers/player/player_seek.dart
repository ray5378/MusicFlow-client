part of 'player_provider.dart';

/// 「连续失败自动跳」连跳段的网络加载节流时长。
///
/// 只把真正发起音频加载（setUrl/setAudioSource 的 GET）这一步延后，绝不冻结
/// next() / state / currentSong 的推进，避免 v5.0.9「Future.delayed 冻结跳转
/// 导致流转上报读不到歌」的回归。
const _kLoadThrottleOnFailStreak = Duration(milliseconds: 300);

mixin PlayerSeekInternals on PlayerNotifier {
  /// 权威时长：元数据已知时以元数据为准，避免实时流渐进上报把 seek 目标截断。
  Duration _authoritativeDuration() => authoritativeDuration(
        streamDuration: state.duration,
        metadataDuration: Duration(
          seconds: state.currentSong?.duration ?? 0,
        ),
      );

  Duration _normalizeSeekPosition(Duration position) => normalizeSeekPosition(
        position,
        _authoritativeDuration(),
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

  /// 播放器**当前真实加载**的音源地址(http/https 才算,离线缓存的 file:// 不算)。
  ///
  /// 这是 seek 路由的事实依据:它不经过任何簿记字段,起流路径无论从哪来
  /// (direct_stream / 转码重试 / preview / 会话恢复)都能反映出来。原先只看
  /// `_seekByReloadStream` 那个可被清空/写错的字段,一旦它错了,seek 就静默退化成
  /// 「重复一遍无效的源内 seek」,而 just_audio 还会立刻把 position 报成目标值,
  /// 让漂移兜底也失效 —— 现场就是「拖了从头播」。
  String? _loadedSourceUrl(AudioPlayer player) {
    final source = player.audioSource;
    if (source is! UriAudioSource) return null;
    final uri = source.uri;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }

  Future<void> _seekWithFallback(
    Duration target, {
    required String songId,
    required bool Function() isCurrentSeek,
    required bool Function() ownsSource,
  }) async {
    final player = _audioPlayer;
    if (player == null || !isCurrentSeek()) return;

    final loadedSourceUrl = _loadedSourceUrl(player);
    final pipelined = _serverPipelinedHttp();
    final plan = resolveSeekReloadPlan(
      songId: songId,
      target: target,
      contextSongId: _currentStreamSongId,
      contextUrl: _currentStreamUrl,
      contextAllowsReload: _seekByReloadStream,
      loadedSourceUrl: loadedSourceUrl,
      serverPipelinedHttp: pipelined,
    );
    _seekDbg(
      'seek route reload=${plan != null} origin=${plan?.origin ?? "-"} '
      'pipe=$pipelined flag=$_seekByReloadStream '
      '${_serverCapabilitySummary()} '
      'ctxSong=${_currentStreamSongId ?? "-"} '
      'ctx=${_summarizeStreamUrl(_currentStreamUrl)} '
      'loaded=${_summarizeStreamUrl(loadedSourceUrl)}',
    );

    if (plan != null) {
      final shouldResume = player.playing;
      final seekTarget = TranscodedStreamSeekTarget.fromLogical(target);
      if (plan.origin == 'context' &&
          seekTarget.serverOffset == _sourcePositionOffset) {
        // 同段微调(目标与当前流同一逻辑段,常发生在拖动连续触发时):源内 seek
        // 足够,不必每次重拉(省 setUrl + 服务端转码首包等待);源拒收(实时管道
        // 流不可字节 seek)则升级全量重拉。
        try {
          await player.seek(seekTarget.sourcePosition);
          return;
        } catch (_) {
          if (!isCurrentSeek()) return;
          _seekDbg('same-segment seek rejected, upgrading to reload');
        }
      }
      await _reloadStreamForSeek(
        player: player,
        songId: songId,
        target: target,
        seekTarget: seekTarget,
        reloadUrl: plan.url,
        origin: plan.origin,
        streamFormat: plan.format,
        streamMaxBitRate: plan.maxBitRate,
        shouldResume: shouldResume,
        isCurrentSeek: isCurrentSeek,
        ownsSource: ownsSource,
      );
      return;
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

    // 走到这里只剩「本服务端流之外」的源(离线缓存文件 / 外部直链 / 明确判定的
    // 非管道化老服务端):position 漂移在这类源上同样会撒谎(见上),所以这里只做
    // 一次温和的原地重试 —— 规避解码器刚起播时的 seek 抖动,不再假装能靠漂移
    // 判断"重拉与否"。服务端流的拖动一律在上面的 plan 分支里重拉。
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

  /// 全量重拉(C5 分发目标):用 [reloadUrl](通常已带 timeOffset)重建流并 setUrl,
  /// offset 同步更新。调用方保证:判定为服务端流才进这里;全部路径 return,无 fallthrough。
  Future<void> _reloadStreamForSeek({
    required AudioPlayer player,
    required String songId,
    required Duration target,
    required TranscodedStreamSeekTarget seekTarget,
    required String reloadUrl,
    required String origin,
    required String? streamFormat,
    required int? streamMaxBitRate,
    required bool shouldResume,
    required bool Function() isCurrentSeek,
    required bool Function() ownsSource,
  }) async {
    _seekDbg(
      'seek reload-stream song=$songId origin=$origin '
      'target=$target serverOffset=${seekTarget.serverOffset} '
      'sourcePosition=${seekTarget.sourcePosition} format=$streamFormat '
      'maxBitRate=$streamMaxBitRate wasPlaying=$shouldResume '
      'url=${_summarizeStreamUrl(reloadUrl)}',
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
    final maximum = _authoritativeDuration();
    return addPlaybackPositionOffset(
      sourcePosition,
      _sourcePositionOffset,
      maximum: maximum > Duration.zero ? maximum : null,
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
      // 意图作废：这次加载没播出来，且之后没有更新的加载启动 —— 期望自动播放
      // 的意图已死，必须清除。否则 0 秒卡死看门狗 6s 后会复活一个从未起播过的
      // 会话（实测：镜像跟随播→加载废弃→看门狗 reload→手机莫名从头出声）。
      // 有更新加载在途时（_sourceGeneration 已超前）不动：新加载自带意图。
      if (_sourceGeneration == generation) {
        _expectingAutoplay = false;
        _seekDbg('autoplay intent voided: latest load abandoned without playback');
      }
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
