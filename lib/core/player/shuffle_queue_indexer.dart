import 'dart:math';

/// 随机/队列「下一首」索引的统一决策器（纯 Dart，无 Flutter / audio 依赖，可单测）。
///
/// 职责收拢三类会各自独立抽随机的索引逻辑，保证它们复用同一出口：
/// 1. 真实切歌 `next()` 的随机采样；
/// 2. 歌曲就绪时的预缓存候选（`precomputedUpcomingIndex`）；
/// 3. 看房史/顺序回绕。
///
/// 语义（对齐主项目洗牌序列）：
/// - 随机模式「一轮内不重复」：`_playedSongIds` 记录本轮已播，优先从未播者中抽；
///   本轮播完（全部播过）才清空重洗，并且重洗后避开当前曲（不立刻重播当前曲）。
/// - 预缓存取样必须是**非变更**语义（`allowRoundReset: false`）：即使本轮播完，
///   也不提前清空本轮标记，避免预缓存影响真实切歌的随机轮次；但返回的候选仍与
///   真实 next 对齐（都避开当前曲），使「预缓存的下一首 == 实际播的下一首」。
class ShuffleQueueIndexer {
  final Random _random;

  /// 本轮已播放的歌曲 id（随机「一轮内不重复」）。
  final Set<String> _playedSongIds = <String>{};

  /// 歌曲就绪时提前确定的「真实下一首」索引：预缓存与真实切歌(next)复用同一值，
  /// 避免两者各自独立抽随机导致「缓存的下一首 ≠ 实际播的下一首」。
  int? precomputedUpcomingIndex;

  ShuffleQueueIndexer({Random? random}) : _random = random ?? Random();

  /// 本轮是否已播过该歌曲 id。
  bool hasPlayed(String songId) => _playedSongIds.contains(songId);

  /// 随机抽取「下一首候选」索引，排除当前曲；优先本轮未播者。
  ///
  /// [queueIds] 为歌曲 id 列表（顺序与 [currentIndex] 对应）。
  /// [currentSongId] 为当前曲 id（用于「不立刻重播当前曲」）。
  /// [allowRoundReset] 为 true 时，若本轮已播完则清空本轮标记重洗；为 false 时
  /// （预缓存取样）即使播完也**不清空**本轮标记（非变更语义），但返回的候选
  /// 与真实 next 对齐（都避开当前曲）。
  int? randomIndexExcludingCurrent(
    List<String> queueIds,
    int currentIndex,
    String? currentSongId, {
    bool allowRoundReset = true,
  }) {
    if (queueIds.isEmpty) return null;
    if (queueIds.length == 1) return 0;

    final nonDuplicateCandidates = <int>[];
    final fallbackCandidates = <int>[];
    final unplayedCandidates = <int>[];

    for (var i = 0; i < queueIds.length; i++) {
      if (i == currentIndex) continue;
      fallbackCandidates.add(i);
      if (!_playedSongIds.contains(queueIds[i])) {
        unplayedCandidates.add(i);
      }
      if (currentSongId == null || queueIds[i] != currentSongId) {
        nonDuplicateCandidates.add(i);
      }
    }

    var candidates = unplayedCandidates;
    if (candidates.isEmpty && nonDuplicateCandidates.isNotEmpty) {
      // 本轮已播完：true 时清空本轮标记重新洗牌（避开当前曲）；false（预缓存）时
      // 仅返回候选、保留本轮标记，让真实切歌自行决定是否重洗。
      if (allowRoundReset) {
        _playedSongIds.clear();
      }
      candidates = nonDuplicateCandidates;
    }
    if (candidates.isEmpty) {
      candidates = fallbackCandidates;
    }
    if (candidates.isEmpty) return null;

    return candidates[_random.nextInt(candidates.length)];
  }

  /// 预缓存候选索引：随机模式优先取 [forcedIndex]；否则做**非变更**随机取样
  /// （不清空本轮标记），结果写入 [precomputedUpcomingIndex] 供真实 next 消费。
  ///
  /// 返回值已写入 [precomputedUpcomingIndex]（供外层读取歌曲并 Log）。不在范围内
  /// 或取不到时返回 null 并置空 [precomputedUpcomingIndex]。
  int? resolveRandomUpcomingIndexForCache(
    List<String> queueIds,
    int currentIndex,
    String? currentSongId, {
    int? forcedIndex,
  }) {
    if (forcedIndex != null && forcedIndex >= 0 && forcedIndex < queueIds.length) {
      precomputedUpcomingIndex = forcedIndex;
      return forcedIndex;
    }
    final idx = randomIndexExcludingCurrent(
      queueIds,
      currentIndex,
      currentSongId,
      allowRoundReset: false,
    );
    precomputedUpcomingIndex = idx;
    return idx;
  }

  /// 消费「歌曲就绪时预计算」的下一首索引（[resolveRandomUpcomingIndexForCache] 写入）。
  /// 消费后清空。校验：随机已关闭 / 越界 / 指向当前曲 均视为失效，返回 null
  /// （调用方回退临时抽随机）。
  /// 注：preview 校验由外层（播放器）依据具体歌曲对象做，本方法只做索引级校验。
  int? consumePrecomputedUpcomingIndex(
    List<String> queueIds,
    int currentIndex,
  ) {
    final idx = precomputedUpcomingIndex;
    precomputedUpcomingIndex = null;
    if (idx == null || idx < 0 || idx >= queueIds.length) return null;
    if (idx == currentIndex) return null;
    return idx;
  }

  /// 记录本轮已播（仅 id 非空）。
  void markPlayed(String songId) {
    if (songId.isNotEmpty) {
      _playedSongIds.add(songId);
    }
  }

  /// 清空本轮播放标记。
  void resetRound() {
    _playedSongIds.clear();
  }

  /// 纯函数：顺序模式「下一首」索引（队尾回绕队首）。空队列返回 null。
  static int? sequentialNextIndex(List<String> queueIds, int currentIndex) {
    final queue = queueIds;
    if (queue.isEmpty) return null;
    final nextIndex = currentIndex + 1;
    if (nextIndex < queue.length) return nextIndex;
    return 0;
  }

  /// 纯函数：解析「强制下一首」索引（跳转到指定曲）。
  /// [forcedSongId]/[forcedIndex] 为强播目标；二者为 null 时返回 null。
  /// 命中条件：目标在队列内、非当前曲、id 匹配。
  static int? resolveForcedNextIndex({
    required String? forcedSongId,
    required int? forcedIndex,
    required List<String> queueIds,
    required int currentIndex,
  }) {
    if (forcedSongId == null) return null;

    bool isMatch(int index) {
      return index >= 0 &&
          index < queueIds.length &&
          index != currentIndex &&
          queueIds[index] == forcedSongId;
    }

    final preferredIndex = forcedIndex;
    if (preferredIndex != null && isMatch(preferredIndex)) {
      return preferredIndex;
    }

    for (var i = currentIndex + 1; i < queueIds.length; i++) {
      if (isMatch(i)) return i;
    }

    for (var i = 0; i < queueIds.length; i++) {
      if (isMatch(i)) return i;
    }
    return null;
  }
}