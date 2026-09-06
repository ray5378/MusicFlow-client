import '../../../data/models/song.dart';
import 'package:musicflow_client/providers/player/player_state.dart';

/// 随机模式「上一步/下一步」的历史导航栈（纯 Dart，可单测）。
///
/// 收拢原先散落在播放器里的 back/forward 两个栈及其 push/去重/解析/回退逻辑：
/// - **_back**：用户「下一首」时把当前曲压入，供 `previous` 回到上一步；
/// - **_forward**：用户「上一首」回到历史时把当前曲压入，供 `next` 重做。
/// 栈内条目解析到当前队列的索引，队列已变导致条目失配的会被跳过（失效即丢弃）。
class ShuffleHistory {
  final List<ShuffleHistoryEntry> _back = <ShuffleHistoryEntry>[];
  final List<ShuffleHistoryEntry> _forward = <ShuffleHistoryEntry>[];

  int get backCount => _back.length;

  void pushBack(ShuffleHistoryEntry entry) => _push(_back, entry);
  void pushForward(ShuffleHistoryEntry entry) => _push(_forward, entry);

  void clearForward() {
    _forward.clear();
  }

  void reset() {
    _back.clear();
    _forward.clear();
  }

  int? takeLastValidBack(List<Song> queue) => _takeLastValid(_back, queue);
  int? takeLastValidForward(List<Song> queue) =>
      _takeLastValid(_forward, queue);

  void _push(List<ShuffleHistoryEntry> stack, ShuffleHistoryEntry entry) {
    if (stack.isNotEmpty) {
      final last = stack.last;
      if (last.songId == entry.songId &&
          last.preferredIndex == entry.preferredIndex) {
        return;
      }
    }
    stack.add(entry);
    if (stack.length > maxShuffleHistoryEntries) {
      stack.removeAt(0);
    }
  }

  int? _takeLastValid(List<ShuffleHistoryEntry> stack, List<Song> queue) {
    while (stack.isNotEmpty) {
      final entry = stack.removeLast();
      final resolvedIndex = _resolveIndex(queue, entry);
      if (resolvedIndex != null) {
        return resolvedIndex;
      }
    }
    return null;
  }

  int? _resolveIndex(List<Song> queue, ShuffleHistoryEntry entry) {
    final preferredIndex = entry.preferredIndex;
    if (preferredIndex >= 0 &&
        preferredIndex < queue.length &&
        queue[preferredIndex].id == entry.songId) {
      return preferredIndex;
    }

    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id == entry.songId) {
        return i;
      }
    }
    return null;
  }
}