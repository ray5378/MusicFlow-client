part of 'player_provider.dart';

mixin PlayerShuffleQueueInternals on PlayerNotifier {
  void _syncShuffleHistoryBeforeSongChange({
    required Song nextSong,
    required List<Song> nextQueue,
    required int nextIndex,
    required bool recordHistory,
    required bool clearForwardHistory,
  }) {
    if (!state.shuffleEnabled) {
      _resetShuffleHistory(updateState: false);
      _syncShuffleHistoryState();
      return;
    }

    if (!_isSameQueueBySongId(state.queue, nextQueue)) {
      _resetShuffleHistory(updateState: false);
      _syncShuffleHistoryState();
      return;
    }

    // 随机模式:记录本轮已播放的歌曲(同一轮内不重复,播完一轮才重新洗牌)。
    if (nextSong.id.isNotEmpty) {
      _shuffleQueueIndexer.markPlayed(nextSong.id);
    }

    if (recordHistory) {
      final currentEntry = _currentShuffleEntry(
        queue: state.queue,
        song: state.currentSong,
        index: state.currentIndex,
      );
      if (currentEntry != null) {
        final isDifferentTrack =
            currentEntry.songId != nextSong.id ||
            currentEntry.preferredIndex != nextIndex;
        if (isDifferentTrack) {
          _shuffleHistory.pushBack(currentEntry);
        }
      }
    }

    if (clearForwardHistory) {
      _shuffleHistory.clearForward();
    }

    _syncShuffleHistoryState();
  }

  ShuffleHistoryEntry? _currentShuffleEntry({
    required List<Song> queue,
    required Song? song,
    required int index,
  }) {
    if (song == null || queue.isEmpty) return null;

    if (index >= 0 && index < queue.length && queue[index].id == song.id) {
      return ShuffleHistoryEntry(songId: song.id, preferredIndex: index);
    }

    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id == song.id) {
        return ShuffleHistoryEntry(songId: song.id, preferredIndex: i);
      }
    }
    return null;
  }

  bool _isSameQueueBySongId(List<Song> currentQueue, List<Song> nextQueue) {
    if (identical(currentQueue, nextQueue)) return true;
    if (currentQueue.length != nextQueue.length) return false;

    for (var i = 0; i < currentQueue.length; i++) {
      if (currentQueue[i].id != nextQueue[i].id) {
        return false;
      }
    }
    return true;
  }

  int? _takeLastValidBackHistoryIndex() {
    return _shuffleHistory.takeLastValidBack(state.queue);
  }

  int? _takeLastValidForwardHistoryIndex() {
    return _shuffleHistory.takeLastValidForward(state.queue);
  }

  void _resetShuffleHistory({bool updateState = true}) {
    _shuffleHistory.reset();
    _shuffleQueueIndexer.resetRound();
    if (updateState) {
      _syncShuffleHistoryState();
    }
  }

  void _syncShuffleHistoryState() {
    if (!mounted) return;
    final historyCount = _shuffleHistory.backCount;
    if (state.shuffleHistoryCount == historyCount) return;
    state = state.copyWith(shuffleHistoryCount: historyCount);
  }

  int? _getQueuePreviousIndex() {
    final queue = state.queue;
    if (queue.isEmpty) return null;
    if (queue.length == 1) return 0;

    final currentIndex = state.currentIndex;
    if (currentIndex <= 0) return queue.length - 1;
    if (currentIndex >= queue.length) return queue.length - 1;
    return currentIndex - 1;
  }

  int? _getRandomIndexExcludingCurrent({bool allowRoundReset = true}) {
    final queue = state.queue;
    if (queue.isEmpty) return null;
    return _shuffleQueueIndexer.randomIndexExcludingCurrent(
      [for (final s in queue) s.id],
      state.currentIndex,
      state.currentSong?.id,
      allowRoundReset: allowRoundReset,
    );
  }

  int? _resolveForcedNextIndex() {
    final queue = state.queue;
    return ShuffleQueueIndexer.resolveForcedNextIndex(
      forcedSongId: _forcedNextSongId,
      forcedIndex: _forcedNextIndex,
      queueIds: [for (final s in queue) s.id],
      currentIndex: state.currentIndex,
    );
  }

  /// 解析「下一首实际将播放的歌曲」供后台预缓存,并把随机分支抽出的索引
  /// 存入 [_precomputedUpcomingIndex]。真实切歌 [next] 会消费同一索引
  /// (见 _consumePrecomputedUpcomingIndex),确保「预缓存的下一首 == 实际
  /// 将要播放的下一首」。随机分支用**非变更**抽样(allowRoundReset:false),
  /// 不会提前清空本轮播过标记,从而不影响真实切歌的随机语义。
  Song? _resolveUpcomingSongForCache() {
    final queue = state.queue;
    if (queue.isEmpty) return null;
    if (state.shuffleEnabled) {
      final forced = _resolveForcedNextIndex();
      final idx = _shuffleQueueIndexer.resolveRandomUpcomingIndexForCache(
        [for (final s in queue) s.id],
        state.currentIndex,
        state.currentSong?.id,
        forcedIndex: forced,
      );
      if (idx != null && idx < queue.length) {
        Logger.info('SHUFFLE precompute idx=$idx song=${queue[idx].id} title=${queue[idx].title}');
        return queue[idx];
      }
      return null;
    }
    final nextIndex = state.currentIndex + 1;
    if (nextIndex < queue.length) return queue[nextIndex];
    // 顺序模式到队尾:按 [next] 的回绕语义取队首作为待缓存候选。
    if (queue.isNotEmpty) return queue.first;
    return null;
  }

  /// 消费「歌曲就绪时预计算」的下一首索引([_resolveUpcomingSongForCache] 写入),
  /// 让真实切歌与预缓存复用同一个值。队列已变/索引越界/指向当前曲时视为失效,
  /// 返回 null(调用方回退临时抽随机)。
  int? _consumePrecomputedUpcomingIndex() {
    final queue = state.queue;
    if (!state.shuffleEnabled) return null;
    final idx = _shuffleQueueIndexer.consumePrecomputedUpcomingIndex(
      [for (final s in queue) s.id],
      state.currentIndex,
    );
    if (idx == null) return null;
    if (queue[idx].isPreview) return null;
    return idx;
  }

  void _clearForcedNext() {
    _forcedNextSongId = null;
    _forcedNextIndex = null;
  }


  // ==================== 服务端权威洗牌序列(2026-09-11 补齐 SPEC) ====================
  //
  // SPEC(player/types.ts,2026-09-10 定):洗牌序列唯一权威在服务端,客户端只做
  // 镜像。此前只有投屏链路实现了,本机链路漏掉 —— 客户端自己随机抽,导致
  // ①服务端预探测扫不到本机 shuffle 窗口;②本机 shuffle 无预跳(没有确定
  // 的"下一首"可跳)。现在补齐:shuffle 推进沿服务端序列走,拿不到序列
  // (离线/未注册)时回退旧本地随机,离线语义不变。

  /// 服务端序列镜像缓存(epoch 变了必须整体重定位)。
  List<int>? _srvShuffleOrder;
  int _srvShuffleEpoch = -1;
  int _srvShufflePos = -1;
  bool _srvShuffleFetching = false;

  /// 拉取(或显式重洗)服务端洗牌序列。返回是否成功。
  Future<bool> _refreshServerShuffleSeq({bool reshuffle = false}) async {
    if (_srvShuffleFetching) return _srvShuffleOrder != null;
    final pid = _ref.read(castPeerControllerProvider.notifier).localPeerId;
    if (pid == null || pid.isEmpty) return false;
    _srvShuffleFetching = true;
    try {
      final enc = Uri.encodeComponent(pid);
      // 短超时:这条请求在切歌路径上,失败即回退本地随机,不能拖慢兜底循环。
      const t = Duration(seconds: 5);
      final resp = reshuffle
          ? await _apiClient.postRaw('/rest/api/v1/peers/$enc/queue/reshuffle',
              receiveTimeout: t)
          : await _apiClient.getRaw('/rest/api/v1/peers/$enc/queue/shuffle',
              receiveTimeout: t);
      if (resp is! Map) return false;
      final order = (resp['shuffleOrder'] as List?)?.whereType<num>().map((e) => e.toInt()).toList();
      if (order == null) return false;
      _srvShuffleOrder = order;
      final newEpoch = (resp['shuffleEpoch'] as num?)?.toInt() ?? -1;
      if (newEpoch != _srvShuffleEpoch) {
        // 序列换版(重洗/整队替换/服务端重启)→ 旧位置作废,由调用方重定位。
        Logger.debugWithTag('PLAYER',
            'srv-shuffle epoch $_srvShuffleEpoch -> $newEpoch (reshuffle=$reshuffle)');
        _srvShuffleEpoch = newEpoch;
        _srvShufflePos = -1;
      }
      if (!reshuffle) {
        _srvShufflePos = (resp['shufflePos'] as num?)?.toInt() ?? _srvShufflePos;
      }
      return true;
    } catch (_) {
      // 离线/无服务:清缓存,回退本地随机。
      _srvShuffleOrder = null;
      _srvShufflePos = -1;
      return false;
    } finally {
      _srvShuffleFetching = false;
    }
  }

  /// 沿服务端洗牌序列推进,越过「明确的、未过期的不可播」的歌(与顺序模式
  /// 的 _skipKnownUnplayable 同一四态语义:只跳 unplayable,transient/unknown
  /// 照播)。返回应播放的队列下标;拿不到序列返回 null(调用方回退本地随机)。
  ///
  /// 序列尾自动重洗(用户确认语义):reshuffle 后取新序列第 0 位。
  /// 已知死链跳过不消耗回绕 —— 序列走到尾即触发重洗,由新序列接力。
  Future<int?> _pickServerShuffleNext() async {
    if (!state.shuffleEnabled || state.queue.isEmpty) return null;
    var ok = await _refreshServerShuffleSeq();
    if (!ok) return null;
    var order = _srvShuffleOrder!;
    var pos = _srvShufflePos;
    // 序列版本对不上/缓存位置与当前曲不符 → 重新定位(跳歌/换队列/重启后)。
    if (pos < 0 || pos >= order.length || order[pos] != state.currentIndex) {
      pos = order.indexOf(state.currentIndex);
    }
    if (pos < 0) return null;

    var nextPos = pos + 1;
    if (nextPos >= order.length) {
      // 序列尾 → 自动重洗,新序列从头接续。
      ok = await _refreshServerShuffleSeq(reshuffle: true);
      if (!ok || _srvShuffleOrder == null || _srvShuffleOrder!.isEmpty) return null;
      order = _srvShuffleOrder!;
      nextPos = 0;
    }
    // 沿序列跳过已知死链(不回绕;越过的位置照常消耗,一轮语义不变)。
    var p = nextPos;
    var skipped = 0;
    while (p < order.length && _isKnownUnplayable(state.queue[order[p]].id)) {
      p++;
      skipped++;
    }
    if (p >= order.length) {
      // 剩余全死 → 重洗一次,从新序列头找第一首非死链。
      ok = await _refreshServerShuffleSeq(reshuffle: true);
      if (!ok || _srvShuffleOrder == null) return null;
      order = _srvShuffleOrder!;
      p = 0;
      while (p < order.length && _isKnownUnplayable(state.queue[order[p]].id)) {
        p++;
      }
      if (p >= order.length) return null;
    }
    _srvShufflePos = p;
    if (skipped > 0) {
      Logger.infoWithTag('PLAYER', 'srv-shuffle skip ahead: skipped $skipped known-unplayable song(s)');
    }
    final idx = order[p];
    if (idx < 0 || idx >= state.queue.length) return null;
    return idx;
  }
}
