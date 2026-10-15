import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

/// Lightweight Notifier that satisfies playerProvider's concrete type
/// without constructing AudioService or AudioPlayer in widget tests.
///
/// ADR-2 阶段 3c：`playerProvider` 由 `同步通知 Provider` 迁到
/// `NotifierProvider`，本桩随之改为 `extends Notifier<PlayerState>`。
/// 必须 `extends`（不能只 `implements PlayerNotifier`）：`NotifierProviderElement`
/// 会做 `(notifier as Notifier<T>).build()`，只 implements 的类型过不了这层 cast。
///
/// 初始态没有 `同步通知基类` 那种 `super(initial)` 通道，改为构造参数存入、
/// 由 `build()` 返回。`build()` 同时标记「已挂到 provider element」—— 未挂载时
/// 读写 `state` 会落到本地镜像，兼容既有「先造桩、后 override」的写法。
class TestPlayerNotifier extends Notifier<PlayerState> implements PlayerNotifier {
  TestPlayerNotifier(PlayerState initial) : _mirror = initial;

  /// 状态镜像：既是构造注入的初始态，也是脱容器（未挂到 element）时的读写落点。
  ///
  /// 为什么不能只靠 `super.state`：`Notifier.state` 依赖 provider element，未挂载
  /// 时读写会抛 LateInitializationError；而迁移前 `同步通知基类` 自持 `_state`，
  /// 大量既有用例是「先造桩、后 override，期间读写 state」。这里兜住这条老路径。
  PlayerState _mirror;

  /// 是否已挂到 provider element（由 `build()` 置真）。
  bool _attached = false;

  @override
  PlayerState build() {
    _attached = true;
    return _mirror;
  }

  /// 保持旧 `同步通知基类.mounted` 语义：widget 测试里这个桩恒为「存活」。
  @override
  bool get mounted => true;

  @override
  PlayerState get state => _attached ? super.state : _mirror;

  @override
  set state(PlayerState value) {
    _mirror = value;
    if (_attached) super.state = value;
  }

  int toggleCount = 0;
  int previousCount = 0;
  int nextCount = 0;
  int clearCount = 0;
  final List<Duration> seekTargets = <Duration>[];
  final List<int> skippedIndices = <int>[];
  final List<int> removedIndices = <int>[];

  void emit(PlayerState value) => state = value;

  @override
  PlaybackMode get playbackMode => state.playbackMode;

  @override
  Future<void> setPlaybackMode(PlaybackMode mode, {bool persist = true}) async {
    state = state.copyWith(playbackMode: mode);
  }

  @override
  int _skipKnownUnplayable(int startIndex) => startIndex;

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
    final nextMode = switch (state.playbackMode) {
      PlaybackMode.order => PlaybackMode.all,
      PlaybackMode.all => PlaybackMode.one,
      PlaybackMode.one => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.order,
    };
    state = state.copyWith(playbackMode: nextMode);
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
  Future<void> clearQueue({bool keepCurrent = true}) async {
    clearCount += 1;
    if (keepCurrent) {
      final current = state.currentSong;
      state = current == null
          ? PlayerState()
          : state.copyWith(queue: <Song>[current], currentIndex: 0);
    } else {
      state = PlayerState();
    }
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
