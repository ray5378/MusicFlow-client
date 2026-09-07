import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 离开本机时的本地播放状态快照:回本机时恢复,保证「切换前设备」逻辑不丢。
class LocalPlaybackSnapshot {
  const LocalPlaybackSnapshot({
    required this.queue,
    required this.currentIndex,
    required this.currentSong,
    required this.position,
    required this.isPlaying,
    required this.loopMode,
    required this.shuffleEnabled,
  });

  final List<Song> queue;
  final int currentIndex;
  final Song? currentSong;
  final Duration position;
  final bool isPlaying;
  final LoopMode loopMode;
  final bool shuffleEnabled;
}

class CastPeerState {
  const CastPeerState({
    this.activePeer,
    this.status = const PeerStatus(),
    this.loadingPeers = false,
    this.playMode = 'all',
    this.smoothPositionSeconds = 0,
    this.castQueue = const <Map<String, dynamic>>[],
    this.castIndex = -1,
    this.offline = false,
    this.endOfQueueCount = 0,
  });

  /// null = 本机播放。
  final PeerInfo? activePeer;
  final PeerStatus status;
  final bool loadingPeers;

  /// 投屏队列播放模式(order|one|all|shuffle,对齐后端),仅投屏态有效。
  final String playMode;

  /// 平滑进度(秒):250/500ms tick 插值,轮询结果回写修正。
  final double smoothPositionSeconds;

  /// 后端权威投屏队列快照(仅投屏态填充),供队列面板展示。
  final List<Map<String, dynamic>> castQueue;
  final int castIndex;

  /// 远端连续轮询失败(离线/被移除)。
  final bool offline;

  /// 队列**自然播完**计数:设备曾处于活跃播放,随后无任何客户端命令干预而
  /// 跳变为非活跃(STOPPED/空)即判定队列到底,计数 +1。
  /// 随机歌曲「播完自动换一批」等场景监听此值变化触发续播。
  final int endOfQueueCount;

  bool get isCasting => activePeer != null;

  /// 设备是否真的在播(后端 state 判定)。
  bool get devicePlaying => status.active;

  String get targetName => activePeer?.name ?? l10nNowCurrent().peer_self;

  CastPeerState copyWith({
    PeerInfo? activePeer,
    bool clearActivePeer = false,
    PeerStatus? status,
    bool? loadingPeers,
    String? playMode,
    double? smoothPositionSeconds,
    List<Map<String, dynamic>>? castQueue,
    int? castIndex,
    bool? offline,
    int? endOfQueueCount,
  }) {
    return CastPeerState(
      activePeer: clearActivePeer ? null : (activePeer ?? this.activePeer),
      status: status ?? this.status,
      loadingPeers: loadingPeers ?? this.loadingPeers,
      playMode: playMode ?? this.playMode,
      smoothPositionSeconds: smoothPositionSeconds ?? this.smoothPositionSeconds,
      castQueue: castQueue ?? this.castQueue,
      castIndex: castIndex ?? this.castIndex,
      offline: offline ?? this.offline,
      endOfQueueCount: endOfQueueCount ?? this.endOfQueueCount,
    );
  }
}

/// 本地播放模式 → 后端 PlayMode(order|one|all|shuffle)。
String mapLocalPlayMode(PlaybackMode mode) => switch (mode) {
      PlaybackMode.shuffle => 'shuffle',
      PlaybackMode.repeatOne => 'one',
      PlaybackMode.repeatAll => 'all',
    };
