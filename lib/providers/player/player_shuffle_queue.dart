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

}
