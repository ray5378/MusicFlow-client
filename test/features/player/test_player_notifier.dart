import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

/// Lightweight StateNotifier that satisfies playerProvider's concrete type
/// without constructing AudioService or AudioPlayer in widget tests.
class TestPlayerNotifier extends StateNotifier<PlayerState>
    implements PlayerNotifier {
  TestPlayerNotifier(super.state);

  int toggleCount = 0;
  int previousCount = 0;
  int nextCount = 0;
  int clearCount = 0;
  final List<Duration> seekTargets = <Duration>[];
  final List<int> skippedIndices = <int>[];
  final List<int> removedIndices = <int>[];

  void emit(PlayerState value) => state = value;

  @override
  PlaybackMode get playbackMode {
    if (state.shuffleEnabled) return PlaybackMode.shuffle;
    if (state.loopMode == LoopMode.one) return PlaybackMode.repeatOne;
    return PlaybackMode.repeatAll;
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(isPlaying: false);
  }

  @override
  Future<void> togglePlayPause() async {
    toggleCount += 1;
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> previous() async {
    previousCount += 1;
  }

  @override
  Future<void> next() async {
    nextCount += 1;
  }

  @override
  Future<void> seek(Duration position) async {
    seekTargets.add(position);
    state = state.copyWith(position: position);
  }

  @override
  Future<void> cyclePlaybackMode() async {
    if (state.shuffleEnabled) {
      state = state.copyWith(shuffleEnabled: false, loopMode: LoopMode.all);
    } else if (state.loopMode == LoopMode.one) {
      state = state.copyWith(shuffleEnabled: true, loopMode: LoopMode.off);
    } else {
      state = state.copyWith(shuffleEnabled: false, loopMode: LoopMode.one);
    }
  }

  @override
  Future<void> toggleFavorite() async {
    final song = state.currentSong;
    if (song == null) return;
    final updated = song.copyWith(starred: !song.starred);
    final queue = <Song>[
      for (final item in state.queue) item.id == song.id ? updated : item,
    ];
    state = state.copyWith(currentSong: updated, queue: queue);
  }

  @override
  Future<bool?> toggleSongFavorite(Song song) async {
    final updated = song.copyWith(starred: !song.starred);
    final queue = <Song>[
      for (final item in state.queue) item.id == song.id ? updated : item,
    ];
    state = state.copyWith(
      currentSong: state.currentSong?.id == song.id ? updated : null,
      queue: queue,
    );
    return updated.starred;
  }

  @override
  Future<void> playNext(Song song) async {
    final queue = <Song>[...state.queue];
    final insertIndex = (state.currentIndex + 1).clamp(0, queue.length);
    queue.insert(insertIndex, song);
    state = state.copyWith(queue: queue);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    skippedIndices.add(index);
    if (index < 0 || index >= state.queue.length) return;
    state = state.copyWith(
      currentSong: state.queue[index],
      currentIndex: index,
    );
  }

  @override
  Future<void> clearQueue() async {
    clearCount += 1;
    final current = state.currentSong;
    state = current == null
        ? PlayerState()
        : state.copyWith(queue: <Song>[current], currentIndex: 0);
  }

  @override
  void removeFromQueue(int index) {
    removedIndices.add(index);
    if (index < 0 || index >= state.queue.length) return;
    final queue = <Song>[...state.queue]..removeAt(index);
    if (index == state.currentIndex) {
      state = PlayerState(queue: queue);
      return;
    }
    state = state.copyWith(
      queue: queue,
      currentIndex: index < state.currentIndex
          ? state.currentIndex - 1
          : state.currentIndex,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  /// 投屏时镜像后端权威队列到本地(对齐 PlayerNotifier.syncQueueForCast)。
  @override
  void syncQueueForCast(List<Map<String, dynamic>> items, int index) {
    final songs = <Song>[];
    for (final it in items) {
      songs.add(castQueueItemToSong(it));
    }
    if (songs.isEmpty) return;
    final safeIndex = index.clamp(0, songs.length - 1);
    state = state.copyWith(
      queue: songs,
      currentIndex: safeIndex,
      currentSong: songs[safeIndex],
      position: Duration.zero,
      duration: Duration.zero,
    );
  }

  /// 回本机时恢复离开前保存的本地播放状态(对齐 PlayerNotifier.restoreStateForCast)。
  @override
  void restoreStateForCast({
    required List<Song> queue,
    required int currentIndex,
    required Song? currentSong,
    required Duration position,
    required LoopMode loopMode,
    required bool shuffleEnabled,
    required bool isPlaying,
  }) {
    final restoredIndex = currentIndex.clamp(
      -1,
      queue.isEmpty ? -1 : queue.length - 1,
    );
    state = state.copyWith(
      queue: queue,
      currentIndex: restoredIndex,
      currentSong:
          restoredIndex >= 0 && restoredIndex < queue.length
              ? queue[restoredIndex]
              : currentSong,
      position: position,
      loopMode: loopMode,
      shuffleEnabled: shuffleEnabled,
      isPlaying: isPlaying,
    );
  }
}
