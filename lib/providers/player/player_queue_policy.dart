// ADR-2「阶段 1：策略/协作者外提」——队列（queue）协作者。
//
// 恢复会话时的「落点索引解析」与「队列同一性判定」都是纯函数（只读 `Song.id`），
// 原先内联在 `player_playback_session.dart` / `player_shuffle_queue.dart` 的 mixin
// 里，属于「库私有」成员、单测无法直达。外提为独立纯函数后可直接零成本覆盖，
// 宿主 mixin 仅透传队列与游标。
import 'package:musicflow_client/data/models/song.dart';

/// 解析「恢复播放会话」时应落到的队列索引（纯函数）。
///
/// 规则（与宿主内联实现逐字等价）：
///   1. 空队列 → 0；
///   2. [currentSongId] 非空时：优先 [preferredIndex]（合法且该位 id 命中）；
///      否则在队列中按 id 首次匹配；
///   3. 未命中/无 id：[preferredIndex] 越下界 → 0，越上界 → `length - 1`，
///      否则原样返回。
int resolveRestoredQueueIndex({
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

/// 两个队列是否「按歌曲 id 逐位相同」（纯函数）。
///
/// 用于避免队列内容未变时的多余重建；`identical` 快捷路径保留。
bool isSameQueueBySongId(List<Song> currentQueue, List<Song> nextQueue) {
  if (identical(currentQueue, nextQueue)) return true;
  if (currentQueue.length != nextQueue.length) return false;

  for (var i = 0; i < currentQueue.length; i++) {
    if (currentQueue[i].id != nextQueue[i].id) {
      return false;
    }
  }
  return true;
}
