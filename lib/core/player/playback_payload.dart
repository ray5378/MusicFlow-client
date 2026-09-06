import 'package:musicflow_client/data/models/song.dart';

/// 播放会话队列 payload 归一化/构建 + 位置归一化（纯 Dart，可单测）。
///
/// 序列化缓存关键点：仅当队列歌曲 id 序列变化时才重建 Map 列表，避免在播放
/// 状态高频更新时每 tick 对整条队列全量 toJson/jsonEncode（历史主线程卡顿来源）。
/// 实例可在播放器内长期持有（可复用的缓存与单测注入点）。
class PlaybackPayloadEncoder {
  List<String>? _cachedIds;
  List<Map<String, dynamic>>? _cachedPayload;

  /// 序列化整条队列；队内歌曲 id 序列未变时复用上次构建结果（同一对象）。
  List<Map<String, dynamic>> buildQueue(List<Song> queue) {
    final ids = [for (final s in queue) s.id];
    final cached = _cachedIds;
    var unchanged = cached != null && cached.length == ids.length;
    if (unchanged) {
      for (var i = 0; i < ids.length; i++) {
        if (cached![i] != ids[i]) {
          unchanged = false;
          break;
        }
      }
    }
    if (unchanged && _cachedPayload != null) return _cachedPayload!;
    _cachedIds = ids;
    _cachedPayload = [for (final s in queue) s.toJson()];
    return _cachedPayload!;
  }

  /// 组装播放会话 payload（含队列序列化、当前曲定位与位置归一化）。
  /// 队列为空或当前曲无法定位时返回 null。nowMs 用于写入 updatedAt。
  Map<String, dynamic>? buildSession({
    required List<Song> queue,
    required int currentIndex,
    required String? currentSongId,
    required Duration position,
    required Duration duration,
    required bool isPlaying,
    required int nowMs,
  }) {
    if (queue.isEmpty) return null;

    var idx = currentIndex;
    final hasCurrent = idx >= 0 && idx < queue.length;
    if (currentSongId != null &&
        (!hasCurrent || queue[idx].id != currentSongId)) {
      final resolved = queue.indexWhere((s) => s.id == currentSongId);
      if (resolved >= 0) idx = resolved;
    }
    if (idx < 0 || idx >= queue.length) return null;

    final normalized = normalizeSeekPosition(position, duration);
    return {
      'version': 1,
      'queue': buildQueue(queue),
      'currentIndex': idx,
      'currentSongId': queue[idx].id,
      'positionMs': normalized.inMilliseconds,
      'isPlaying': isPlaying,
      'updatedAt': nowMs,
    };
  }
}

/// 位置归一化：负进度归零、超过音频时长则裁到时长。
Duration normalizeSeekPosition(Duration position, Duration duration) {
  if (position < Duration.zero) return Duration.zero;
  if (duration > Duration.zero && position > duration) return duration;
  return position;
}