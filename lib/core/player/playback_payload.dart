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
  ///
  /// [queueOrigin] 是当前队列的来源（歌单/专辑/艺术家…）。必须落盘：重启后
  /// 队列由此会话恢复，若来源丢失，「本机→设备」接续搬移将拿不到
  /// `serverContentType`，只能整队推送（数千首 ≈ MB 级）。实测（3251 首，
  /// 公网）：主通道 115B/296ms vs 整队 642KB/7986ms，缩约 5720×。
  Map<String, dynamic>? buildSession({
    required List<Song> queue,
    required int currentIndex,
    required String? currentSongId,
    required Duration position,
    required Duration duration,
    required bool isPlaying,
    required int nowMs,
    Map<String, dynamic>? queueOrigin,
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
      if (queueOrigin != null) kSessionQueueOriginKey: queueOrigin,
    };
  }
}

/// 位置归一化：负进度归零、超过音频时长则裁到时长。
Duration normalizeSeekPosition(Duration position, Duration duration) {
  if (position < Duration.zero) return Duration.zero;
  if (duration > Duration.zero && position > duration) return duration;
  return position;
}

/// 权威播放时长：歌曲元数据已知时**以元数据为准**，实时流上报值一律让位。
///
/// 现场（Windows / Android 实测）：服务端实时管道流起播时，`durationStream`
/// 会先把时长报成 1s、2s…再一路爬到真实时长。若直接拿它当权威值：
/// - 进度条「总时长」先显示正确值、再被拽回 0 并逐秒爬升（观感抖动）；
/// - 更严重的是 [normalizeSeekPosition] 会按这个偏小的时长截断 seek 目标 ——
///   用户拖到 3 分钟却被裁成几秒，听感就是「点击/拖拽都从开头播放同一首」。
///
/// 元数据缺失（老库/导入歌曲）时才退回流上报值，保持原有「流时长更准确」。
Duration authoritativeDuration({
  required Duration streamDuration,
  required Duration metadataDuration,
}) {
  return metadataDuration > Duration.zero ? metadataDuration : streamDuration;
}

/// 播放会话 payload 中「队列来源」的键名。
///
/// 写入与读取共用同一常量：两侧任何一边拼错都会被守卫测试立刻抓住，
/// 避免出现「写进去了但读的时候键名不一致」这种静默失效。
const String kSessionQueueOriginKey = 'queueOrigin';

/// 从播放会话 payload 中取出队列来源的原始 JSON 片段。
///
/// 单独抽成函数的原因：会话恢复发生在 `_init()` 内（需要真实 AudioService），
/// 在纯测试里驱动成本极高、极易漏测。做成纯函数后，「恢复时必须回填来源」
/// 这条契约才能被单测直接锁死——历史上它正是因为没有任何测试覆盖，
/// 才让「重启后大歌单搬移撞 403」静默存活。
Object? readSessionQueueOrigin(Map<String, dynamic> session) =>
    session[kSessionQueueOriginKey];