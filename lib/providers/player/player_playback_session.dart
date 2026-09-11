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
    var fromServer = false;
    _restoreStartedAtMs = DateTime.now().millisecondsSinceEpoch;

    try {
      final session = await LocalStorage.getPlaybackSession();
      final localQueue = session == null
          ? const <Song>[]
          : _parsePlaybackSessionQueue(session['queue']);
      if (session != null && localQueue.isEmpty) {
        await LocalStorage.clearPlaybackSession();
      }
      final localUpdatedAt =
          session == null ? 0 : (_parseStoredInt(session['updatedAt']) ?? 0);

      // ── 新鲜度竞速:服务端快照比本地文件新则采用服务端队列 ──
      // 本地文件可能因历史 bug(恢复卡死压制落盘 / 写卡死)整体陈旧;若
      // 无条件信任本地,会把旧队列恢复上屏,还会经 syncLocalQueueNow 把
      // 服务端较新的队列覆盖掉(实测:本地 412 首旧会话反杀服务端 3215
      // 首歌单队列)。比较基准是 updatedAt:后端未带该字段(旧版本)按 0
      // 处理 → 本地优先,行为与旧版一致。拉取失败/测试环境返回 null。
      Map<String, dynamic>? snap;
      try {
        snap = await _ref
            .read(castPeerControllerProvider.notifier)
            .fetchLocalQueueForRestore();
      } catch (e) {
        Logger.debugWithTag(
          _playerLogTag,
          'restore: server queue snapshot unavailable: $e',
        );
      }
      final serverQueue = snap == null
          ? const <Song>[]
          : [
              for (final it in (snap['items'] as List))
                if (it is Map) queueItemToSong(it.map((k, v) => MapEntry(k.toString(), v))),
            ];
      final serverUpdatedAt =
          snap == null ? 0 : ((snap['updatedAt'] as num?)?.toInt() ?? 0);
      final useServer = serverQueue.isNotEmpty && serverUpdatedAt > localUpdatedAt;

      if (session == null && !useServer) return;

      List<Song> queue;
      int restoredIndex;
      var restoredPosition = Duration.zero;
      if (useServer) {
        fromServer = true;
        queue = serverQueue;
        final idx = (snap!['currentIndex'] as num?)?.toInt() ?? 0;
        restoredIndex = (idx < 0 || idx >= queue.length) ? 0 : idx;
        // 恢复服务端播放模式(客户端本地洗牌序自建,服务端序列只喂预探测)。
        final modeStr = snap['playMode'] as String?;
        final mode = switch (modeStr) {
          'shuffle' => PlaybackMode.shuffle,
          'one' => PlaybackMode.one,
          'all' => PlaybackMode.all,
          _ => PlaybackMode.order,
        };
        unawaited(setPlaybackMode(mode, persist: false));
        Logger.infoWithTag(
          _playerLogTag,
          'restoring FROM SERVER queue=${queue.length} '
          'index=$restoredIndex serverUpdatedAt=$serverUpdatedAt '
          'localUpdatedAt=$localUpdatedAt mode=$modeStr',
        );
      } else {
        queue = localQueue;
        final preferredIndex = _parseStoredInt(session!['currentIndex']) ?? 0;
        final currentSongId = session['currentSongId']?.toString();
        restoredIndex = _resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: preferredIndex,
          currentSongId: currentSongId,
        );
        final storedPositionMs = _parseStoredInt(session['positionMs']) ?? 0;
        restoredPosition = Duration(milliseconds: max(0, storedPositionMs));
        Logger.infoWithTag(
          _playerLogTag,
          'restoring playback session queue=${queue.length} '
          'index=$restoredIndex posMs=${restoredPosition.inMilliseconds} '
          'wasPlaying=${session['isPlaying'] == true}',
        );
      }
      final song = queue[restoredIndex];

      // ── 恢复不再 await 音源加载 ──
      // playSong 会对当前曲 setUrl;死链/慢源下该 await 可能永久不返回,
      // 把整个恢复流程卡死 → 恢复标志(旧布尔量/现租约)长期为 true →
      // 之后所有会话落盘被跳过 → 本地文件整体陈旧 → 每次重启都恢复成
      // 同一首旧歌(v4.3.49 真机实测)。这里 fire-and-forget:恢复只负责
      // 恢复状态,加载与重试交给播放器既有看门狗;进度经 initialPosition
      // 走 pendingSeek 管线,源就绪后自动 seek 落位。
      final autoResume = await LocalStorage.getAutoPlayOnLaunch();
      unawaited(
        playSong(
          song,
          queue: queue,
          index: restoredIndex,
          autoPlay: autoResume,
          initialPosition: fromServer ? null : restoredPosition,
        ).catchError((Object e) {
          Logger.warnWithTag(_playerLogTag, 'post-restore load failed', e);
        }),
      );

      // 恢复队列来源(与队列同源,必须成对):服务端快照无来源 → null,
      // 按「其它来源」降级为整队推送,不误走主通道。
      _ref.read(queueOriginProvider.notifier).state = fromServer
          ? null
          : QueueOrigin.fromJson(readSessionQueueOrigin(session!));

      Logger.infoWithTag(
        _playerLogTag,
        'playback session restored (fromServer=$fromServer)',
      );
      restored = true;

      // 本地为准:把队列镜像给服务端(告诉服务端这是本次要恢复的队列)。
      // 服务端为准:内容一致,无需回推,避免 MB 级冗余上行。
      if (!fromServer) {
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
      }
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to restore playback session',
        e,
      );
    } finally {
      _restoreStartedAtMs = null;
    }

    if (restored) {
      // 两种来源都立即回写本地文件:服务端胜出时,这次回写把服务端内容
      // 落成新的本地会话,下次启动两侧一致。
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
