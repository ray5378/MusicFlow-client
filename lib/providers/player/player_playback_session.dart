part of 'player_provider.dart';

const Duration _playbackSessionPersistInterval = Duration(seconds: 5);

mixin PlayerPlaybackSessionInternals on PlayerNotifier {
  void _schedulePersistPlaybackSession({bool immediate = false}) {
    if (!mounted || _isRestoringPlaybackSession) return;

    if (immediate) {
      _playbackSessionPersistTimer?.cancel();
      _playbackSessionPersistTimer = null;
      unawaited(_persistPlaybackSession());
      return;
    }

    if (_playbackSessionPersistTimer != null) return;
    _playbackSessionPersistTimer = Timer(_playbackSessionPersistInterval, () {
      _playbackSessionPersistTimer = null;
      unawaited(_persistPlaybackSession());
    });
  }

  /// 序列化队列，队列未变化时复用上次结果（避免每次落盘都全量 toJson 整队，
  /// 那是大屏旋转封面"定时卡顿"的周期性主线程分配源）。
  Map<String, dynamic>? _buildPlaybackSessionPayload() {
    return _payloadEncoder.buildSession(
      queue: state.queue,
      currentIndex: state.currentIndex,
      currentSongId: state.currentSong?.id,
      position: state.position,
      duration: state.duration,
      isPlaying: state.isPlaying,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _persistPlaybackSession() async {
    // 关闭(dispose)时 mounted 已为 false,但不能因此跳过落盘 —— 否则退出瞬间
    // 刚更新的进度/歌曲就会丢,重开无法续播。只在「恢复会话进行中」与「正在写」
    // 时跳过,其余情况(含关闭)都照常保存。
    if (_isRestoringPlaybackSession || _isPersistingPlaybackSession) {
      return;
    }

    _isPersistingPlaybackSession = true;
    try {
      final payload = _buildPlaybackSessionPayload();
      if (payload == null) {
        await LocalStorage.clearPlaybackSession();
        return;
      }
      Logger.debugWithTag(
        _playerLogTag,
        'persist session currentSongId=${payload['currentSongId']} '
        'index=${payload['currentIndex']} '
        'posMs=${payload['positionMs']} isPlaying=${payload['isPlaying']} '
        'queueLen=${(payload['queue'] as List).length} '
        'updatedAt=${payload['updatedAt']}',
      );
      await LocalStorage.savePlaybackSession(payload);
      // 顺带持久化音量：随会话周期反复落盘，即使滑块松手那次写入丢失，
      // 下次周期也会补上，避免「直接退出客户端后音量回到 100%」。
      await LocalStorage.setPlayerVolume(state.volume);
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to persist playback session',
        e,
      );
    } finally {
      _isPersistingPlaybackSession = false;
    }
  }

  Future<void> _restorePlaybackSession() async {
    if (!mounted) return;
    var restored = false;
    _isRestoringPlaybackSession = true;

    try {
      final session = await LocalStorage.getPlaybackSession();
      if (session == null) return;

      final queue = _parsePlaybackSessionQueue(session['queue']);
      if (queue.isEmpty) {
        await LocalStorage.clearPlaybackSession();
        return;
      }

      final preferredIndex = _parseStoredInt(session['currentIndex']) ?? 0;
      final currentSongId = session['currentSongId']?.toString();
      final restoredIndex = _resolveRestoredQueueIndex(
        queue: queue,
        preferredIndex: preferredIndex,
        currentSongId: currentSongId,
      );
      final storedPositionMs = _parseStoredInt(session['positionMs']) ?? 0;
      final restoredPosition = Duration(milliseconds: max(0, storedPositionMs));
      final wasPlaying = session['isPlaying'] == true;
      Logger.infoWithTag(
        _playerLogTag,
        'restoring playback session queue=${queue.length} '
        'index=$restoredIndex posMs=${restoredPosition.inMilliseconds} '
        'wasPlaying=$wasPlaying',
      );
      // 诊断：打印恢复队列的实际歌曲(用于定位"每次都恢复成固定试听歌")。
      Logger.infoWithTag(
        _playerLogTag,
        'session queue ids=${queue.map((s) => s.id).toList()} '
        'titles=${queue.map((s) => s.title).toList()} '
        'previewFlags=${queue.map((s) => s.isPreview).toList()} '
        'storedCurrentSongId=$currentSongId storedIndex=$preferredIndex '
        'sessionUpdatedAt=${session['updatedAt']}',
      );
      await playSong(
        queue[restoredIndex],
        queue: queue,
        index: restoredIndex,
        autoPlay: false,
      );
      if (restoredPosition > Duration.zero) {
        await seek(restoredPosition);
      }
      // 恢复即续播:是否自动播放**只由设置「打开时自动播放」决定**(默认关闭)。
      // 关闭时只恢复队列与进度、停在暂停态,不因关闭前在播就擅自起播;
      // 开启时才在恢复后自动续播。旧逻辑 `wasPlaying || autoPlayOnLaunch`
      // 会让关闭前在播的应用无论如何都自动续播,违背用户设置意图。
      final autoResume = await LocalStorage.getAutoPlayOnLaunch();
      if (autoResume) {
        await play();
      } else {
        await pause();
      }

      Logger.infoWithTag(_playerLogTag, 'playback session restored');
      restored = true;
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to restore playback session',
        e,
      );
    } finally {
      _isRestoringPlaybackSession = false;
    }

    if (restored) {
      _schedulePersistPlaybackSession(immediate: true);
    }
  }

  List<Song> _parsePlaybackSessionQueue(Object? rawQueue) {
    if (rawQueue is! List) return const [];

    final queue = <Song>[];
    for (final item in rawQueue) {
      try {
        if (item is Map<String, dynamic>) {
          queue.add(Song.fromJson(item));
          continue;
        }
        if (item is Map) {
          final mapped = item.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          queue.add(Song.fromJson(mapped));
        }
      } catch (e) {
        Logger.warnWithTag(
          _playerLogTag,
          'skip invalid song in playback session',
          e,
        );
      }
    }
    return queue;
  }

  int? _parseStoredInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  int _resolveRestoredQueueIndex({
    required List<Song> queue,
    required int preferredIndex,
    required String? currentSongId,
  }) {
    if (queue.isEmpty) return 0;

    if (currentSongId != null && currentSongId.isNotEmpty) {
      if (preferredIndex >= 0 &&
          preferredIndex < queue.length &&
          queue[preferredIndex].id == currentSongId) {
        return preferredIndex;
      }

      final matched = queue.indexWhere((song) => song.id == currentSongId);
      if (matched >= 0) return matched;
    }

    if (preferredIndex < 0) return 0;
    if (preferredIndex >= queue.length) return queue.length - 1;
    return preferredIndex;
  }

}
