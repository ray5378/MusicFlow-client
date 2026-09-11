import 'package:just_audio/just_audio.dart';
import '../../../data/models/song.dart';
import '../../../data/models/audio_quality.dart';

/// 播放来源
enum PlaybackSource {
  stream, // 在线流式播放
}

/// 播放模式(四态,与服务端 PlayMode / 投屏链路对齐,2026-09-11 补齐 order)。
///
/// 命名与服务端线上值同名(order/all/one/shuffle),消除一层映射胶水。
/// 旧值映射(历史版本持久化的是 repeatAll/repeatOne):
///   repeatAll → all / repeatOne → one(读侧 LocalStorage.getPlaybackMode 处理)。
///
/// ⚠️ **order(顺序播放,播完即停)与 all(列表循环)在底层 just_audio 同为
/// LoopMode.off** —— 两者的行为差异由外层队列推进逻辑(next/_onSongCompleted)
/// 按 playbackMode 分支实现,不在这层。
///
/// 这是**权威状态**:不能从 (loopMode, shuffleEnabled) 派生 ——
/// order 与 all 的底层组合完全相同,派生必然丢失该维度。
enum PlaybackMode { order, all, one, shuffle }

const maxShuffleHistoryEntries = 200;

/// 预探测结论的客户端 TTL(毫秒)。必须 ≤ 服务端 negativeTtlSeconds 默认值(45s)
/// —— 服务端是判定权威,客户端缓存只允许更短(过期即回退到「未知 → 照常播放」)。
const probeCacheTtlMs = 45 * 1000;

/// 预探测结论条目(带时间戳,TTL 判定用)。
class ProbeCacheEntry {
  const ProbeCacheEntry({required this.ok, required this.at, this.verdict});
  final bool ok;
  final int at; // ms epoch
  /// 服务端四态判定(2026-09-11):playable | unplayable | transient | unknown。
  /// null = 旧构造(仅 ok)/ 旧服务端 → 回落到按 [ok] 推断。
  final String? verdict;
}

/// 某条预探测结论当前是否构成「明确的、未过期的不可播」。
///
/// §8.3 护栏 3:**无记录 / 已过期 → false(未知 → 照常播放)**。
/// 绝不把「不知道」当成「死的」—— 这是拆除永久拉黑时定下的边界。
/// 四态后:**只有服务端明确判定 unplayable 才预跳**;transient(网络抖动)与
/// unknown(未探过)一律不跳,由播放失败兜底。纯函数(守卫测试直接锁定)。
bool isProbeEntryUnplayable(ProbeCacheEntry? entry, int nowMs) {
  if (entry == null) return false;
  if (nowMs - entry.at >= probeCacheTtlMs) return false;
  if (entry.verdict != null) return entry.verdict == 'unplayable';
  return !entry.ok; // 旧构造 / 旧服务端兼容
}

/// 预跳过的纯函数核心(§8.3):从 [startIndex] 起连续越过「明确的、未过期的
/// 不可播」的歌,返回实际应播放的 index。
///
/// - 不越过队列末尾(all 模式回绕后的死源由下一轮接力,order 模式到末尾即停);
/// - 步数上限 = [queueLength](与投屏链路的绕圈上限 = 队列长度同源);
/// - 调用方负责不改队列 —— 本函数只算 index。
/// 纯函数(守卫测试直接锁定)。
int resolvePreProbeSkipIndex({
  required int startIndex,
  required int queueLength,
  required bool Function(int index) isKnownUnplayable,
}) {
  var idx = startIndex;
  var steps = 0;
  while (idx < queueLength && steps < queueLength && isKnownUnplayable(idx)) {
    idx++;
    steps++;
  }
  return idx;
}

class ShuffleHistoryEntry {
  const ShuffleHistoryEntry({
    required this.songId,
    required this.preferredIndex,
  });

  final String songId;
  final int preferredIndex;
}

/// 播放器状态
class PlayerState {
  final Song? currentSong;
  final List<Song> queue;
  final int currentIndex;
  final bool isPlaying;
  final ProcessingState processingState;
  final Duration position;
  final Duration duration;
  final LoopMode loopMode;
  final bool shuffleEnabled;

  /// 四态播放模式(权威)。order/all 的底层组合相同,差异只体现在外层推进,
  /// 因此必须独立存储而不能从 loopMode/shuffleEnabled 派生。
  final PlaybackMode playbackMode;
  final int shuffleHistoryCount;
  final AudioQualityLevel? currentQuality;
  final PlaybackSource? playbackSource;
  final int currentBitRateKbps;
  final Duration bufferedPosition;

  /// 本机播放音量（0.0~1.0，对齐主项目前端 volume 语义）。
  final double volume;

  PlayerState({
    this.currentSong,
    this.queue = const [],
    this.currentIndex = 0,
    this.isPlaying = false,
    this.processingState = ProcessingState.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.loopMode = LoopMode.off,
    this.shuffleEnabled = false,
    this.playbackMode = PlaybackMode.all,
    this.shuffleHistoryCount = 0,
    this.currentQuality,
    this.playbackSource,
    this.currentBitRateKbps = 0,
    this.bufferedPosition = Duration.zero,
    this.volume = 0.8,
  });

  PlayerState copyWith({
    Song? currentSong,
    List<Song>? queue,
    int? currentIndex,
    bool? isPlaying,
    ProcessingState? processingState,
    Duration? position,
    Duration? duration,
    LoopMode? loopMode,
    bool? shuffleEnabled,
    PlaybackMode? playbackMode,
    int? shuffleHistoryCount,
    AudioQualityLevel? currentQuality,
    PlaybackSource? playbackSource,
    int? currentBitRateKbps,
    Duration? bufferedPosition,
    double? volume,
  }) {
    return PlayerState(
      currentSong: currentSong ?? this.currentSong,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      processingState: processingState ?? this.processingState,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      loopMode: loopMode ?? this.loopMode,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      playbackMode: playbackMode ?? this.playbackMode,
      shuffleHistoryCount: shuffleHistoryCount ?? this.shuffleHistoryCount,
      currentQuality: currentQuality ?? this.currentQuality,
      playbackSource: playbackSource ?? this.playbackSource,
      currentBitRateKbps: currentBitRateKbps ?? this.currentBitRateKbps,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      volume: volume ?? this.volume,
    );
  }

  bool get _hasValidCurrent =>
      currentSong != null && currentIndex >= 0 && currentIndex < queue.length;

  bool get hasNext {
    if (!_hasValidCurrent) return false;
    return queue.isNotEmpty;
  }

  bool get hasPrevious {
    if (!_hasValidCurrent) return false;
    return queue.isNotEmpty;
  }
}
