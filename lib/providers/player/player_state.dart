import 'package:just_audio/just_audio.dart';
import '../../../data/models/song.dart';
import '../../../data/models/audio_quality.dart';

/// 播放来源
enum PlaybackSource {
  downloaded, // 已下载的本地文件
  cached, // 缓存的本地文件
  stream, // 在线流式播放
}

/// 播放模式（用于播放器控制区三态切换）
enum PlaybackMode { shuffle, repeatAll, repeatOne }

const maxShuffleHistoryEntries = 200;

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
