part of 'player_provider.dart';

const Duration _playbackSessionPersistInterval = Duration(seconds: 5);

/// 租约时长：一次落盘占用「正在写」标记的最长时间。超过即视为上次落盘已死
/// （await 永久挂起），强制放行下一次写入。
///
/// 为什么**不用** `Future.timeout()` 兜底：`.timeout()` 会创建一颗 Timer，而
/// flutter_test 的 fakeAsync 环境下它是 FakeTimer —— 写入走真实 IO、不会在
/// fakeAsync 时钟内完成，那颗 Timer 就永远 pending，撞上框架的不变量断言
/// 「A Timer is still pending even after the widget tree was disposed」。
/// 租约是纯时间戳比较，不创建任何 Timer，测试与生产行为一致。
const Duration _persistLease = Duration(seconds: 15);

mixin PlayerPlaybackSessionInternals on PlayerNotifier {
  /// 落盘是否正在进行中（租约制，见 _persistingSinceMs）。
  bool get _isPersistingPlaybackSession {
    final since = _persistingSinceMs;
    if (since == null) return false;
    final stuckMs = DateTime.now().millisecondsSinceEpoch - since;
    if (stuckMs <= _persistLease.inMilliseconds) return true;
    // 租约过期：上次落盘的 await 永久挂起，finally 没机会复位标记。强制
    // 放行并留证，否则会话落盘永久停摆（每次重启都恢复成同一首旧歌）。
    Logger.warnWithTag(
      _playerLogTag,
      'playback session persist lease expired, forcing next write '
      '(stuckForMs=$stuckMs)',
    );
    _persistingSinceMs = null;
    return false;
  }

  void _beginPersistLease() =>
      _persistingSinceMs = DateTime.now().millisecondsSinceEpoch;

  void _endPersistLease() => _persistingSinceMs = null;
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
    // 来源一并落盘：重启后队列由此会话恢复，若来源丢失则「本机→设备」接续
    // 搬移拿不到 serverContentType，只能整队推送（大歌单上行 MB 级、耗时
    // 随规模线性劣化）。
    final origin = _ref.read(queueOriginProvider);
    return _payloadEncoder.buildSession(
      queue: state.queue,
      currentIndex: state.currentIndex,
      currentSongId: state.currentSong?.id,
      position: state.position,
      duration: state.duration,
      isPlaying: state.isPlaying,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      queueOrigin: origin?.toJson(),
    );
  }

  Future<void> _persistPlaybackSession() async {
    // 关闭(dispose)时 mounted 已为 false,但不能因此跳过落盘 —— 否则退出瞬间
    // 刚更新的进度/歌曲就会丢,重开无法续播。只在「恢复会话进行中」与「正在写」
    // 时跳过,其余情况(含关闭)都照常保存。
    if (_isRestoringPlaybackSession) return;
    if (_isPersistingPlaybackSession) {
      Logger.debugWithTag(
        _playerLogTag,
        'skip persist: previous write still in flight',
      );
      return;
    }

    _beginPersistLease();
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
      // 挂起风险:Windows 上 tmp.rename 覆盖已存在文件时若被杀软/索引服务
      // 占用会阻塞等待而非抛错,await 永不返回 → finally 不执行。此时靠
      // _persistingSinceMs 租约兜底(见 _persistLease),不再用 .timeout()。
      await LocalStorage.savePlaybackSession(payload);
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to persist playback session',
        e,
      );
    } finally {
      _endPersistLease();
    }

    // 音量单独成块:即使会话写入失败/超时也要保住音量,避免「直接退出客户端
    // 后音量回到 100%」。原实现与会话同一个 try,会话一失败音量就跟着不落盘。
    try {
      await LocalStorage.setPlayerVolume(state.volume);
    } catch (e) {
      Logger.warnWithTag(_playerLogTag, 'failed to persist player volume', e);
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

      // 恢复队列来源（与队列同一份会话，必须成对恢复）。
      // 本方法直接调 playSong 而非 playEffectiveQueue，不经过来源写入点，
      // 所以必须在这里显式回填；否则「本机→设备」接续搬移会误判来源不可解析。
      // 字段缺失（旧版会话）→ null，按「其它来源」降级为整队推送，不误走主通道。
      // 键名与读取走 playback_payload 的共享常量/函数，两侧不会各写各的。
      _ref.read(queueOriginProvider.notifier).state =
          QueueOrigin.fromJson(readSessionQueueOrigin(session));

      Logger.infoWithTag(_playerLogTag, 'playback session restored');
      restored = true;

      // 恢复后立即把队列镜像给服务端:恢复路径不走常规播放入口,服务端可能
      // 还留着上次进程的旧队列。失败不影响本地续播(下个变化点会再试)。
      try {
        await _ref
            .read(castPeerControllerProvider.notifier)
            .syncLocalQueueNow();
      } catch (e) {
        Logger.debugWithTag(
          _playerLogTag,
          'post-restore queue mirror skipped: $e',
        );
      }
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
