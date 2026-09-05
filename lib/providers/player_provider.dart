import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import '../data/models/song.dart';
import '../data/models/peer.dart';
import '../data/models/audio_quality.dart';
import '../data/models/server_address.dart';
import '../data/sources/subsonic_api_client.dart';
import '../data/sources/local_storage.dart';
import '../data/repositories/music_repository.dart';

import '../core/network/connectivity_monitor.dart';
import '../core/utils/logger.dart';
import '../core/utils/network_error_notifier.dart';
import '../core/utils/server_url_security.dart';
import '../core/services/audio_handler_service.dart';

import 'music_provider.dart';
import 'api_provider.dart';
import 'audio_quality_provider.dart';
import 'crossfade_provider.dart';
import 'gd_music_provider.dart';
import 'sleep_timer_provider.dart';

export 'player/player_state.dart';
export 'player/favorite_scrobble_handler.dart';
import 'player/player_state.dart';
import 'player/favorite_scrobble_handler.dart';
import 'player/player_seek_policy.dart';
import 'player/transcoded_stream_seek.dart';

const _playerLogTag = 'PLAYER';
const _playDbgTag = 'PLAYDBG';

bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

bool get _isApplePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// 将解析后的试听元数据写回原队列项，同时保留其它正式/试听歌曲。
@visibleForTesting
({List<Song> queue, int index}) resolvePreviewPlaybackQueue({
  required List<Song> queue,
  required int preferredIndex,
  required Song unresolvedSong,
  required Song resolvedSong,
}) {
  final nextQueue = List<Song>.of(queue);
  var nextIndex = preferredIndex;

  if (nextQueue.isEmpty) {
    return (queue: <Song>[resolvedSong], index: 0);
  }

  final preferredIndexMatches =
      nextIndex >= 0 &&
      nextIndex < nextQueue.length &&
      nextQueue[nextIndex].id == unresolvedSong.id;
  if (!preferredIndexMatches) {
    final matchedIndex = nextQueue.indexWhere(
      (item) => item.id == unresolvedSong.id,
    );
    if (matchedIndex >= 0) {
      nextIndex = matchedIndex;
    } else {
      nextIndex = nextIndex.clamp(0, nextQueue.length);
      nextQueue.insert(nextIndex, resolvedSong);
      return (queue: nextQueue, index: nextIndex);
    }
  }

  nextQueue[nextIndex] = resolvedSong;
  return (queue: nextQueue, index: nextIndex);
}

/// 播放器 Provider

// ...
final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>((
  ref,
) {
  // 不固定 apiClient/musicRepository 引用，PlayerNotifier 内部通过 ref.read 动态获取
  // 这样既不建立 watch 依赖（不会被重建），又能始终拿到最新的实例
  return PlayerNotifier(ref);
});

/// 播放器状态管理器
class PlayerNotifier extends StateNotifier<PlayerState> {
  final Ref _ref;
  AudioPlayer? _audioPlayer;
  MusicFlowAudioHandler? _audioHandler;

  /// 当前音频处理器（后台服务中初始化）。供 DLNA 等注册「任务被手动清理」回调，
  /// 以便在用户划掉 App 时释放各自的后台保活。
  MusicFlowAudioHandler? get audioHandler => _audioHandler;
  StreamSubscription<NetworkType>? _networkTypeSubscription;
  final Random _random = Random();
  final List<ShuffleHistoryEntry> _shuffleBackHistory = <ShuffleHistoryEntry>[];
  final List<ShuffleHistoryEntry> _shuffleForwardHistory =
      <ShuffleHistoryEntry>[];
  // 随机模式「一轮内不重复」:记录本轮已播放的歌曲 id(与主项目洗牌序列语义一致,
  // 播完一轮才重新洗牌)。随机取下一首时优先从未播过的歌中选。
  final Set<String> _shuffleRoundPlayedIds = <String>{};
  Duration? _pendingSeekPosition;
  String? _pendingSeekSongId;
  String? _currentStreamUrl;
  String? _currentStreamSongId;
  String? _currentStreamFormat;
  int? _currentStreamMaxBitRate;
  String? _loadedSourceSongId;
  int _sourceGeneration = 0;
  int _seekRequestGeneration = 0;
  int _transportRequestGeneration = 0;
  int? _activeSeekGeneration;
  String? _activeSeekSongId;
  bool _isApplyingPendingSeek = false;
  bool _seekByReloadStream = false;
  Duration _sourcePositionOffset = Duration.zero;
  String? _forcedNextSongId;
  int? _forcedNextIndex;
  ProcessingState? _lastProcessingStateForDebug;
  bool _isHandlingCompletion = false;
  String? _completionHandlingSongId;
  Timer? _positionPollTimer;
  Duration _lastPolledPlayerPosition = Duration.zero;
  int _stagnantPositionTicks = 0;
  int _lastStagnantLogTick = -1;
  int _lastIgnoredSyntheticPositionLogTick = -1;

  /// 0 秒卡死兜底计数：播放意图存在但长时间卡在 loading/buffering 且
  /// 位置无进展时累计；一旦离开该状态或超出阈值即清零/reset。
  int _startupStuckTicks = 0;

  /// 期望正在自动播放（尚未被用户暂停）的意图标记。
  /// 仅在 playSong(autoPlay:true) 时置位、用户暂停时清除。
  /// 必要性：若底层 setSource(网络/缓存/转码)卡住不返回,play() 永远
  /// 不被调用,just_audio 的 `player.playing` 恒为 false,0 秒卡死看门狗
  /// (仅当 playing=true 才累计)会永不触发——正是「切下一首再切回」能恢复、
  /// 而看门狗却放任不管的根因。此标记让看门狗在「想播但还没真正开始播」
  /// 的阶段也能累计,覆盖源加载挂起这一最常被漏掉的场景。
  bool _expectingAutoplay = false;

  /// 停滞看门狗阈值：进度在播放状态下持续卡住达到该 tick 数(每 500ms 一 tick)
  /// 即自动跳下一首，避免「进度一直不走却无自愈」。10 tick = 5 秒。
  static const int _stagnantSkipThresholdTicks = 10;

  /// 0 秒卡死兜底阈值：播放意图存在且位置持续卡在起点(loading/buffering
  /// 或 position 长期 <=0)，连续达到该 tick 数(每 500ms) 即重载当前曲目，
  /// 模拟「切下一首再切回」的效果。12 tick = 6 秒。
  static const int _startupStuckSkipThresholdTicks = 12;

  /// 0 秒卡死「连续重载」容错上限：同一首曲因卡在起点被看门狗连续重载达到
  /// 该次数仍无任何进展(位置始终不前进)，判定为「后端确无可播源」而非
  /// 瞬时挂起，转入既有失败跳歌逻辑(_handlePlaybackError)标记死歌并跳下一首，
  /// 避免对一首永远无法起播的歌无限重载原地空转。0 秒卡死重载走的是模拟
  /// 「切下一首再切回」路径，瞬时可恢复的挂起在 1 次重载后即会推进位置并
  /// 清零本计数；因此容错设为 2：允许 1 次自愈重试，若第 2 次连续重载仍无
  /// 进展则判死跳歌。
  static const int _startupReloadTolerance = 2;

  /// 当前正在被 0 秒卡死看门狗重载的曲目 id 与该曲的连续重载次数。
  /// 用于区分「瞬时挂起可自愈」与「真无可播源应放弃」。
  String? _startupStuckSongId;
  int _startupReloadStreak = 0;

  /// Windows 专项近末尾兜底计数阈值。
  ///
  /// Android 正常播完时 just_audio 会上报 completed，走常规完成流程；但
  /// Windows(just_audio 走 media_kit 后端)对部分容器的表现是：解码到字节末
  /// 后 position 顶到接近/等于声明的 duration，而 processing 却进入 buffering
  /// 而非 completed——于是 `isReadyPlaying`(要求 processing==ready)恒为 false，
  /// 导致上面的 `_stagnantPositionTicks` 每个 tick 都被清零，近末尾守卫与停滞
  /// 看门狗对 Windows 全部失效 → 「某一首歌固定的末尾卡死」。
  ///
  /// 专用于本守卫的计数不与 processing 绑定：只要「确实在播(player.playing)
  /// + 位置落在末段窗口内不再前进」就累计，到阈值即按播完处理(尊重随机/单曲
  /// 循环/顺序)。进程真正比播放引擎更可靠地表达“用户还在播但要结束了”。
  /// 5 tick ≈ 2.5s。暂停/前进/离开末段任一情况都会清零，避免误判。
  static const int _nearEndStuckTicksThreshold = 5;
  int _nearEndStuckTicks = 0;
  bool _syntheticPositionFallbackActive = false;
  int _playDebugSession = 0;
  bool _loggedDurationUnavailableForSong = false;
  Timer? _fadeTimer;
  Completer<void>? _fadeCompleter;
  // 播放会话落盘节流：仅当序列本质上变化时才重新序列化整张队列，避免每次
  // position tick 都全量 toJson + jsonEncode（大队列会在大屏旋转封面时周期卡顿）。
  // 由 2s 放宽到 5s：降频 2.5 倍，崩溃续播最多损失 ~5s 进度，与主流播放器一致。
  static const Duration _playbackSessionPersistInterval = Duration(seconds: 5);
  Timer? _playbackSessionPersistTimer;
  Timer? _volumePersistTimer;
  bool _isPersistingPlaybackSession = false;
  bool _isRestoringPlaybackSession = false;
  // 队列序列化缓存：queue 未变化时直接复用序列化结果，避免每 tick 重序列化整队。
  List<Object?> _cachedQueueIds = const [];
  List<Map<String, dynamic>> _cachedQueuePayload = const [];
  NetworkType _lastObservedNetworkType = NetworkType.none;
  bool _retryCurrentPlaybackOnReconnect = false;
  bool _retryingCurrentPlayback = false;
  String? _pendingRetrySongId;
  bool _pendingRetryIsPreview = false;
  bool _pendingRetryAutoPlay = true;

  // ── 播放失败自动跳过 + 预探测 ──────────────────────────────────────────
  /// 连续播放失败计数；达到上限后停止自动跳过，避免整队不可播时死循环。
  int _failStreak = 0;
  static const int _maxFailStreak = 5;

  /// 预探测缓存：songId -> 是否可用（session 级别，重启失效）。
  /// 带上限（FIFO 逐出），防止常驻无界增长（SPEC §1.5 内存红线）。
  final Map<String, bool> _probeCache = <String, bool>{};
  static const int _probeCacheMaxEntries = 500;

  /// 预探测确认不可播的歌曲 ID 集合，播放前自动跳过（与 _probeCache 同步带上限）。
  final Set<String> _deadSongs = <String>{};
  static const int _deadSongsMaxEntries = 200;

  /// 防止并发预探测。
  bool _probing = false;

  /// 预探测窗口大小：提前探测接下来几首。
  static const int _probeWindow = 3;

  // ── Handlers ──────────────────────────────────────────────────────────────
  late final FavoriteScrobbleHandler _favoriteHandler;

  /// 动态获取最新的 API client
  SubsonicApiClient get _apiClient => _ref.read(subsonicApiClientProvider);

  /// 动态获取最新的 MusicRepository
  MusicRepository get _musicRepository =>
      _ref.read(musicRepositoryProvider) ?? MusicRepository(_apiClient);

  PlayerNotifier(this._ref) : super(PlayerState()) {
    _favoriteHandler = FavoriteScrobbleHandler(_ref);
    _initConnectivityRetryHandling();
    _init();
  }

  @override
  set state(PlayerState value) {
    super.state = value;
    _schedulePersistPlaybackSession();
  }

  /// 初始化播放器
  void _init() async {
    AudioPlayer player;

    // 初始化 AudioService（仅在移动平台，桌面端不支持且可能干扰播放）
    try {
      if (_isDesktopPlatform) throw UnsupportedError('Desktop platform');
      _audioHandler = await initAudioService();
      player = _audioHandler!.audioPlayer;
      Logger.info('AudioService initialized');

      // 设置通知栏按钮回调
      _audioHandler?.onSkipToNext = () {
        next();
      };
      _audioHandler?.onSkipToPrevious = () {
        previous();
      };
      _audioHandler?.onSeek = seek;
    } catch (e) {
      Logger.warn('AudioService not available: $e');
      player = AudioPlayer(
        audioLoadConfiguration: const AudioLoadConfiguration(
          androidLoadControl: AndroidLoadControl(
            minBufferDuration: Duration(minutes: 10),
            maxBufferDuration: Duration(minutes: 15),
            bufferForPlaybackDuration: Duration(seconds: 5),
            bufferForPlaybackAfterRebufferDuration: Duration(seconds: 10),
          ),
          darwinLoadControl: DarwinLoadControl(
            preferredForwardBufferDuration: Duration(minutes: 10),
          ),
        ),
      );
    }

    _audioPlayer = player;

    // 优先恢复本机音量：桌面端 SharedPreferences 读取极快，player 一就绪就
    // 落库并写入 real 引擎。放在最前，避免后续模式/会话恢复失败时音量恢复被
    // 跳过（否则每次重开都停在默认值、观感上"回到 100%"）。也保证任何播放
    // 源就绪前，real 引擎音量已是用户上次设置。
    await _restorePlayerVolume();

    // 监听播放状态
    player.playingStream.listen((isPlaying) {
      _playDbg(
        'playingStream playing=$isPlaying '
        'processing=${player.processingState.name} '
        'sourcePosition=${player.position} '
        'position=${_logicalPlayerPosition(player.position)} '
        'sourceBuffered=${player.bufferedPosition} '
        'buffered=${_logicalPlayerPosition(player.bufferedPosition)} '
        'song=${state.currentSong?.id}',
      );
      if (mounted) state = state.copyWith(isPlaying: isPlaying);
    });

    // 监听播放进度
    player.positionStream.listen((position) {
      if (!mounted) return;

      // A queued seek is the user's latest intent. While the next source is
      // still loading, just_audio may continue to report the previous source
      // position; do not let that stale value make the scrubber jump back.
      if (_shouldPreserveSeekPosition()) {
        return;
      }

      final logicalPosition = _logicalPlayerPosition(position);

      // 合成进度模式下，positionStream 可能回传 0 或过时位置，
      // 会把 UI 进度回退。此时统一忽略，交给轮询器维护并在恢复后切回真实位置。
      final ignorePositionWhileSynthetic =
          _syntheticPositionFallbackActive &&
          state.position > const Duration(milliseconds: 250);
      if (ignorePositionWhileSynthetic) {
        final isStuckZero = position <= const Duration(milliseconds: 50);
        final shouldLog =
            _stagnantPositionTicks != _lastIgnoredSyntheticPositionLogTick &&
            _stagnantPositionTicks % 6 == 0;
        if (shouldLog) {
          _lastIgnoredSyntheticPositionLogTick = _stagnantPositionTicks;
          _playDbg(
            isStuckZero
                ? 'positionStream ignored_stuck_zero '
                      'sourcePos=$position logicalPos=$logicalPosition '
                      'statePos=${state.position} '
                      'song=${state.currentSong?.id}'
                : 'positionStream ignored_while_synthetic '
                      'sourcePos=$position logicalPos=$logicalPosition '
                      'statePos=${state.position} '
                      'song=${state.currentSong?.id}',
          );
        }
        return;
      }

      // 进度更新节流 ≥250ms(与投屏 tick 对齐):positionStream(~200ms)
      // 高频 tick 只写回明显前进的位置,避免驱动整页高频重建(SEC §8.2)。
      // 后退(换歌/seek 回退)必须立即写回,保证进度回跳及时。
      final lastWrittenPosition = state.position;
      if ((logicalPosition - lastWrittenPosition) >=
              const Duration(milliseconds: 250) ||
          logicalPosition < lastWrittenPosition) {
        state = state.copyWith(position: logicalPosition);
      }
    });
    _startPositionPolling(player);

    // 监听缓冲进度
    player.bufferedPositionStream.listen((buffered) {
      if (mounted) {
        if (_shouldPreserveSeekPosition()) return;
        state = state.copyWith(
          bufferedPosition: _logicalPlayerPosition(buffered),
        );
      }
    });
    // 监听总时长
    player.durationStream.listen((duration) {
      if (mounted) {
        if (duration != null && duration > Duration.zero) {
          if (_shouldPreserveSeekPosition() && _seekByReloadStream) {
            _playDbg(
              'durationStream ignored during reload seek duration=$duration '
              'song=${state.currentSong?.id}',
            );
            return;
          }
          // A timeOffset stream may expose either the remaining duration or
          // the original X-Content-Duration. The song timeline is already
          // known, so do not replace it with a source-relative duration.
          if (_sourcePositionOffset > Duration.zero &&
              state.duration > Duration.zero) {
            _loggedDurationUnavailableForSong = false;
            _playDbg(
              'durationStream kept logical duration=${state.duration} '
              'sourceDuration=$duration offset=$_sourcePositionOffset '
              'song=${state.currentSong?.id}',
            );
            return;
          }
          // 如果流能提供时长，优先使用流的时长（更准确）
          state = state.copyWith(
            duration: _sourcePositionOffset > Duration.zero
                ? duration + _sourcePositionOffset
                : duration,
          );
          _loggedDurationUnavailableForSong = false;
          _playDbg(
            'durationStream duration=$duration song=${state.currentSong?.id}',
          );
        } else {
          if (!_loggedDurationUnavailableForSong && state.currentSong != null) {
            _loggedDurationUnavailableForSong = true;
            _playDbg(
              'durationStream unavailable duration=$duration '
              'song=${state.currentSong?.id}',
            );
          }
        }
      }
      // 如果 duration 为 null 或 0，保持使用歌曲元数据的时长
    });

    // 监听播放完成
    player.playerStateStream.listen((playerState) {
      if (mounted && state.processingState != playerState.processingState) {
        state = state.copyWith(processingState: playerState.processingState);
      }
      if (_lastProcessingStateForDebug != playerState.processingState) {
        _lastProcessingStateForDebug = playerState.processingState;
        _seekDbg(
          'playerState=${playerState.processingState.name} '
          'playing=${playerState.playing} '
          'sourcePosition=${player.position} '
          'position=${_logicalPlayerPosition(player.position)} '
          'sourceBuffered=${player.bufferedPosition} '
          'buffered=${_logicalPlayerPosition(player.bufferedPosition)} '
          'duration=${player.duration} '
          'sourceOffset=$_sourcePositionOffset '
          'pending=$_pendingSeekPosition '
          'pendingSong=$_pendingSeekSongId '
          'currentSong=${state.currentSong?.id}',
        );
      }
      if (playerState.processingState == ProcessingState.ready ||
          playerState.processingState == ProcessingState.completed) {
        // 播放源就绪时把音量重写成用户设置值：Windows 的播放引擎在载入新源
        // 后可能把音量重置为 1.0，这里再压回上次保存的音量，确保重启后实际
        // 读音与 UI 都是保存值，而不是被顶回 100%。
        _audioPlayer?.setVolume(state.volume);
        unawaited(_applyPendingSeekIfNeeded());
      }

      // 播放成功：重置连续失败计数（与主项目前端 onplay 回调一致）。
      if (playerState.processingState == ProcessingState.ready &&
          playerState.playing) {
        _failStreak = 0;
      }

      if (playerState.processingState != ProcessingState.completed) {
        _isHandlingCompletion = false;
        _completionHandlingSongId = null;
      }

      if (mounted && playerState.processingState == ProcessingState.completed) {
        final completedSongId = state.currentSong?.id;
        final shouldHandle =
            completedSongId != null &&
            (!_isHandlingCompletion ||
                _completionHandlingSongId != completedSongId);
        if (shouldHandle) {
          _isHandlingCompletion = true;
          _completionHandlingSongId = completedSongId;
          _seekDbg(
            'completed detected song=$completedSongId '
            'loop=${state.loopMode.name} shuffle=${state.shuffleEnabled} '
            'index=${state.currentIndex}/${state.queue.length - 1} '
            'hasNext=${state.hasNext}',
          );
          unawaited(_onSongCompleted(completedSongId));
        }
      }
    });

    // 监听循环模式
    player.loopModeStream.listen((loopMode) {
      if (mounted) state = state.copyWith(loopMode: loopMode);
    });

    // 监听随机模式
    player.shuffleModeEnabledStream.listen((enabled) {
      if (!enabled) {
        _resetShuffleHistory(updateState: false);
      }
      if (mounted) {
        state = state.copyWith(
          shuffleEnabled: enabled,
          shuffleHistoryCount: enabled ? state.shuffleHistoryCount : 0,
        );
      }
    });

    await _restorePlaybackMode();
    await _restorePlaybackSession();
  }

  void _initConnectivityRetryHandling() {
    final connectivityMonitor = _ref.read(connectivityMonitorProvider);
    _lastObservedNetworkType = connectivityMonitor.currentNetworkType;
    _networkTypeSubscription?.cancel();
    _networkTypeSubscription = connectivityMonitor.networkTypeStream.listen(
      (networkType) {
        final previousType = _lastObservedNetworkType;
        _lastObservedNetworkType = networkType;
        if (networkType == NetworkType.none || previousType == networkType) {
          return;
        }
        unawaited(
          _retryCurrentPlaybackIfNeeded(
            networkType: networkType,
            previousType: previousType,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        Logger.warnWithTag(
          _playerLogTag,
          'connectivity retry listener error',
          error,
        );
      },
    );
  }

  void _scheduleCurrentPlaybackRetry({
    required Song song,
    required bool isPreview,
    required bool autoPlay,
  }) {
    _retryCurrentPlaybackOnReconnect = true;
    _pendingRetrySongId = song.id;
    _pendingRetryIsPreview = isPreview;
    _pendingRetryAutoPlay = autoPlay;
    _playDbg(
      'schedule reconnect retry song=${song.id} preview=$isPreview '
      'autoPlay=$autoPlay network=$_lastObservedNetworkType',
    );
  }

  void _clearCurrentPlaybackRetry({
    String? reason,
    bool preserveRetrying = false,
  }) {
    final hadRetryState =
        _retryCurrentPlaybackOnReconnect ||
        _retryingCurrentPlayback ||
        _pendingRetrySongId != null;
    if (hadRetryState && reason != null) {
      _playDbg(
        'clear reconnect retry reason=$reason '
        'song=$_pendingRetrySongId retrying=$_retryingCurrentPlayback',
      );
    }
    _retryCurrentPlaybackOnReconnect = false;
    _pendingRetrySongId = null;
    _pendingRetryIsPreview = false;
    _pendingRetryAutoPlay = true;
    if (!preserveRetrying) {
      _retryingCurrentPlayback = false;
    }
  }

  Future<void> _retryCurrentPlaybackIfNeeded({
    required NetworkType networkType,
    required NetworkType previousType,
  }) async {
    if (!_retryCurrentPlaybackOnReconnect || _retryingCurrentPlayback) {
      return;
    }

    final song = state.currentSong;
    if (song == null) {
      _clearCurrentPlaybackRetry(reason: 'no_current_song');
      return;
    }

    if (_pendingRetrySongId != null && song.id != _pendingRetrySongId) {
      _clearCurrentPlaybackRetry(reason: 'current_song_changed');
      return;
    }

    _retryingCurrentPlayback = true;
    final retryAutoPlay = _pendingRetryAutoPlay;
    final retryPreview = _pendingRetryIsPreview || song.isPreview;
    _playDbg(
      'retry current playback on connectivity change '
      '$previousType->$networkType song=${song.id} preview=$retryPreview',
    );

    try {
      final retryQueue = state.queue.isEmpty ? [song] : state.queue;
      var retryIndex = state.currentIndex;
      final currentIndexMatchesSong =
          retryIndex >= 0 &&
          retryIndex < retryQueue.length &&
          retryQueue[retryIndex].id == song.id;
      if (!currentIndexMatchesSong) {
        final matchedIndex = retryQueue.indexWhere(
          (item) => item.id == song.id,
        );
        retryIndex = matchedIndex >= 0 ? matchedIndex : 0;
      }

      await playSong(
        song,
        queue: retryQueue,
        index: retryIndex,
        autoPlay: retryAutoPlay,
      );
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'reconnect retry failed for current playback',
        e,
      );
    } finally {
      _retryingCurrentPlayback = false;
    }
  }

  /// 播放单曲
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool recordShuffleHistory = false,
    bool clearShuffleForwardHistory = false,
    bool autoPlay = true,
  }) async {
    final playQueue = queue ?? [song];
    final playIndex = index ?? 0;
    _syncShuffleHistoryBeforeSongChange(
      nextSong: song,
      nextQueue: playQueue,
      nextIndex: playIndex,
      recordHistory: recordShuffleHistory,
      clearForwardHistory: clearShuffleForwardHistory,
    );

    // 记录「期望自动播放」意图：看门狗据此在源加载挂起(play() 未执行、
    // playing=false)时也能识别并重载，覆盖 0 秒卡死场景。
    _expectingAutoplay = autoPlay;

    if (song.isPreview) {
      await _playPreviewSongInternal(
        song,
        queue: playQueue,
        index: playIndex,
        autoPlay: autoPlay,
      );
      return;
    }

    // 跳过预探测确认不可播的歌曲（与主项目前端 deadSongs 跳过一致）。
    if (_deadSongs.contains(song.id) && playQueue.length > 1) {
      Logger.warnWithTag(
        _playerLogTag,
        'skip confirmed-unplayable song: ${song.title} (${song.id})',
      );
      // 尝试下一首
      final nextIdx = playIndex + 1;
      if (nextIdx < playQueue.length) {
        await playSong(
          playQueue[nextIdx],
          queue: playQueue,
          index: nextIdx,
          recordShuffleHistory: recordShuffleHistory,
          clearShuffleForwardHistory: clearShuffleForwardHistory,
          autoPlay: autoPlay,
        );
      }
      return;
    }

    final debugSession = ++_playDebugSession;
    _transportRequestGeneration += 1;
    bool isCurrentSession() =>
        _isPlaybackContextCurrent(session: debugSession, songId: song.id);
    _clearCurrentPlaybackRetry(
      reason: 'play_song_started',
      preserveRetrying: _retryingCurrentPlayback,
    );
    try {
      _seekDbg(
        'playSong start song=${song.id} title="${song.title}" '
        'suffix=${song.suffix} duration=${song.duration}s '
        'queue=${playQueue.length} index=$playIndex autoPlay=$autoPlay',
      );
      _playDbg(
        'sid=$debugSession playSong enter song=${song.id} '
        'suffix=${song.suffix} durationSec=${song.duration} '
        'queue=${playQueue.length} index=$playIndex',
      );

      // 淡出当前歌曲（如果启用了淡入淡出）
      await _fadeOut(debugSession);
      if (_playDebugSession != debugSession) return;
      if (!autoPlay) {
        _cancelFade();
        await _audioPlayer?.pause();
        await _audioHandler?.pause();
        if (_playDebugSession != debugSession) return;
      }

      _clearPendingSeek();
      _currentStreamUrl = null;
      _invalidateLoadedSource(reason: 'play_song_started');
      _invalidateSeekRequests();
      _clearStreamContext();
      _clearForcedNext();
      _isHandlingCompletion = false;
      _completionHandlingSongId = null;
      _lastPolledPlayerPosition = Duration.zero;
      _stagnantPositionTicks = 0;
      _lastStagnantLogTick = -1;
      _lastIgnoredSyntheticPositionLogTick = -1;
      _syntheticPositionFallbackActive = false;
      _loggedDurationUnavailableForSong = false;

      // 如果歌曲有时长信息，先预设 duration（转码流可能无法获取时长）
      final initialDuration = song.duration != null
          ? Duration(seconds: song.duration!)
          : Duration.zero;

      state = state.copyWith(
        currentSong: song,
        queue: playQueue,
        currentIndex: playIndex,
        position: Duration.zero,
        duration: initialDuration, // 使用歌曲元数据的时长
        currentBitRateKbps: 0,
      );

      // 换队列/换歌即触发预探测（非阻塞）：尽早标记后续坏源歌曲。
      // 即使当前首曲播放失败、未走到"播放成功"的预探测点，
      // 也能提前把接下来几首的坏源标记为跳过（覆盖所有播放链路的兜底）。
      unawaited(_probeUpcoming());

      // 更新通知栏媒体信息
      _updateMediaItem(song);
      _scheduleSongRemoteRefresh(song, debugSession);

      // 获取当前音质设置
      final effectiveQuality = _ref.read(effectiveQualityProvider);

      // 2. 流式播放
      final String? transcodeFormat = _needsTranscoding(song.suffix);
      final int? maxBitRate;
      if (transcodeFormat != null) {
        // 需要转码时：原始音质不限制码率，其它音质使用对应 maxBitRate。
        maxBitRate = effectiveQuality == AudioQualityLevel.original
            ? null
            : (effectiveQuality.maxBitRate ?? 320);
      } else if (effectiveQuality == AudioQualityLevel.original) {
        // 原始无损 — 不传 maxBitRate
        maxBitRate = null;
      } else {
        maxBitRate = effectiveQuality.maxBitRate;
      }
      final useServerTimeOffsetSeek = shouldUseServerTimeOffsetSeek(
        requestedFormat: transcodeFormat,
        requestedMaxBitRate: maxBitRate,
        sourceFormat: song.suffix,
        sourceBitRate: song.bitRate,
      );

      final activeAddress = await _ensureActiveAddressForPlayback(
        session: debugSession,
        reason: 'stream_playback',
      );
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession abandoned while waiting for active address '
          '(current=$_playDebugSession)',
        );
        return;
      }
      if (activeAddress == null) {
        _scheduleCurrentPlaybackRetry(
          song: song,
          isPreview: false,
          autoPlay: autoPlay,
        );
        NetworkErrorNotifier.show(l10nNowCurrent().provider_network_error_no_route);
        return;
      }

      final streamUrl = _buildStreamUrlOrThrow(
        song.id,
        session: debugSession,
        source: 'primary_stream',
        format: transcodeFormat,
        maxBitRate: maxBitRate,
      );
      final isAppleHttpStream =
          _isApplePlatform && streamUrl.startsWith('http://');
      _playDbg(
        'sid=$debugSession stream_resolved '
        'quality=${effectiveQuality.name} transcode=${transcodeFormat ?? 'none'} '
        'maxBitRate=${maxBitRate ?? 'none'} appleHttp=$isAppleHttpStream '
        'timeOffsetSeek=$useServerTimeOffsetSeek '
        'url=${_summarizeStreamUrl(streamUrl)}',
      );

      if (transcodeFormat != null) {
        Logger.info(
          'Transcoding ${song.suffix} to $transcodeFormat for: ${song.title}',
        );
      } else if (maxBitRate != null) {
        Logger.info(
          'Playing bitrate-limited stream (${song.suffix}) '
          'maxBitRate=$maxBitRate: ${song.title}',
        );
      } else {
        Logger.info(
          'Playing original format (${song.suffix}): ${song.title} '
          '[quality=${effectiveQuality.name}]',
        );
      }

      // 直接流式播放（已移除边播边缓存）
      try {
        _playDbg(
          'sid=$debugSession source=direct_stream setUrl='
          '${_summarizeStreamUrl(streamUrl)}',
        );
        final sourceReady = await _replaceLoadedSource(
          songId: song.id,
          label: 'direct_stream',
          ownsSource: () => _isPlaybackContextCurrent(
            session: debugSession,
            songId: song.id,
          ),
          setSource: (player) async {
            await player.setUrl(streamUrl);
          },
        );
        if (!sourceReady) return;
        _currentStreamUrl = streamUrl;
        _setStreamContext(
          songId: song.id,
          format: transcodeFormat,
          maxBitRate: maxBitRate,
          seekByReloadStream: useServerTimeOffsetSeek,
        );
        await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
        if (!isCurrentSession()) return;
        _seekDbg(
          'source=direct_stream quality=${effectiveQuality.name} '
          'format=${transcodeFormat ?? song.suffix}',
        );
      } catch (e) {
        Logger.warn('Direct stream failed: ${song.title}', e);
        rethrow;
      }

      await _applyPendingSeekIfNeeded();
      if (!isCurrentSession()) return;
      state = state.copyWith(
        currentQuality: effectiveQuality,
        playbackSource: PlaybackSource.stream,
        currentBitRateKbps: _resolveCurrentBitRateKbps(
          song: song,
          quality: effectiveQuality,
          source: PlaybackSource.stream,
          maxBitRate: maxBitRate,
        ),
      );

      if (!isCurrentSession()) return;
      _clearCurrentPlaybackRetry(reason: 'playback_ready_stream');

      // 上报"正在播放"
      if (autoPlay) {
        await _scrobble(song.id, submission: false);
        if (!isCurrentSession()) return;
      }

      Logger.info('Playing: ${song.title}');
      _seekDbg(
        'playSong ready song=${song.id} currentPos=${_audioPlayer?.position} '
        'duration=${state.duration}',
      );
      _playDbg(
        'sid=$debugSession playSong ready '
        'playerPos=${_audioPlayer?.position} '
        'buffered=${_audioPlayer?.bufferedPosition} '
        'duration=${_audioPlayer?.duration} '
        'stream=${_summarizeStreamUrl(_currentStreamUrl)}',
      );

      // 预探测接下来可能播放的歌曲是否可用（与主项目前端 probeUpcoming 一致）
      if (autoPlay) {
        unawaited(_probeUpcoming());
      }
    } catch (e) {
      Logger.error('Failed to play song', e);
      _seekDbg('playSong failed song=${song.id} err=$e');

      // 如果在重试前用户已切歌（新的 playSong 被调用），放弃本次重试
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession abandoned (current=$_playDebugSession), '
          'skip transcoding retry',
        );
        return;
      }

      final hasAvailableRoute = await _refreshRoutesAndCheckAvailability();
      if (!hasAvailableRoute) {
        _scheduleCurrentPlaybackRetry(
          song: song,
          isPreview: false,
          autoPlay: autoPlay,
        );
        NetworkErrorNotifier.show(l10nNowCurrent().provider_network_error_no_route);
        return;
      }

      // 路由刷新后再次检查会话
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession abandoned after route refresh '
          '(current=$_playDebugSession)',
        );
        return;
      }

      // 如果播放失败且没有转码过，尝试转码播放
      if (_needsTranscoding(song.suffix) == null) {
        Logger.info('Original format failed, retrying with MP3 transcoding');
        await _playWithTranscoding(
          song,
          queue: queue,
          index: index,
          debugSession: debugSession,
          autoPlay: autoPlay,
        );
        // 转码路径内部自行处理成功/失败（失败会走 _handlePlaybackError 跳下一首）。
        return;
      }

      // 已尝试转码仍失败（或音源加载阶段就失败、本就不走转码）：
      // 自动跳到下一首，避免"播放失败后卡在第一首"（对齐主项目前端
      // localHandlePlaybackError；连续失败达 _maxFailStreak 会停止并提示）。
      _handlePlaybackError(song.id);
    }
  }

  /// 使用转码方式播放（降级方案）
  Future<void> _playWithTranscoding(
    Song song, {
    List<Song>? queue,
    int? index,
    int? debugSession,
    bool autoPlay = true,
  }) async {
    // 会话已被更新的 playSong 取代，放弃本次转码重试
    final sid = debugSession ?? _playDebugSession;
    bool isCurrentSession() =>
        _isPlaybackContextCurrent(session: sid, songId: song.id);
    if (debugSession != null && _playDebugSession != debugSession) {
      _playDbg(
        'sid=$sid transcoding retry abandoned '
        '(current=$_playDebugSession)',
      );
      return;
    }

    try {
      final streamUrl = _buildStreamUrlOrThrow(
        song.id,
        session: sid,
        source: 'transcoding_retry',
        format: 'mp3', // 转码为 MP3
        maxBitRate: 320,
      );
      final useServerTimeOffsetSeek = shouldUseServerTimeOffsetSeek(
        requestedFormat: 'mp3',
        requestedMaxBitRate: 320,
        sourceFormat: song.suffix,
        sourceBitRate: song.bitRate,
      );
      final isAppleHttpStream =
          _isApplePlatform && streamUrl.startsWith('http://');

      Logger.info('Retrying with MP3 transcoding: ${song.title}');
      _playDbg(
        'sid=${debugSession ?? _playDebugSession} transcoding retry '
        'song=${song.id} appleHttp=$isAppleHttpStream '
        'url=${_summarizeStreamUrl(streamUrl)}',
      );

      try {
        _playDbg(
          'sid=${debugSession ?? _playDebugSession} '
          'source=direct_stream_transcoding setUrl='
          '${_summarizeStreamUrl(streamUrl)}',
        );
        // 在实际设置音源前再次检查会话
        if (debugSession != null && _playDebugSession != debugSession) {
          _playDbg(
            'sid=$sid transcoding setUrl abandoned '
            '(current=$_playDebugSession)',
          );
          return;
        }
        final sourceReady = await _replaceLoadedSource(
          songId: song.id,
          label: 'direct_stream_transcoding',
          ownsSource: () =>
              _isPlaybackContextCurrent(session: sid, songId: song.id),
          setSource: (player) async {
            await player.setUrl(streamUrl);
          },
        );
        if (!sourceReady) return;
        _currentStreamUrl = streamUrl;
        _setStreamContext(
          songId: song.id,
          format: 'mp3',
          maxBitRate: 320,
          seekByReloadStream: useServerTimeOffsetSeek,
        );
        await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
        if (!isCurrentSession()) return;
        _seekDbg('source=direct_stream_transcoding mp3 song=${song.id}');
      } catch (e) {
        _playDbg(
          'sid=${debugSession ?? _playDebugSession} '
          'source=direct_stream_transcoding setUrl failed err=$e',
        );
        rethrow;
      }

      // 转码设置音源完成后再次检查会话
      if (debugSession != null && _playDebugSession != debugSession) {
        _playDbg(
          'sid=$sid transcoding post-setup abandoned '
          '(current=$_playDebugSession)',
        );
        return;
      }
      await _applyPendingSeekIfNeeded();
      if (!isCurrentSession()) return;
      final effectiveQuality = _ref.read(effectiveQualityProvider);
      state = state.copyWith(
        currentQuality: effectiveQuality,
        playbackSource: PlaybackSource.stream,
        currentBitRateKbps: _resolveCurrentBitRateKbps(
          song: song,
          quality: effectiveQuality,
          source: PlaybackSource.stream,
          maxBitRate: 320,
        ),
      );
      _clearCurrentPlaybackRetry(reason: 'playback_ready_transcoding');

      // 上报"正在播放"
      if (autoPlay) {
        await _scrobble(song.id, submission: false);
        if (!isCurrentSession()) return;
      }
    } catch (e) {
      Logger.error('Failed to play song even with transcoding', e);
      final hasAvailableRoute = await _refreshRoutesAndCheckAvailability();
      if (debugSession != null && _playDebugSession != debugSession) {
        _playDbg(
          'sid=$sid transcoding retry abandoned after route refresh '
          '(current=$_playDebugSession)',
        );
        return;
      }
      if (!hasAvailableRoute) {
        _scheduleCurrentPlaybackRetry(
          song: song,
          isPreview: false,
          autoPlay: autoPlay,
        );
        NetworkErrorNotifier.show(l10nNowCurrent().provider_network_error_no_route);
        return;
      }
      // 有可用线路但转码仍失败 → 自动跳到下一首，避免"卡在第一首"。
      // （对齐主项目前端 localHandlePlaybackError；连续失败会继续向前跳过，
      //  仅整队不可播时才停止并提示。）
      _handlePlaybackError(song.id);
    }
  }

  /// 判断格式是否需要强制转码
  /// 返回 null 表示直接使用原始格式，返回格式字符串表示需要转码
  String? _needsTranscoding(String? suffix) {
    if (suffix == null) return null;

    final lowerSuffix = suffix.toLowerCase();

    // macOS/iOS 原生支持 m4a/alac（AVFoundation/CoreAudio），无需转码
    // 所有平台都不支持的格式
    const universallyUnsupported = [
      'ape', // Monkey's Audio
      'wv', // WavPack
      'tta', // True Audio
      'dff', // DSD
      'dsf', // DSD
      'tak', // TAK
    ];

    if (universallyUnsupported.contains(lowerSuffix)) {
      return 'mp3';
    }

    // Android 上 m4a/alac 支持不完整，需要转码
    if (!_isApplePlatform) {
      const androidUnsupported = [
        'm4a', // 可能包含 ALAC 编码，Android 支持不完整
        'alac', // Apple Lossless
      ];
      if (androidUnsupported.contains(lowerSuffix)) {
        return 'mp3';
      }
    }

    // 其他格式优先尝试原始格式播放
    // 支持的格式包括：mp3, aac, flac, ogg, opus, wav 等
    return null;
  }

  int _normalizeBitRateKbps(int? bitRate) {
    if (bitRate == null || bitRate <= 0) return 0;
    // 兼容个别场景可能传入 bps（例如 320000）。
    if (bitRate >= 10000) return bitRate ~/ 1000;
    return bitRate;
  }

  int _parseBitRateFromText(String? text) {
    if (text == null) return 0;
    final match = RegExp(
      r'(\d{2,4})\s*kbps',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return 0;
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  int _resolveCurrentBitRateKbps({
    required Song song,
    required AudioQualityLevel quality,
    required PlaybackSource source,
    int? maxBitRate,
  }) {
    final songBitRate = _normalizeBitRateKbps(song.bitRate);
    if (song.isPreview) {
      if (songBitRate > 0) return songBitRate;
      return _parseBitRateFromText(song.previewQualityLabel);
    }

    switch (source) {
      case PlaybackSource.stream:
        if (maxBitRate != null && maxBitRate > 0) return maxBitRate;
        if (quality != AudioQualityLevel.original &&
            quality.maxBitRate != null) {
          return quality.maxBitRate!;
        }
        return songBitRate;
    }
  }

  void _scheduleSongRemoteRefresh(Song song, int session) {
    unawaited(() async {
      final activeAddress = await _ensureActiveAddressForPlayback(
        session: session,
        reason: 'song_remote_refresh',
        logFailure: false,
      );
      if (activeAddress == null ||
          !mounted ||
          _playDebugSession != session ||
          state.currentSong?.id != song.id) {
        return;
      }
      _updateMediaItem(song);
      await _enrichSongMetadata(song.id, session);
    }());
  }

  ServerAddress? _syncImmediateActiveAddress({
    required int session,
    required String reason,
  }) {
    final pool = _ref.read(addressPoolProvider);
    final active = pool.activeAddress ?? _ref.read(activeAddressProvider);
    if (active == null) return null;

    final dio = _apiClient.dio;
    // 归一化去尾斜杠：getStreamUrl/getCoverArtUrl 手工拼接 baseUrl,带尾斜杠
    // 会拼出 '//rest/stream'（服务端返回 200 + SPA HTML → 一首都放不了）。
    final normalized = normalizeServerBaseUrl(active.url);
    if (dio.options.baseUrl != normalized) {
      dio.options.baseUrl = normalized;
      Logger.infoWithTag('API', 'switched base URL to: $normalized');
    }
    _playDbg(
      'sid=$session active_address_ready '
      'reason=$reason label=${active.label} url=${active.url}',
    );
    return active;
  }

  Future<ServerAddress?> _ensureActiveAddressForPlayback({
    required int session,
    required String reason,
    bool logFailure = true,
  }) async {
    final immediate = _syncImmediateActiveAddress(
      session: session,
      reason: reason,
    );
    if (immediate != null) return immediate;

    _playDbg('sid=$session active_address_wait start reason=$reason');
    try {
      final ensured = await _ref.read(ensureActiveAddressProvider.future);
      final dio = _apiClient.dio;
      final normalizedEnsured = normalizeServerBaseUrl(ensured.url);
      if (dio.options.baseUrl != normalizedEnsured) {
        dio.options.baseUrl = normalizedEnsured;
        Logger.infoWithTag('API', 'switched base URL to: $normalizedEnsured');
      }
      _playDbg(
        'sid=$session active_address_ready '
        'reason=$reason label=${ensured.label} url=${ensured.url}',
      );
      return ensured;
    } catch (e) {
      if (logFailure) {
        Logger.warnWithTag(
          _playerLogTag,
          'failed to ensure active address for $reason',
          e,
        );
      }
      _playDbg(
        'sid=$session active_address_wait failed '
        'reason=$reason err=$e',
      );
      return null;
    }
  }

  String _buildStreamUrlOrThrow(
    String songId, {
    required int session,
    required String source,
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) {
    final streamUrl = _apiClient.getStreamUrl(
      songId,
      maxBitRate: maxBitRate,
      format: format,
      timeOffset: timeOffset,
    );
    if (streamUrl.isEmpty) {
      final baseUrl = _apiClient.dio.options.baseUrl;
      _playDbg(
        'sid=$session $source stream_url_empty '
        'baseUrl=${baseUrl.isEmpty ? 'none' : baseUrl}',
      );
      throw StateError('No active server address available for stream URL');
    }
    return streamUrl;
  }

  /// 更新通知栏媒体信息
  void _updateMediaItem(Song song) {
    if (_audioHandler == null) return;

    final previewCover = song.previewCoverUrl?.trim();
    final coverArtUrl =
        song.isPreview && previewCover != null && previewCover.isNotEmpty
        ? previewCover
        : (song.coverArt != null
              ? _apiClient.getCoverArtUrl(song.coverArt!, size: 300)
              : null);
    final safeCoverArtUrl = coverArtUrl?.trim();

    final mediaItem = MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist ?? 'Unknown Artist',
      album: song.album ?? 'Unknown Album',
      duration: song.duration != null
          ? Duration(seconds: song.duration!)
          : null,
      artUri: safeCoverArtUrl != null && safeCoverArtUrl.isNotEmpty
          ? Uri.parse(safeCoverArtUrl)
          : null,
    );

    _audioHandler?.updateMediaItem(mediaItem);
  }

  /// 投屏/直投期间，用投屏进度驱动系统播控中心（通知/锁屏进度条）。
  /// 本机此时已暂停、位置不再自增，若不喂给播控中心其进度会定住在投屏那一刻。
  void updateNotificationCastProgress({
    required bool active,
    required bool playing,
    required Duration position,
  }) {
    _audioHandler?.setCastProgress(
      active: active,
      playing: playing,
      position: position,
    );
  }

  /// 异步补充歌曲元数据（格式/码率/位深/采样率/声道数），不阻塞播放流程。
  Future<void> _enrichSongMetadata(String songId, int session) async {
    try {
      final fullSong = await _musicRepository.getSong(songId);
      if (fullSong == null) return;
      // 会话已切换 → 丢弃
      if (!mounted || _playDebugSession != session) return;
      final current = state.currentSong;
      if (current == null || current.id != songId) return;
      // 仅在缺失时补充
      final needsUpdate =
          current.suffix == null ||
          current.bitRate == null ||
          current.bitDepth == null ||
          current.samplingRate == null ||
          current.channelCount == null;
      if (!needsUpdate) return;
      final enriched = current.copyWith(
        suffix: current.suffix ?? fullSong.suffix,
        bitRate: current.bitRate ?? fullSong.bitRate,
        bitDepth: current.bitDepth ?? fullSong.bitDepth,
        samplingRate: current.samplingRate ?? fullSong.samplingRate,
        channelCount: current.channelCount ?? fullSong.channelCount,
      );
      if (mounted && state.currentSong?.id == songId) {
        state = state.copyWith(currentSong: enriched);
        // 同步更新队列中的歌曲对象
        final idx = state.currentIndex;
        if (idx >= 0 &&
            idx < state.queue.length &&
            state.queue[idx].id == songId) {
          final updatedQueue = List<Song>.from(state.queue);
          updatedQueue[idx] = enriched;
          state = state.copyWith(queue: updatedQueue);
        }
        if (_currentStreamSongId == songId &&
            _sourcePositionOffset == Duration.zero) {
          final useServerTimeOffsetSeek = shouldUseServerTimeOffsetSeek(
            requestedFormat: _currentStreamFormat,
            requestedMaxBitRate: _currentStreamMaxBitRate,
            sourceFormat: enriched.suffix,
            sourceBitRate: enriched.bitRate,
          );
          if (useServerTimeOffsetSeek != _seekByReloadStream) {
            _seekByReloadStream = useServerTimeOffsetSeek;
            _seekDbg(
              'updated timeOffset seek after metadata refresh '
              'song=$songId bitRate=${enriched.bitRate} '
              'maxBitRate=$_currentStreamMaxBitRate '
              'enabled=$useServerTimeOffsetSeek',
            );
          }
        }
      }
    } catch (e) {
      Logger.debug('Failed to enrich song metadata for $songId: $e');
    }
  }

  /// 启动播放但不阻塞当前流程。
  /// just_audio 的 play() Future 会在暂停/结束时才完成，不能在切歌流程里 await。
  void _startPlayback({bool fadeIn = true}) {
    final player = _audioPlayer;
    if (player == null) return;
    final songId = state.currentSong?.id;
    unawaited(
      player.play().catchError((error) {
        Logger.warn('Failed to start playback', error);
        _handlePlaybackError(songId);
      }),
    );
    if (fadeIn) {
      _fadeIn();
    }
  }

  /// 播放失败自动跳过：与主项目前端 localHandlePlaybackError 一致。
  /// 连续失败过多时**不再硬停**，而是把失败歌曲记入死歌集合继续向前跳过，
  /// 直到找到可播歌曲；仅当整队都已确认不可播时才停止并提示，
  /// 避免"随机歌单/平台歌单连续坏源"时客户端卡在暂停。
  void _handlePlaybackError(String? songId) {
    if (!mounted) return;
    _failStreak++;
    // 把本次失败歌曲记入死歌集合：后续队列项直接跳过，不反复尝试。
    if (songId != null && songId.isNotEmpty) {
      _markSongDead(songId);
    }
    Logger.warnWithTag(
      _playerLogTag,
      'play fail (${_failStreak}/$_maxFailStreak) songId=$songId, auto-skip',
    );
    // 整队都已确认不可播：停止并提示，避免整队坏源时无限跳过。
    final queue = state.queue;
    if (queue.isNotEmpty && queue.every((s) => _deadSongs.contains(s.id))) {
      Logger.warnWithTag(_playerLogTag, 'whole queue unplayable, stop auto-skip');
      _failStreak = 0;
      state = state.copyWith(isPlaying: false);
      // 给用户可见反馈，避免"点了播放没反应"的假象（Windows 排查关键）。
      NetworkErrorNotifier.show(
        l10nNowCurrent().provider_playback_all_unavailable,
      );
      return;
    }
    if (_failStreak >= _maxFailStreak) {
      // 连续失败过多：重置计数并继续向前跳过（长段坏源时不再中途停住）。
      Logger.warnWithTag(_playerLogTag, 'too many consecutive failures, continue skipping forward');
      _failStreak = 0;
    }
    next();
  }

  /// 把歌曲标记为已确认不可播（与预探测结果共用 _deadSongs 集合，带上限）。
  void _markSongDead(String songId) {
    if (_probeCache.length >= _probeCacheMaxEntries) {
      _probeCache.clear();
      _deadSongs.clear();
    }
    _probeCache[songId] = false;
    if (_deadSongs.length >= _deadSongsMaxEntries) {
      _deadSongs.clear();
    }
    _deadSongs.add(songId);
  }

  /// 预探测接下来可能播放的歌曲是否可用（与主项目前端 probeUpcoming 一致）。
  /// 后端 POST /rest/api/v1/stream/probe 对本地歌曲零开销,
  /// 对 web 歌曲做 Range 探测并自动换源写回 DB；不可用的歌提前标记跳过。
  Future<void> _probeUpcoming() async {
    if (_probing || state.queue.isEmpty) return;
    final queue = state.queue;
    final currentIndex = state.currentIndex;
    final cands = <String>[];

    // 远程歌(未入库,走 /rest/stream-remote)跳过预探测:后端 probe 按 DB songId
    // 判可用性,远程歌不入库,后端没有该 songId 会误判为不可播(对齐主项目前端
    // probeUpcoming 的 !s.streamUrl 排除)。试听歌同理不走 probe。
    bool isRemoteSong(Song s) => s.isPreview || s.id.startsWith('remote:');

    // 收集接下来 _probeWindow 首未探测过的非远程歌曲 ID
    for (var i = 1; i <= _probeWindow; i++) {
      final idx = currentIndex + i;
      if (idx < queue.length) {
        final s = queue[idx];
        if (s.id.isNotEmpty &&
            !isRemoteSong(s) &&
            !_probeCache.containsKey(s.id)) {
          cands.add(s.id);
        }
      } else if (idx >= queue.length && state.loopMode != LoopMode.off) {
        // 循环模式下回绕
        final wrap = idx % queue.length;
        if (wrap != currentIndex) {
          final s = queue[wrap];
          if (s.id.isNotEmpty &&
              !isRemoteSong(s) &&
              !_probeCache.containsKey(s.id)) {
            cands.add(s.id);
          }
        }
      }
    }
    if (cands.isEmpty) return;

    _probing = true;
    try {
      final client = _apiClient;
      // 业务 API（非 OpenSubsonic）→ 必须用 postRaw，post 会按 subsonic-response
      // 解包返回 null，导致下面的 results['results'] 每次都抛错、预探测永不生效。
      final results = await client.postRaw(
        '/rest/api/v1/stream/probe',
        data: {'songIds': cands},
      );
      final items = (results is Map ? (results['results'] as List?) : null) ??
          const [];
      for (final r in items.whereType<Map>()) {
        final songId = (r['songId'] as String?) ?? '';
        if (songId.isEmpty) continue;
        final ok = r['ok'] == true;
        // 带上限：超限时整体重置（一次性清空），避免无界增长。
        if (_probeCache.length >= _probeCacheMaxEntries) {
          _probeCache.clear();
          _deadSongs.clear();
        }
        _probeCache[songId] = ok;
        if (!ok) {
          if (_deadSongs.length >= _deadSongsMaxEntries) {
            _deadSongs.clear();
          }
          _deadSongs.add(songId);
          Logger.warnWithTag(
            _playerLogTag,
            'pre-probe unplayable, skip ahead: $songId (${r['reason'] ?? 'no usable audio source'})',
          );
        } else {
          _deadSongs.remove(songId);
        }
      }
    } catch (e) {
      // 探测失败不阻塞播放：交给播放时的失败兜底
      Logger.debugWithTag(_playerLogTag, 'pre-probe failed: $e');
    } finally {
      _probing = false;
    }
  }

  Future<void> _syncPlaybackAfterSourceReady({required bool autoPlay}) async {
    if (autoPlay) {
      _startPlayback();
      return;
    }

    _cancelFade();
    await _audioPlayer?.pause();
    await _audioHandler?.pause();
    if (mounted && state.isPlaying) {
      state = state.copyWith(isPlaying: false);
    }
  }

  // ---------------------------------------------------------------------------
  // 淡入淡出
  // ---------------------------------------------------------------------------

  /// 取消正在进行的淡入淡出动画并将音量恢复为用户设置值（state.volume）。
  void _cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final completer = _fadeCompleter;
    _fadeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _audioPlayer?.setVolume(state.volume);
  }

  /// 淡出当前正在播放的歌曲。
  /// 如果用户未启用淡入淡出或当前未在播放，则立即返回。
  Future<void> _fadeOut(int session) async {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) return;
    final player = _audioPlayer;
    if (player == null || !player.playing) return;

    // 淡出只使用一半时长，另一半留给淡入
    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    // 从用户设置音量淡出到 0（不覆盖用户音量）
    final volumeStep = state.volume / steps;
    var currentVolume = state.volume;

    _playDbg('sid=$session fadeOut start durationMs=$fadeMs steps=$steps');

    final completer = Completer<void>();
    _fadeCompleter = completer;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      // 会话已变（用户快速切歌）→ 立即中止
      if (_playDebugSession != session) {
        timer.cancel();
        _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        player.setVolume(0.0);
        if (!completer.isCompleted) completer.complete();
        return;
      }
      currentVolume = (currentVolume - volumeStep).clamp(0.0, 1.0);
      player.setVolume(currentVolume);
      if (currentVolume <= 0.0) {
        timer.cancel();
        _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        _playDbg('sid=$session fadeOut complete');
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  /// 淡入新歌曲：从 0.0 渐变到用户设置音量（state.volume）
  void _fadeIn() {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) {
      _audioPlayer?.setVolume(state.volume);
      return;
    }
    final player = _audioPlayer;
    if (player == null) return;

    // 淡入使用另一半时长
    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    final volumeStep = state.volume / steps;
    var currentVolume = 0.0;
    player.setVolume(0.0);

    final session = _playDebugSession;
    _playDbg('sid=$session fadeIn start durationMs=$fadeMs steps=$steps');

    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      if (_playDebugSession != session) {
        timer.cancel();
        _fadeTimer = null;
        player.setVolume(state.volume);
        return;
      }
      currentVolume = (currentVolume + volumeStep).clamp(0.0, state.volume);
      player.setVolume(currentVolume);
      if (currentVolume >= state.volume) {
        timer.cancel();
        _fadeTimer = null;
        _playDbg('sid=$session fadeIn complete');
      }
    });
  }

  /// 播放队列
  ///
  /// [shuffleRandomStart] 为 true 且当前处于随机模式时，随机挑选一首作为
  /// 「洗牌后的列表」第一首，而不是固定从队列原顺序第 0 首开始。仅用于
  /// 「播放整个歌单/列表」的从头播放语义；显式点了某首（调用方传入具体
  /// index 而非该标记）则保持「点哪首播哪首」。
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
  }) async {
    if (songs.isEmpty) return;
    var effectiveIndex = startIndex;
    if (shuffleRandomStart && state.shuffleEnabled && songs.length > 1) {
      // 打乱后的列表第一首 = 从全部曲目中随机挑一个索引，语义与主项目
      // shuffle 模式的随机起点一致；同曲不因随机起点而跳过。
      effectiveIndex = _random.nextInt(songs.length);
    }
    effectiveIndex = effectiveIndex.clamp(0, songs.length - 1);
    await playSong(
      songs[effectiveIndex],
      queue: songs,
      index: effectiveIndex,
    );
  }
  /// 播放试听歌曲。
  Future<void> playPreviewSong(Song song) async {
    await playSong(song);
  }

  Future<void> _playPreviewSongInternal(
    Song song, {
    required List<Song> queue,
    required int index,
    bool autoPlay = true,
  }) async {
    final debugSession = ++_playDebugSession;
    _transportRequestGeneration += 1;
    bool isCurrentSession() =>
        _isPlaybackContextCurrent(session: debugSession, songId: song.id);
    _clearCurrentPlaybackRetry(
      reason: 'play_preview_started',
      preserveRetrying: _retryingCurrentPlayback,
    );

    late final Song resolvedSong;
    try {
      resolvedSong = await _resolvePreviewSongForPlayback(song);
    } catch (e) {
      Logger.error('Failed to resolve preview song', e);
      if (_playDebugSession == debugSession) {
        // 试听链接解析失败 → 记入死歌并在当前试听队列内自动跳下一首。
        // 注意:此处 state 尚未切换到本试听队列,不能走 _handlePlaybackError
        // (它的 next() 会推进旧队列),只能在本队列内就地跳转。
        _markSongDead(song.id);
        final nextIdx = index + 1;
        if (nextIdx < queue.length) {
          await playSong(
            queue[nextIdx],
            queue: queue,
            index: nextIdx,
            autoPlay: autoPlay,
          );
        } else {
          NetworkErrorNotifier.show(l10nNowCurrent().provider_preview_link_parse_failed);
        }
      }
      return;
    }
    if (_playDebugSession != debugSession) return;

    final streamUrl = resolvedSong.previewStreamUrl?.trim() ?? '';
    final previewHeaders = resolvedSong.previewRequestHeaders;
    final previewQueue = resolvePreviewPlaybackQueue(
      queue: queue,
      preferredIndex: index,
      unresolvedSong: song,
      resolvedSong: resolvedSong,
    );
    final playQueue = previewQueue.queue;
    final playIndex = previewQueue.index;

    if (!autoPlay) {
      _cancelFade();
      await _audioPlayer?.pause();
      await _audioHandler?.pause();
      if (_playDebugSession != debugSession) return;
    }

    _clearPendingSeek();
    _currentStreamUrl = null;
    _invalidateLoadedSource(reason: 'play_preview_started');
    _invalidateSeekRequests();
    _clearStreamContext();
    _clearForcedNext();
    _isHandlingCompletion = false;
    _completionHandlingSongId = null;
    _lastPolledPlayerPosition = Duration.zero;
    _stagnantPositionTicks = 0;
    _lastStagnantLogTick = -1;
    _lastIgnoredSyntheticPositionLogTick = -1;
    _syntheticPositionFallbackActive = false;
    _loggedDurationUnavailableForSong = false;

    final initialDuration = resolvedSong.duration != null
        ? Duration(seconds: resolvedSong.duration!)
        : Duration.zero;

    state = state.copyWith(
      currentSong: resolvedSong,
      queue: playQueue,
      currentIndex: playIndex,
      position: Duration.zero,
      duration: initialDuration,
      currentBitRateKbps: 0,
    );

    _updateMediaItem(resolvedSong);

    try {
      _playDbg(
        'sid=$debugSession preview setUrl song=${resolvedSong.id} '
        'queue=${playQueue.length} index=$playIndex '
        'url=${_summarizeStreamUrl(streamUrl)} '
        'headers=${previewHeaders.keys.join(",")}',
      );
      final sourceReady = await _replaceLoadedSource(
        songId: resolvedSong.id,
        label: 'preview',
        ownsSource: () => _isPlaybackContextCurrent(
          session: debugSession,
          songId: resolvedSong.id,
        ),
        setSource: (player) async {
          await player.setUrl(streamUrl, headers: previewHeaders);
        },
      );
      if (!sourceReady) return;
      _currentStreamUrl = streamUrl;
      _setStreamContext(
        songId: resolvedSong.id,
        format: null,
        maxBitRate: null,
        seekByReloadStream: false,
      );
      await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
      if (!isCurrentSession()) return;
      await _applyPendingSeekIfNeeded();
      if (!isCurrentSession()) return;
      state = state.copyWith(
        currentQuality: AudioQualityLevel.original,
        playbackSource: PlaybackSource.stream,
        currentBitRateKbps: _resolveCurrentBitRateKbps(
          song: resolvedSong,
          quality: AudioQualityLevel.original,
          source: PlaybackSource.stream,
          maxBitRate: _normalizeBitRateKbps(resolvedSong.bitRate),
        ),
      );
      _clearCurrentPlaybackRetry(reason: 'playback_ready_preview');
    } catch (e) {
      Logger.error('Failed to play preview song', e);
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession preview abandoned after failure '
          '(current=$_playDebugSession)',
        );
        return;
      }
      final hasAvailableRoute = await _refreshRoutesAndCheckAvailability();
      if (_playDebugSession != debugSession) {
        _playDbg(
          'sid=$debugSession preview abandoned after route refresh '
          '(current=$_playDebugSession)',
        );
        return;
      }
      if (!hasAvailableRoute) {
        _scheduleCurrentPlaybackRetry(
          song: resolvedSong,
          isPreview: true,
          autoPlay: autoPlay,
        );
        NetworkErrorNotifier.show(l10nNowCurrent().provider_preview_play_no_route);
        return;
      }
      // 有可用线路但试听仍失败 → 自动跳到下一首，避免"卡在试听首曲"。
      // （对齐本机链路 localHandlePlaybackError；连续失败会继续向前跳过，
      //  仅整队不可播时才停止并提示。）
      _handlePlaybackError(resolvedSong.id);
    }
  }

  /// 试听歌曲可以先作为普通队列项加入；真正轮到播放时再补齐临时 URL。
  ///
  /// 注意：临时签名 URL（网易/QQ 等）通常分钟级就过期，**不能跨进程复用**。
  /// 会话恢复（_isRestoringPlaybackSession）时为上次进程内下发的 URL 早已失效，
  /// 必须强制重新解析一次；只有同进程内正在播放（未经过重启）才可复用已有 URL。
  Future<Song> _resolvePreviewSongForPlayback(Song song) async {
    final existingUrl = song.previewStreamUrl?.trim() ?? '';
    if (existingUrl.isNotEmpty && !_isRestoringPlaybackSession) return song;

    final source = song.previewSource?.trim() ?? '';
    final trackId = song.previewTrackId?.trim() ?? '';
    // 恢复进程内旧临时 URL 已过期：若可重新解析则强制重解析；缺 source/trackId
    // 无法重解析时退回既有 URL（尽力而为，避免把会话恢复成死歌）。
    if (_isRestoringPlaybackSession && source.isNotEmpty && trackId.isNotEmpty) {
      // fallthrough 到下方 resolveSongUrl
    } else if (existingUrl.isNotEmpty) {
      return song;
    }
    if (source.isEmpty || trackId.isEmpty) {
      throw StateError('preview song missing source/trackId');
    }

    final client = _ref.read(gdMusicApiClientProvider);
    final resolved = await client.resolveSongUrl(
      source: source,
      trackId: trackId,
    );

    var coverUrl = song.previewCoverUrl?.trim();
    final picId = song.previewPicId?.trim() ?? '';
    if ((coverUrl == null || coverUrl.isEmpty) && picId.isNotEmpty) {
      coverUrl = await client.resolveCoverUrl(source: source, picId: picId);
    }

    return song.copyWith(
      previewStreamUrl: resolved.url,
      previewCoverUrl: coverUrl,
      previewQualityLabel: resolved.qualityLabel,
      previewRequestHeaders: resolved.requiredHeaders,
      bitRate: resolved.bitRateKbps,
      suffix: resolved.suffix ?? song.suffix,
    );
  }

  /// 播放/暂停
  Future<void> togglePlayPause() async {
    if (state.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// 设置本机播放音量（0.0~1.0，对齐主项目前端 setVolume）。
  /// 立即作用于 just_audio，持久化改为**延迟批量**写入（防抖），
  /// 避免滑杆松手时同步 IO / 平台通道写入阻塞 UI（Windows 上会假死数秒）。
  /// 会话周期（_persistPlaybackSession）也会顺带落盘音量，双保险兜底。
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0).toDouble();
    if (mounted) {
      state = state.copyWith(volume: clamped);
    }
    _audioPlayer?.setVolume(clamped);
    _schedulePersistVolume();
  }

  /// 音量持久化防抖：松手后 1s 内没有新的调整才真正落盘。
  void _schedulePersistVolume() {
    _volumePersistTimer?.cancel();
    _volumePersistTimer = Timer(const Duration(seconds: 1), () async {
      _volumePersistTimer = null;
      try {
        await LocalStorage.setPlayerVolume(state.volume);
      } catch (e) {
        Logger.warnWithTag(
          _playerLogTag,
          'failed to persist player volume: ${state.volume}',
          e,
        );
      }
    });
  }

  /// 拖动音量滑块时的实时跟随：只改状态与播放器音量，**不落盘**。
  /// 避免每次 onChanged 都写 SharedPreferences 造成卡顿/窗口假死；
  /// 松手时由 [setVolume] 统一持久化。
  void setVolumeLive(double volume) {
    final clamped = volume.clamp(0.0, 1.0).toDouble();
    if (mounted) {
      state = state.copyWith(volume: clamped);
    }
    _audioPlayer?.setVolume(clamped);
  }

  /// 启动时恢复本机音量（默认 0.8）。
  Future<void> _restorePlayerVolume() async {
    try {
      final saved = await LocalStorage.getPlayerVolume();
      // 不能加 `if (!mounted) return;`：桌面端 SharedPreferences 读取极快，
      // 常在第一个 widget 订阅前就完成，此时 mounted=false 会导致音量永远
      // 停在默认 1.0（每次重开都是 100%）。StateNotifier 在无监听者时赋值
      // 同样安全，后续监听者会拿到最新 state。
      state = state.copyWith(volume: saved);
      _audioPlayer?.setVolume(saved);
      Logger.infoWithTag(
        _playerLogTag,
        'restored player volume: $saved',
      );
    } catch (e) {
      Logger.warnWithTag(_playerLogTag, 'failed to restore player volume', e);
    }
  }

  /// 暂停（带淡出）
  Future<void> pause() async {
    final playbackSession = _playDebugSession;
    final transportRequest = ++_transportRequestGeneration;
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs > 0 && state.isPlaying) {
      await _fadeOutForPause();
      if (_playDebugSession != playbackSession ||
          _transportRequestGeneration != transportRequest) {
        return;
      }
    }
    // 用户主动暂停：清除「期望自动播放」意图，避免 0 秒卡死看门狗
    // 把停在起点的暂停歌曲误判为卡死而去重载/自动播放。
    _expectingAutoplay = false;
    await _audioPlayer?.pause();
    if (_playDebugSession != playbackSession ||
        _transportRequestGeneration != transportRequest) {
      return;
    }
    await _audioHandler?.pause();
  }

  /// 播放（从暂停恢复，不使用淡入——淡入淡出仅用于切歌）
  Future<void> play() {
    _transportRequestGeneration += 1;
    _cancelFade(); // 取消任何进行中的淡入淡出，恢复音量到 1.0
    _startPlayback(fadeIn: false);
    return Future<void>.value();
  }

  /// 暂停前的淡出：音量降到 0 后返回，由 pause() 执行实际暂停。
  Future<void> _fadeOutForPause() async {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) return;
    final player = _audioPlayer;
    if (player == null || !player.playing) return;

    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    // 从用户设置音量淡出到 0（暂停后 play() 恢复用户音量）
    final volumeStep = state.volume / steps;
    var currentVolume = state.volume;

    final completer = Completer<void>();
    _fadeCompleter = completer;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      currentVolume = (currentVolume - volumeStep).clamp(0.0, state.volume);
      player.setVolume(currentVolume);
      if (currentVolume <= 0.0) {
        timer.cancel();
        _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  /// 上一首
  Future<void> previous() async {
    if (!state.hasPrevious) return;

    _clearForcedNext();

    if (state.shuffleEnabled) {
      final historyIndex = _takeLastValidBackHistoryIndex();
      final previousIndex = historyIndex ?? _getQueuePreviousIndex();
      if (previousIndex == null) return;

      if (historyIndex != null) {
        final currentEntry = _currentShuffleEntry(
          queue: state.queue,
          song: state.currentSong,
          index: state.currentIndex,
        );
        if (currentEntry != null) {
          _pushShuffleEntry(_shuffleForwardHistory, currentEntry);
        }
      } else {
        _shuffleForwardHistory.clear();
      }
      _syncShuffleHistoryState();
      final previousSong = state.queue[previousIndex];
      await playSong(
        previousSong,
        queue: state.queue,
        index: previousIndex,
        recordShuffleHistory: false,
        clearShuffleForwardHistory: false,
      );
      return;
    }

    final previousIndex = _getQueuePreviousIndex();
    if (previousIndex == null) return;
    final previousSong = state.queue[previousIndex];
    await playSong(previousSong, queue: state.queue, index: previousIndex);
  }

  /// 下一首
  Future<void> next() async {
    if (!state.hasNext) return;

    if (state.shuffleEnabled) {
      final forcedIndex = _resolveForcedNextIndex();
      if (forcedIndex != null) {
        final forcedSong = state.queue[forcedIndex];
        _clearForcedNext();
        await playSong(
          forcedSong,
          queue: state.queue,
          index: forcedIndex,
          recordShuffleHistory: true,
          clearShuffleForwardHistory: true,
        );
        return;
      }
      _clearForcedNext();
      final forwardIndex = _takeLastValidForwardHistoryIndex();
      if (forwardIndex != null) {
        final currentEntry = _currentShuffleEntry(
          queue: state.queue,
          song: state.currentSong,
          index: state.currentIndex,
        );
        if (currentEntry != null) {
          _pushShuffleEntry(_shuffleBackHistory, currentEntry);
        }
        _syncShuffleHistoryState();
        final forwardSong = state.queue[forwardIndex];
        await playSong(
          forwardSong,
          queue: state.queue,
          index: forwardIndex,
          recordShuffleHistory: false,
          clearShuffleForwardHistory: false,
        );
        return;
      }
      final nextIndex = _getRandomIndexExcludingCurrent();
      if (nextIndex == null) return;
      final nextSong = state.queue[nextIndex];
      await playSong(
        nextSong,
        queue: state.queue,
        index: nextIndex,
        recordShuffleHistory: true,
        clearShuffleForwardHistory: true,
      );
      return;
    }

    final nextIndex = state.currentIndex + 1;
    if (nextIndex < state.queue.length) {
      final nextSong = state.queue[nextIndex];
      await playSong(nextSong, queue: state.queue, index: nextIndex);
      return;
    }

    // 回绕到首曲（单曲队列时等同于重播当前曲目）。
    if (state.queue.isNotEmpty) {
      await skipToQueueItem(0);
    }
  }

  /// 投屏时镜像**后端权威队列**到本地(不触发本地播放,本地在投屏期间保持暂停)。
  /// 迷你条/全屏/歌词/队列面板都读取 playerProvider,因此整队镜像让 UI 跟随设备
  /// 当前播放(对齐主项目前端:远端队列以后端快照为准,前端只镜像展示)。
  void syncQueueForCast(List<Map<String, dynamic>> items, int index) {
    if (!mounted) return;
    final songs = <Song>[];
    for (final it in items) {
      songs.add(castQueueItemToSong(it));
    }
    if (songs.isEmpty) return;
    final safeIndex = index.clamp(0, songs.length - 1);
    final current = songs[safeIndex];
    final queueChanged = state.queue.length != songs.length ||
        (state.queue.isNotEmpty &&
            (state.queue.first.id != songs.first.id ||
                state.queue.last.id != songs.last.id));
    if (!queueChanged &&
        current.id == state.currentSong?.id &&
        safeIndex == state.currentIndex) {
      return;
    }
    state = state.copyWith(
      queue: songs,
      currentIndex: safeIndex,
      currentSong: current,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
    );
    // 投屏切歌后刷新系统播控中心的曲目信息（标题/艺人/封面），
    // 否则通知栏/锁屏会一直停留在直投开始的那一首。
    _updateMediaItem(current);
  }

  /// 回本机时恢复离开前保存的本地播放状态(见 CastPeerController.backToLocal)。
  /// 本机 just_audio 在离开时仅 pause(未卸载);恢复 currentSong 后如需续播
  /// 调用 [play] 直接 resume 当前加载源。
  void restoreStateForCast({
    required List<Song> queue,
    required int currentIndex,
    required Song? currentSong,
    required Duration position,
    required LoopMode loopMode,
    required bool shuffleEnabled,
    required bool isPlaying,
  }) {
    if (!mounted) return;
    final restoredIndex = currentIndex.clamp(
      -1,
      queue.isEmpty ? -1 : queue.length - 1,
    );
    final restoredSong =
        restoredIndex >= 0 && restoredIndex < queue.length
            ? queue[restoredIndex]
            : currentSong;
    state = state.copyWith(
      queue: queue,
      currentIndex: restoredIndex,
      currentSong: restoredSong,
      position: position,
      loopMode: loopMode,
      shuffleEnabled: shuffleEnabled,
      isPlaying: isPlaying,
    );
    if (isPlaying) {
      _startPlayback(fadeIn: false);
    }
  }

  /// 计算投屏模式下「下一首/上一首」的目标索引（按队列顺序并回绕）。
  /// 返回 null 表示队列为空或没有可切换目标。
  int? resolveCastNeighborIndex({required bool forward}) {
    final queue = state.queue;
    if (queue.isEmpty) return null;
    if (queue.length == 1) return state.currentIndex;
    final current = state.currentIndex.clamp(0, queue.length - 1);
    return forward
        ? (current + 1) % queue.length
        : (current - 1 + queue.length) % queue.length;
  }

  /// 跳转到指定位置
  Future<void> seek(Duration position) async {
    final player = _audioPlayer;
    final currentSongId = state.currentSong?.id;
    if (player == null || currentSongId == null) return;

    final seekGeneration = ++_seekRequestGeneration;
    final playbackSession = _playDebugSession;
    bool isCurrentSeek() => _isSeekRequestCurrent(
      seekGeneration: seekGeneration,
      playbackSession: playbackSession,
      songId: currentSongId,
    );
    bool ownsSource() => _isPlaybackContextCurrent(
      session: playbackSession,
      songId: currentSongId,
    );
    final target = _normalizeSeekPosition(position);
    final canSeekNow = canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    );
    _seekDbg(
      'seek request song=$currentSongId target=$target '
      'playerPos=${player.position} state=${player.processingState.name} '
      'canSeekNow=$canSeekNow loadedSource=$_loadedSourceSongId',
    );

    if (!canSeekNow) {
      _pendingSeekSongId = currentSongId;
      _pendingSeekPosition = target;
      _seekDbg('seek queued pendingSong=$_pendingSeekSongId pending=$target');
      if (mounted) {
        state = state.copyWith(position: target);
      }
      return;
    }

    _activeSeekGeneration = seekGeneration;
    _activeSeekSongId = currentSongId;

    // 可立即 seek 时，先把 UI 锚定到目标位置，避免等待底层回调期间回退到旧进度。
    if (mounted) {
      state = state.copyWith(position: target);
    }

    _clearPendingSeek();
    try {
      await _seekWithFallback(
        target,
        songId: currentSongId,
        isCurrentSeek: isCurrentSeek,
        ownsSource: ownsSource,
      );
      if (isCurrentSeek() && mounted) {
        state = state.copyWith(position: target);
      }
    } finally {
      _releaseSeekAnchor(seekGeneration);
      _schedulePendingSeekIfReady();
    }
  }

  /// 跳转到队列中的指定歌曲
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;

    final song = state.queue[index];
    await playSong(song, queue: state.queue, index: index);
  }

  /// 设置循环模式
  Future<void> setLoopMode(LoopMode mode) async {
    await _audioPlayer?.setLoopMode(mode);
    if (mounted) {
      state = state.copyWith(loopMode: mode);
    }
    final modeToPersist = state.shuffleEnabled
        ? PlaybackMode.shuffle
        : (mode == LoopMode.one
              ? PlaybackMode.repeatOne
              : PlaybackMode.repeatAll);
    await _persistPlaybackMode(modeToPersist);
  }

  /// 切换循环模式
  Future<void> toggleLoopMode() async {
    final nextMode = switch (state.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await setLoopMode(nextMode);
  }

  /// 设置随机播放
  Future<void> setShuffleEnabled(bool enabled) async {
    await _audioPlayer?.setShuffleModeEnabled(enabled);
    _resetShuffleHistory(updateState: false);
    if (mounted) {
      state = state.copyWith(shuffleEnabled: enabled, shuffleHistoryCount: 0);
    }
    final modeToPersist = enabled
        ? PlaybackMode.shuffle
        : (state.loopMode == LoopMode.one
              ? PlaybackMode.repeatOne
              : PlaybackMode.repeatAll);
    await _persistPlaybackMode(modeToPersist);
  }

  /// 切换随机播放
  Future<void> toggleShuffle() async {
    await setShuffleEnabled(!state.shuffleEnabled);
  }

  /// 播放失败后刷新全部线路，确认是否存在可用线路
  Future<bool> _refreshRoutesAndCheckAvailability() async {
    try {
      final pool = _ref.read(addressPoolProvider);
      final active = await pool.probeAll();
      if (active?.status == ServerAddressStatus.ok) return true;
      return pool.addresses.any((a) => a.status == ServerAddressStatus.ok);
    } catch (e) {
      Logger.warn('Failed to refresh routes after playback error', e);
      return false;
    }
  }

  /// 当前播放模式（三态）
  PlaybackMode get playbackMode {
    if (state.shuffleEnabled) return PlaybackMode.shuffle;
    if (state.loopMode == LoopMode.one) return PlaybackMode.repeatOne;
    return PlaybackMode.repeatAll;
  }

  /// 设置三态播放模式
  Future<void> setPlaybackMode(PlaybackMode mode, {bool persist = true}) async {
    switch (mode) {
      case PlaybackMode.shuffle:
        // 队列是手动切歌而非播放器内建列表。
        // 在随机模式使用 LoopMode.off，避免底层播放器自动重放当前单曲。
        await _audioPlayer?.setLoopMode(LoopMode.off);
        await _audioPlayer?.setShuffleModeEnabled(true);
        _resetShuffleHistory(updateState: false);
        if (mounted) {
          state = state.copyWith(
            loopMode: LoopMode.off,
            shuffleEnabled: true,
            shuffleHistoryCount: 0,
          );
        }
        break;
      case PlaybackMode.repeatAll:
        // 队列切歌由外层状态机驱动，Repeat All 用 LoopMode.off
        // 避免底层播放器在单音源下自动回放当前曲目。
        await _audioPlayer?.setShuffleModeEnabled(false);
        await _audioPlayer?.setLoopMode(LoopMode.off);
        _resetShuffleHistory(updateState: false);
        if (mounted) {
          state = state.copyWith(
            loopMode: LoopMode.off,
            shuffleEnabled: false,
            shuffleHistoryCount: 0,
          );
        }
        break;
      case PlaybackMode.repeatOne:
        await _audioPlayer?.setShuffleModeEnabled(false);
        await _audioPlayer?.setLoopMode(LoopMode.one);
        _resetShuffleHistory(updateState: false);
        if (mounted) {
          state = state.copyWith(
            loopMode: LoopMode.one,
            shuffleEnabled: false,
            shuffleHistoryCount: 0,
          );
        }
        break;
    }

    if (persist) {
      await _persistPlaybackMode(mode);
    }
  }

  /// 循环切换三态播放模式：
  /// 随机 -> 列表循环 -> 单曲循环 -> 随机
  Future<void> cyclePlaybackMode() async {
    final nextMode = switch (playbackMode) {
      PlaybackMode.shuffle => PlaybackMode.repeatAll,
      PlaybackMode.repeatAll => PlaybackMode.repeatOne,
      PlaybackMode.repeatOne => PlaybackMode.shuffle,
    };
    await setPlaybackMode(nextMode);
  }

  Future<void> _restorePlaybackMode() async {
    try {
      final storedMode = await LocalStorage.getPlaybackMode();
      final mode = PlaybackMode.values.firstWhere(
        (item) => item.name == storedMode,
        orElse: () => PlaybackMode.repeatAll,
      );
      await setPlaybackMode(mode, persist: false);
      Logger.infoWithTag(_playerLogTag, 'playback mode restored: ${mode.name}');
    } catch (e) {
      Logger.warnWithTag(_playerLogTag, 'failed to restore playback mode', e);
    }
  }

  Future<void> _persistPlaybackMode(PlaybackMode mode) async {
    try {
      await LocalStorage.setPlaybackMode(mode.name);
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to persist playback mode: ${mode.name}',
        e,
      );
    }
  }

  void _schedulePersistPlaybackSession({bool immediate = false}) {
    if (!mounted || _isRestoringPlaybackSession) return;

    if (immediate) {
      _playbackSessionPersistTimer?.cancel();
      _playbackSessionPersistTimer = null;
      unawaited(_persistPlaybackSession());
      return;
    }

    if (_playbackSessionPersistTimer != null) return;
    _playbackSessionPersistTimer = Timer(_playbackSessionPersistInterval, () {
      _playbackSessionPersistTimer = null;
      unawaited(_persistPlaybackSession());
    });
  }

  /// 序列化队列，队列未变化时复用上次结果（避免每次落盘都全量 toJson 整队，
  /// 那是大屏旋转封面"定时卡顿"的周期性主线程分配源）。
  List<Map<String, dynamic>> _serializedQueuePayload(List<Song> queue) {
    final ids = queue.map((song) => song.id).toList(growable: false);
    final cached = _cachedQueueIds;
    var unchanged = cached.length == ids.length;
    if (unchanged) {
      for (var i = 0; i < ids.length; i++) {
        if (cached[i] != ids[i]) {
          unchanged = false;
          break;
        }
      }
    }
    if (unchanged) return _cachedQueuePayload;
    _cachedQueueIds = ids;
    _cachedQueuePayload =
        queue.map((song) => song.toJson()).toList(growable: false);
    return _cachedQueuePayload;
  }

  Map<String, dynamic>? _buildPlaybackSessionPayload() {
    final queue = state.queue;
    if (queue.isEmpty) return null;

    var currentIndex = state.currentIndex;
    final currentSongId = state.currentSong?.id;
    final hasCurrentIndex = currentIndex >= 0 && currentIndex < queue.length;

    if (currentSongId != null &&
        (!hasCurrentIndex || queue[currentIndex].id != currentSongId)) {
      final resolvedIndex = queue.indexWhere(
        (song) => song.id == currentSongId,
      );
      if (resolvedIndex >= 0) {
        currentIndex = resolvedIndex;
      }
    }

    if (currentIndex < 0 || currentIndex >= queue.length) return null;

    final normalizedPosition = _normalizeSeekPosition(state.position);
    return {
      'version': 1,
      'queue': _serializedQueuePayload(queue),
      'currentIndex': currentIndex,
      'currentSongId': queue[currentIndex].id,
      'positionMs': normalizedPosition.inMilliseconds,
      'isPlaying': state.isPlaying,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<void> _persistPlaybackSession() async {
    // 关闭(dispose)时 mounted 已为 false,但不能因此跳过落盘 —— 否则退出瞬间
    // 刚更新的进度/歌曲就会丢,重开无法续播。只在「恢复会话进行中」与「正在写」
    // 时跳过,其余情况(含关闭)都照常保存。
    if (_isRestoringPlaybackSession || _isPersistingPlaybackSession) {
      return;
    }

    _isPersistingPlaybackSession = true;
    try {
      final payload = _buildPlaybackSessionPayload();
      if (payload == null) {
        await LocalStorage.clearPlaybackSession();
        return;
      }
      Logger.debugWithTag(
        _playerLogTag,
        'persist session currentSongId=${payload['currentSongId']} '
        'index=${payload['currentIndex']} '
        'posMs=${payload['positionMs']} isPlaying=${payload['isPlaying']} '
        'queueLen=${(payload['queue'] as List).length} '
        'updatedAt=${payload['updatedAt']}',
      );
      await LocalStorage.savePlaybackSession(payload);
      // 顺带持久化音量：随会话周期反复落盘，即使滑块松手那次写入丢失，
      // 下次周期也会补上，避免「直接退出客户端后音量回到 100%」。
      await LocalStorage.setPlayerVolume(state.volume);
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to persist playback session',
        e,
      );
    } finally {
      _isPersistingPlaybackSession = false;
    }
  }

  Future<void> _restorePlaybackSession() async {
    if (!mounted) return;
    var restored = false;
    _isRestoringPlaybackSession = true;

    try {
      final session = await LocalStorage.getPlaybackSession();
      if (session == null) return;

      final queue = _parsePlaybackSessionQueue(session['queue']);
      if (queue.isEmpty) {
        await LocalStorage.clearPlaybackSession();
        return;
      }

      final preferredIndex = _parseStoredInt(session['currentIndex']) ?? 0;
      final currentSongId = session['currentSongId']?.toString();
      final restoredIndex = _resolveRestoredQueueIndex(
        queue: queue,
        preferredIndex: preferredIndex,
        currentSongId: currentSongId,
      );
      final storedPositionMs = _parseStoredInt(session['positionMs']) ?? 0;
      final restoredPosition = Duration(milliseconds: max(0, storedPositionMs));
      final wasPlaying = session['isPlaying'] == true;
      Logger.infoWithTag(
        _playerLogTag,
        'restoring playback session queue=${queue.length} '
        'index=$restoredIndex posMs=${restoredPosition.inMilliseconds} '
        'wasPlaying=$wasPlaying',
      );
      // 诊断：打印恢复队列的实际歌曲(用于定位"每次都恢复成固定试听歌")。
      Logger.infoWithTag(
        _playerLogTag,
        'session queue ids=${queue.map((s) => s.id).toList()} '
        'titles=${queue.map((s) => s.title).toList()} '
        'previewFlags=${queue.map((s) => s.isPreview).toList()} '
        'storedCurrentSongId=$currentSongId storedIndex=$preferredIndex '
        'sessionUpdatedAt=${session['updatedAt']}',
      );
      await playSong(
        queue[restoredIndex],
        queue: queue,
        index: restoredIndex,
        autoPlay: false,
      );
      if (restoredPosition > Duration.zero) {
        await seek(restoredPosition);
      }
      // 恢复即续播:是否自动播放**只由设置「打开时自动播放」决定**(默认关闭)。
      // 关闭时只恢复队列与进度、停在暂停态,不因关闭前在播就擅自起播;
      // 开启时才在恢复后自动续播。旧逻辑 `wasPlaying || autoPlayOnLaunch`
      // 会让关闭前在播的应用无论如何都自动续播,违背用户设置意图。
      final autoResume = await LocalStorage.getAutoPlayOnLaunch();
      if (autoResume) {
        await play();
      } else {
        await pause();
      }

      Logger.infoWithTag(_playerLogTag, 'playback session restored');
      restored = true;
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'failed to restore playback session',
        e,
      );
    } finally {
      _isRestoringPlaybackSession = false;
    }

    if (restored) {
      _schedulePersistPlaybackSession(immediate: true);
    }
  }

  List<Song> _parsePlaybackSessionQueue(Object? rawQueue) {
    if (rawQueue is! List) return const [];

    final queue = <Song>[];
    for (final item in rawQueue) {
      try {
        if (item is Map<String, dynamic>) {
          queue.add(Song.fromJson(item));
          continue;
        }
        if (item is Map) {
          final mapped = item.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          queue.add(Song.fromJson(mapped));
        }
      } catch (e) {
        Logger.warnWithTag(
          _playerLogTag,
          'skip invalid song in playback session',
          e,
        );
      }
    }
    return queue;
  }

  int? _parseStoredInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  int _resolveRestoredQueueIndex({
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

  void _syncShuffleHistoryBeforeSongChange({
    required Song nextSong,
    required List<Song> nextQueue,
    required int nextIndex,
    required bool recordHistory,
    required bool clearForwardHistory,
  }) {
    if (!state.shuffleEnabled) {
      _resetShuffleHistory(updateState: false);
      _syncShuffleHistoryState();
      return;
    }

    if (!_isSameQueueBySongId(state.queue, nextQueue)) {
      _resetShuffleHistory(updateState: false);
      _syncShuffleHistoryState();
      return;
    }

    // 随机模式:记录本轮已播放的歌曲(同一轮内不重复,播完一轮才重新洗牌)。
    if (nextSong.id.isNotEmpty) {
      _shuffleRoundPlayedIds.add(nextSong.id);
    }

    if (recordHistory) {
      final currentEntry = _currentShuffleEntry(
        queue: state.queue,
        song: state.currentSong,
        index: state.currentIndex,
      );
      if (currentEntry != null) {
        final isDifferentTrack =
            currentEntry.songId != nextSong.id ||
            currentEntry.preferredIndex != nextIndex;
        if (isDifferentTrack) {
          _pushShuffleEntry(_shuffleBackHistory, currentEntry);
        }
      }
    }

    if (clearForwardHistory) {
      _shuffleForwardHistory.clear();
    }

    _syncShuffleHistoryState();
  }

  ShuffleHistoryEntry? _currentShuffleEntry({
    required List<Song> queue,
    required Song? song,
    required int index,
  }) {
    if (song == null || queue.isEmpty) return null;

    if (index >= 0 && index < queue.length && queue[index].id == song.id) {
      return ShuffleHistoryEntry(songId: song.id, preferredIndex: index);
    }

    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id == song.id) {
        return ShuffleHistoryEntry(songId: song.id, preferredIndex: i);
      }
    }
    return null;
  }

  bool _isSameQueueBySongId(List<Song> currentQueue, List<Song> nextQueue) {
    if (identical(currentQueue, nextQueue)) return true;
    if (currentQueue.length != nextQueue.length) return false;

    for (var i = 0; i < currentQueue.length; i++) {
      if (currentQueue[i].id != nextQueue[i].id) {
        return false;
      }
    }
    return true;
  }

  void _pushShuffleEntry(
    List<ShuffleHistoryEntry> stack,
    ShuffleHistoryEntry entry,
  ) {
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

  int? _resolveShuffleEntryIndex(ShuffleHistoryEntry entry) {
    final queue = state.queue;
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

  int? _takeLastValidHistoryIndex(List<ShuffleHistoryEntry> stack) {
    while (stack.isNotEmpty) {
      final entry = stack.removeLast();
      final resolvedIndex = _resolveShuffleEntryIndex(entry);
      if (resolvedIndex != null) {
        return resolvedIndex;
      }
    }
    return null;
  }

  int? _takeLastValidBackHistoryIndex() {
    return _takeLastValidHistoryIndex(_shuffleBackHistory);
  }

  int? _takeLastValidForwardHistoryIndex() {
    return _takeLastValidHistoryIndex(_shuffleForwardHistory);
  }

  void _resetShuffleHistory({bool updateState = true}) {
    _shuffleBackHistory.clear();
    _shuffleForwardHistory.clear();
    _shuffleRoundPlayedIds.clear();
    if (updateState) {
      _syncShuffleHistoryState();
    }
  }

  void _syncShuffleHistoryState() {
    if (!mounted) return;
    final historyCount = _shuffleBackHistory.length;
    if (state.shuffleHistoryCount == historyCount) return;
    state = state.copyWith(shuffleHistoryCount: historyCount);
  }

  int? _getQueuePreviousIndex() {
    final queue = state.queue;
    if (queue.isEmpty) return null;
    if (queue.length == 1) return 0;

    final currentIndex = state.currentIndex;
    if (currentIndex <= 0) return queue.length - 1;
    if (currentIndex >= queue.length) return queue.length - 1;
    return currentIndex - 1;
  }

  int? _getRandomIndexExcludingCurrent() {
    final queue = state.queue;
    if (queue.isEmpty) return null;
    if (queue.length == 1) return 0;

    final currentIndex = state.currentIndex;
    final currentSongId = state.currentSong?.id;

    final nonDuplicateCandidates = <int>[];
    final fallbackCandidates = <int>[];
    final unplayedCandidates = <int>[];

    for (var i = 0; i < queue.length; i++) {
      if (i == currentIndex) continue;
      fallbackCandidates.add(i);
      if (!_shuffleRoundPlayedIds.contains(queue[i].id)) {
        unplayedCandidates.add(i);
      }
      if (currentSongId == null || queue[i].id != currentSongId) {
        nonDuplicateCandidates.add(i);
      }
    }

    // 主项目随机语义对齐:优先取「本轮未播过」的歌;本轮已播完(全部播过)则
    // 清空本轮标记重新洗牌,且避开当前曲(不立刻重播)。
    var candidates = unplayedCandidates;
    if (candidates.isEmpty && nonDuplicateCandidates.isNotEmpty) {
      _shuffleRoundPlayedIds.clear();
      candidates = nonDuplicateCandidates;
    }
    if (candidates.isEmpty) {
      candidates = fallbackCandidates;
    }
    if (candidates.isEmpty) return null;

    return candidates[_random.nextInt(candidates.length)];
  }

  int? _resolveForcedNextIndex() {
    final forcedSongId = _forcedNextSongId;
    if (forcedSongId == null) return null;

    final queue = state.queue;
    final currentIndex = state.currentIndex;

    bool isMatch(int index) {
      return index >= 0 &&
          index < queue.length &&
          index != currentIndex &&
          queue[index].id == forcedSongId;
    }

    final preferredIndex = _forcedNextIndex;
    if (preferredIndex != null && isMatch(preferredIndex)) {
      return preferredIndex;
    }

    for (var i = currentIndex + 1; i < queue.length; i++) {
      if (isMatch(i)) return i;
    }

    for (var i = 0; i < queue.length; i++) {
      if (isMatch(i)) return i;
    }
    return null;
  }

  void _clearForcedNext() {
    _forcedNextSongId = null;
    _forcedNextIndex = null;
  }

  /// 添加到队列末尾
  void addToQueue(Song song) {
    final newQueue = [...state.queue, song];
    state = state.copyWith(queue: newQueue);
  }

  /// 添加多首到队列
  void addAllToQueue(List<Song> songs) {
    final newQueue = [...state.queue, ...songs];
    state = state.copyWith(queue: newQueue);
  }

  /// 添加到下一曲位置
  Future<void> playNext(Song song) async {
    if (state.queue.isEmpty || state.currentSong == null) {
      await playSong(song, queue: [song], index: 0);
      return;
    }

    final newQueue = [...state.queue];
    final insertIndex = (state.currentIndex + 1).clamp(0, newQueue.length);
    newQueue.insert(insertIndex, song);
    state = state.copyWith(queue: newQueue);
    _forcedNextSongId = song.id;
    _forcedNextIndex = insertIndex;
  }

  /// 清空队列
  Future<void> clearQueue() async {
    _clearForcedNext();
    _resetShuffleHistory(updateState: false);

    final currentSong = state.currentSong;
    if (currentSong != null) {
      // 保留当前正在播放/暂停的歌曲，仅清空后续队列。
      state = state.copyWith(
        queue: [currentSong],
        currentIndex: 0,
        shuffleHistoryCount: 0,
      );
      return;
    }

    await _audioPlayer?.stop();
    await _audioHandler?.stop();
    _invalidateLoadedSource(reason: 'queue_cleared');
    _invalidateSeekRequests();
    state = state.copyWith(
      currentSong: null,
      queue: const [],
      currentIndex: 0,
      shuffleHistoryCount: 0,
      isPlaying: false,
      processingState: ProcessingState.idle,
      position: Duration.zero,
      duration: Duration.zero,
      currentQuality: null,
      playbackSource: null,
      currentBitRateKbps: 0,
    );
  }

  /// 从队列移除
  void removeFromQueue(int index) {
    if (index < 0 || index >= state.queue.length) return;

    _clearForcedNext();
    _resetShuffleHistory(updateState: false);

    final newQueue = [...state.queue];
    newQueue.removeAt(index);

    // 如果移除的是当前播放的歌曲
    if (index == state.currentIndex) {
      // 停止播放
      _audioPlayer?.stop();
      _audioHandler?.stop();
      _invalidateLoadedSource(reason: 'current_queue_item_removed');
      _invalidateSeekRequests();
      state = state.copyWith(
        queue: newQueue,
        currentSong: null,
        currentIndex: 0,
        shuffleHistoryCount: 0,
        currentBitRateKbps: 0,
      );
    } else {
      // 调整当前索引
      final newIndex = index < state.currentIndex
          ? state.currentIndex - 1
          : state.currentIndex;
      state = state.copyWith(
        queue: newQueue,
        currentIndex: newIndex,
        shuffleHistoryCount: 0,
      );
    }
  }

  /// 歌曲播放完成
  Future<void> _onSongCompleted(String completedSongId) async {
    if (state.currentSong?.id != completedSongId) return;

    // 定时停止「播完整首再关闭」本机链路：到点后等当前曲播完，曲毕即在此
    // 暂停并结束定时，不再自动切到下一首（避免与定时暂停冲突）。
    final sleepNotifier = _ref.read(sleepTimerProvider.notifier);
    if (sleepNotifier.finishingCurrentTrack) {
      unawaited(sleepNotifier.finishAtTrackEndNow());
      return;
    }

    // 不阻塞切歌流程，避免完成态停留过久导致竞态。
    if (state.currentSong?.isPreview != true) {
      unawaited(_scrobble(completedSongId, submission: true));
    }

    // 随机模式优先：从队列中随机到下一首，不走 loopMode 分支。
    if (state.shuffleEnabled) {
      if (state.queue.isNotEmpty) {
        _seekDbg('completed -> shuffle next song=$completedSongId');
        await next();
      }
      return;
    }

    // 根据循环模式决定下一步
    if (state.loopMode == LoopMode.one) {
      // 单曲循环
      _seekDbg('completed -> repeat one song=$completedSongId');
      await seek(Duration.zero);
      if (state.currentSong?.id == completedSongId) {
        _startPlayback(fadeIn: false);
      }
    } else if (state.hasNext) {
      // 播放下一首
      _seekDbg('completed -> sequential next song=$completedSongId');
      await next();
    }
  }

  /// 上报播放记录（Scrobble）
  Future<void> _scrobble(String songId, {required bool submission}) =>
      _favoriteHandler.scrobble(songId, submission: submission);

  /// 切换当前歌曲的收藏状态
  Future<void> toggleFavorite() async {
    final currentSong = state.currentSong;
    if (currentSong == null) return;
    await toggleSongFavorite(currentSong);
  }

  /// 切换指定歌曲的收藏状态
  Future<bool?> toggleSongFavorite(Song song) async {
    final newStarred = await _favoriteHandler.toggleSongFavorite(
      song: song,
      currentSong: state.currentSong,
      queue: state.queue,
    );
    if (newStarred == null) return null;

    final updatedQueue = _favoriteHandler.updateQueueStarred(
      state.queue,
      song.id,
      newStarred,
    );
    final currentSong = state.currentSong;
    final updatedCurrentSong = currentSong != null && currentSong.id == song.id
        ? currentSong.copyWith(starred: newStarred)
        : currentSong;

    state = state.copyWith(
      currentSong: updatedCurrentSong,
      queue: updatedQueue,
    );
    _favoriteHandler.invalidateFavoriteProviders(albumId: song.albumId);
    return newStarred;
  }

  Future<void> refreshSongMetadata(String songId) async {
    if (songId.trim().isEmpty) return;

    try {
      final fullSong = await _musicRepository.getSong(songId);
      if (fullSong == null) return;

      final currentSong = state.currentSong;
      final updatedQueue = List<Song>.from(state.queue);
      var queueChanged = false;
      for (var i = 0; i < updatedQueue.length; i++) {
        if (updatedQueue[i].id != songId) continue;
        updatedQueue[i] = fullSong;
        queueChanged = true;
      }

      if (currentSong != null && currentSong.id == songId) {
        state = state.copyWith(
          currentSong: fullSong,
          queue: queueChanged ? updatedQueue : state.queue,
        );
        _updateMediaItem(fullSong);
        return;
      }

      if (queueChanged) {
        state = state.copyWith(queue: updatedQueue);
      }
    } catch (e) {
      Logger.warnWithTag(_playerLogTag, 'failed to refresh song metadata', e);
    }
  }

  Duration _normalizeSeekPosition(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    final duration = state.duration;
    if (duration > Duration.zero && position > duration) {
      return duration;
    }
    return position;
  }

  Future<void> _applyPendingSeekIfNeeded() async {
    if (_isApplyingPendingSeek) return;

    final player = _audioPlayer;
    final pending = _pendingSeekPosition;
    final pendingSongId = _pendingSeekSongId;
    final currentSongId = state.currentSong?.id;
    if (player == null ||
        pending == null ||
        pendingSongId == null ||
        currentSongId == null) {
      return;
    }
    if (pendingSongId != currentSongId) return;

    final canSeekNow = canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    );
    if (!canSeekNow) return;

    _isApplyingPendingSeek = true;
    final seekGeneration = ++_seekRequestGeneration;
    final playbackSession = _playDebugSession;
    bool isCurrentSeek() => _isSeekRequestCurrent(
      seekGeneration: seekGeneration,
      playbackSession: playbackSession,
      songId: currentSongId,
    );
    bool ownsSource() => _isPlaybackContextCurrent(
      session: playbackSession,
      songId: currentSongId,
    );
    final target = _normalizeSeekPosition(pending);
    _activeSeekGeneration = seekGeneration;
    _activeSeekSongId = currentSongId;
    _seekDbg(
      'applyPendingSeek song=$currentSongId target=$target '
      'playerPos=${player.position} state=${player.processingState.name}',
    );
    _clearPendingSeek();
    try {
      await _seekWithFallback(
        target,
        songId: currentSongId,
        isCurrentSeek: isCurrentSeek,
        ownsSource: ownsSource,
      );
      if (isCurrentSeek() && mounted) {
        state = state.copyWith(position: target);
      }
    } finally {
      _releaseSeekAnchor(seekGeneration);
      _isApplyingPendingSeek = false;
      _schedulePendingSeekIfReady();
    }
  }

  Future<void> _seekWithFallback(
    Duration target, {
    required String songId,
    required bool Function() isCurrentSeek,
    required bool Function() ownsSource,
  }) async {
    final player = _audioPlayer;
    if (player == null || !isCurrentSeek()) return;

    if (_seekByReloadStream &&
        _currentStreamSongId == songId &&
        _currentStreamUrl != null) {
      final shouldResume = player.playing;
      final seekTarget = TranscodedStreamSeekTarget.fromLogical(target);
      final streamFormat = _currentStreamFormat;
      final streamMaxBitRate = _currentStreamMaxBitRate;
      final reloadUrl = _apiClient.getStreamUrl(
        songId,
        maxBitRate: streamMaxBitRate,
        format: streamFormat,
        timeOffset: seekTarget.serverOffset.inSeconds,
      );
      _seekDbg(
        'seek reload-stream song=$songId '
        'target=$target serverOffset=${seekTarget.serverOffset} '
        'sourcePosition=${seekTarget.sourcePosition} format=$streamFormat '
        'maxBitRate=$streamMaxBitRate wasPlaying=$shouldResume',
      );
      try {
        final sourceReady = await _replaceLoadedSource(
          songId: songId,
          label: 'seek_reload_stream',
          ownsSource: ownsSource,
          setSource: (sourcePlayer) async {
            await sourcePlayer.setUrl(
              reloadUrl,
              initialPosition: seekTarget.sourcePosition,
            );
          },
        );
        if (!sourceReady) return;
        _currentStreamUrl = reloadUrl;
        _setStreamContext(
          songId: songId,
          format: streamFormat,
          maxBitRate: streamMaxBitRate,
          seekByReloadStream: true,
          sourcePositionOffset: seekTarget.serverOffset,
        );
        if (!isCurrentSeek()) {
          _schedulePendingSeekIfReady();
          return;
        }
        if (mounted) {
          state = state.copyWith(position: target, bufferedPosition: target);
        }
        if (shouldResume) {
          _startPlayback(fadeIn: false);
        }
        await Future<void>.delayed(const Duration(milliseconds: 220));
        if (!isCurrentSeek()) return;
        final actualReload = _logicalPlayerPosition(player.position);
        final reloadDrift = (actualReload - target).inMilliseconds.abs();
        _seekDbg(
          'seek reload-stream verify target=$target '
          'sourceActual=${player.position} actual=$actualReload '
          'sourceOffset=$_sourcePositionOffset driftMs=$reloadDrift',
        );
        if (reloadDrift <= 2000) return;
        Logger.warn(
          'Reload-stream seek drift still high '
          '(target=$target, actual=$actualReload), retrying plain seek',
        );
        if (!isCurrentSeek()) return;
        await player.seek(seekTarget.sourcePosition);
        return;
      } catch (e) {
        if (!isCurrentSeek()) return;
        Logger.warn('Reload-stream seek failed, fallback to plain seek', e);
        await player.seek(_sourceSeekPosition(target));
        return;
      }
    }

    final sourceTarget = _sourceSeekPosition(target);
    _seekDbg(
      'seek execute target=$target sourceTarget=$sourceTarget '
      'sourceFrom=${player.position} '
      'from=${_logicalPlayerPosition(player.position)} '
      'sourceOffset=$_sourcePositionOffset '
      'state=${player.processingState.name}',
    );
    await player.seek(sourceTarget);
    if (!isCurrentSeek()) return;

    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!isCurrentSeek()) return;
    final actual = _logicalPlayerPosition(player.position);
    final drift = (actual - target).inMilliseconds.abs();
    _seekDbg(
      'seek verify target=$target sourceActual=${player.position} '
      'actual=$actual driftMs=$drift',
    );
    if (drift <= 2000) return;

    // 直连流/本地文件也做一次强制重试，规避解码器刚起播时的 seek 抖动。
    final shouldResume = player.playing;
    Logger.warn(
      'Seek drift detected on non-lock source (target=$target, actual=$actual), '
      'retrying seek',
    );
    if (shouldResume) {
      await player.pause();
      if (!isCurrentSeek()) return;
    }
    await player.seek(sourceTarget);
    if (!isCurrentSeek()) return;
    if (shouldResume) {
      _startPlayback(fadeIn: false);
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!isCurrentSeek()) return;
    _seekDbg('seek retry completed now=${player.position}');
  }

  void _clearPendingSeek() {
    if (_pendingSeekPosition != null || _pendingSeekSongId != null) {
      _seekDbg(
        'clearPendingSeek pending=$_pendingSeekPosition pendingSong=$_pendingSeekSongId',
      );
    }
    _pendingSeekPosition = null;
    _pendingSeekSongId = null;
  }

  void _setStreamContext({
    required String songId,
    required String? format,
    required int? maxBitRate,
    required bool seekByReloadStream,
    Duration sourcePositionOffset = Duration.zero,
  }) {
    _currentStreamSongId = songId;
    _currentStreamFormat = format;
    _currentStreamMaxBitRate = maxBitRate;
    _seekByReloadStream = seekByReloadStream;
    _setSourcePositionOffset(sourcePositionOffset);
  }

  void _clearStreamContext() {
    _currentStreamSongId = null;
    _currentStreamFormat = null;
    _currentStreamMaxBitRate = null;
    _seekByReloadStream = false;
    _setSourcePositionOffset(Duration.zero);
  }

  void _setSourcePositionOffset(Duration offset) {
    final normalized = offset < Duration.zero ? Duration.zero : offset;
    if (_sourcePositionOffset == normalized) return;
    _sourcePositionOffset = normalized;
    _audioHandler?.setPositionOffset(normalized);
    _seekDbg('source timeline offset updated: $normalized');
  }

  Duration _logicalPlayerPosition(Duration sourcePosition) {
    return addPlaybackPositionOffset(
      sourcePosition,
      _sourcePositionOffset,
      maximum: state.duration > Duration.zero ? state.duration : null,
    );
  }

  Duration _sourceSeekPosition(Duration logicalPosition) {
    final sourcePosition = logicalPosition - _sourcePositionOffset;
    return sourcePosition < Duration.zero ? Duration.zero : sourcePosition;
  }

  bool _isPlaybackContextCurrent({
    required int session,
    required String songId,
  }) {
    return _playDebugSession == session && state.currentSong?.id == songId;
  }

  void _invalidateLoadedSource({required String reason}) {
    _sourceGeneration += 1;
    _loadedSourceSongId = null;
    _playDbg('source invalidated generation=$_sourceGeneration reason=$reason');
  }

  Future<bool> _replaceLoadedSource({
    required String songId,
    required String label,
    required bool Function() ownsSource,
    required Future<void> Function(AudioPlayer player) setSource,
  }) async {
    final player = _audioPlayer;
    if (player == null || !ownsSource()) {
      _playDbg('source=$label setup abandoned before load song=$songId');
      return false;
    }

    final generation = ++_sourceGeneration;
    _loadedSourceSongId = null;
    _playDbg('source=$label load begin song=$songId generation=$generation');

    try {
      await setSource(player);
    } catch (_) {
      if (_sourceGeneration == generation) {
        _loadedSourceSongId = null;
      }
      rethrow;
    }

    if (_sourceGeneration != generation ||
        !ownsSource() ||
        player.audioSource == null) {
      _playDbg(
        'source=$label load abandoned song=$songId generation=$generation '
        'currentGeneration=$_sourceGeneration',
      );
      return false;
    }

    _loadedSourceSongId = songId;
    _playDbg('source=$label load ready song=$songId generation=$generation');
    return true;
  }

  void _invalidateSeekRequests() {
    _seekRequestGeneration += 1;
    _activeSeekGeneration = null;
    _activeSeekSongId = null;
  }

  bool _isSeekRequestCurrent({
    required int seekGeneration,
    required int playbackSession,
    required String songId,
  }) {
    return _seekRequestGeneration == seekGeneration &&
        _isPlaybackContextCurrent(session: playbackSession, songId: songId);
  }

  void _releaseSeekAnchor(int seekGeneration) {
    if (_activeSeekGeneration != seekGeneration) return;
    _activeSeekGeneration = null;
    _activeSeekSongId = null;
  }

  void _schedulePendingSeekIfReady() {
    if (!mounted || _isApplyingPendingSeek) return;
    final player = _audioPlayer;
    final currentSongId = state.currentSong?.id;
    if (player == null || currentSongId == null) return;
    if (!shouldPreservePendingSeekPosition(
      pendingPosition: _pendingSeekPosition,
      pendingSongId: _pendingSeekSongId,
      currentSongId: currentSongId,
    )) {
      return;
    }
    if (!canSeekLoadedPlayerSource(
      processingState: player.processingState,
      loadedSourceSongId: _loadedSourceSongId,
      currentSongId: currentSongId,
    )) {
      return;
    }
    unawaited(_applyPendingSeekIfNeeded());
  }

  bool _shouldPreserveSeekPosition() {
    final currentSongId = state.currentSong?.id;
    return shouldPreservePendingSeekPosition(
          pendingPosition: _pendingSeekPosition,
          pendingSongId: _pendingSeekSongId,
          currentSongId: currentSongId,
        ) ||
        (_activeSeekGeneration == _seekRequestGeneration &&
            _activeSeekSongId != null &&
            _activeSeekSongId == currentSongId);
  }

  void _startPositionPolling(AudioPlayer player) {
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (state.currentSong == null) return;
      if (_shouldPreserveSeekPosition()) {
        return;
      }

      final sourcePlayerPos = player.position;
      final playerPos = _logicalPlayerPosition(sourcePlayerPos);
      final processing = player.processingState;
      final isReadyPlaying =
          player.playing && processing == ProcessingState.ready;

      // 「确实在播」信号按平台归一化：
      // - 移动端维持 isReadyPlaying(仅 processing==ready 累计)，避免长期缓冲
      //   被误跳；这是原实现、不影响 Android/iOS。
      // - Windows(media_kit 后端)对 processing 判定更“粗”：撞容器比特末或长时间
      //   缓冲时会停留在 buffering 而非 ready，导致依赖 isReadyPlaying 的停滞
      //   看门狗计数被恒清零 → 失效。故 Windows 上改用 player.playing(播放意图，
      //   不会随 processing 变成 false) 作为停滞累计信号，与近末尾守卫同理。
      // 注意：仍保留 delta>150 才前进即重置，避免把 Windows 正常的粗粒度位置
      // 采样(每 500ms 报 150~300ms 前移)误当作停滞而误跳下一首。
      final isWinDesktop = !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.windows;
      final stallSignal = isWinDesktop ? player.playing : isReadyPlaying;

      final deltaFromLast = (sourcePlayerPos - _lastPolledPlayerPosition)
          .inMilliseconds
          .abs();
      // 0 秒卡死独立计数：播放意图存在但卡在起点(loading/buffering 或位置
      // 长期 <=0)且位置无进展时累计；一旦真的开始播/位置前进/暂停即清零。
      // just_audio 在 buffering/loading 时 player.playing 仍保持 true。
      // 播放意图 = playing 或「尚未真正开始播放但期望自动播放」(_expectingAutoplay)：
      // 源加载本身若挂起不返回,player.playing 恒为 false,仅凭 playing 会漏判。
      final atStart =
          sourcePlayerPos <= const Duration(milliseconds: 1500) ||
          state.position <= const Duration(milliseconds: 1500);
      final hasNoProgress = deltaFromLast <= 150 ||
          (processing == ProcessingState.loading ||
              processing == ProcessingState.buffering);
      final wantsPlaying = player.playing || _expectingAutoplay;
      // 合成进度兜底正在承担推进时(锁缓存流可能以 0 上报真实位置但音频在播),
      // 不把“定位在起点”当作 0 秒卡死,否则看门狗会重载一首正常在播的歌。
      // 已移除边播边缓存(LockCachingAudioSource)，不再需要对锁缓存流做
      // “位置报 0 但音频在播”的合成进度护航，相关分支恒为 false。
      final syntheticCarrying =
          _syntheticPositionFallbackActive &&
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50);
      if (wantsPlaying &&
          atStart &&
          hasNoProgress &&
          !syntheticCarrying &&
          !_shouldPreserveSeekPosition()) {
        _startupStuckTicks += 1;
      } else {
        _startupStuckTicks = 0;
      }
      // 一旦位置确有前进(迈出起点)，视为已恢复，清空期望意图标记与计数，
      // 避免后续看门狗仅凭旧标记误判。
      if (sourcePlayerPos > const Duration(milliseconds: 1500)) {
        _expectingAutoplay = false;
        // 真正开始播放：清零「连续重载」计数与标记，同曲后续再停滞从 1 重新计，
        // 不会因历史卡死而被立刻判死。
        if (_startupReloadStreak > 0 || _startupStuckSongId != null) {
          _startupReloadStreak = 0;
          _startupStuckSongId = null;
        }
      }
      // 仅「确实在播」状态累计停滞计数；暂停/缓冲/加载一律清零，
      // 否则暂停很久后恢复会因计数已越阈值而被看门狗误跳下一首。
      // (stallSignal 在 Windows 上为 player.playing、移动端为 isReadyPlaying)
      // 起点阶段(atStart)一律清零：0 秒卡死由 _startupStuckTicks 重载路径
      // 负责；若这里也累计,Windows 上加载/buffering 阶段(playing 仍 true)会
      // 提前攒到阈值,用「跳下一首」取代更温和的「重载自愈」+死歌判定。
      if (atStart) {
        _stagnantPositionTicks = 0;
      } else if (!stallSignal || deltaFromLast > 150) {
        _stagnantPositionTicks = 0;
      } else {
        _stagnantPositionTicks += 1;
      }

      // Windows 专项近末尾计数：不依赖 processing==ready(见字段注释)。
      // Windows 撞到容器 EOF 常把 processing 置于 buffering 而非 completed，
      // 通用计数随之被清零，导致看门狗对 Windows 末尾卡死失效。这里只要
      // 「确实在播 + 位置停在末段 2.5s 窗口内不再前进」就累计；暂停/前进/
      // 离开末段任一情况立即清零，避免误判。
      // 附加：另有部分容器与媒体后端在 EOF 处会把 playing 置 false、processing
      // 搁到 idle/其他 ≠completed，同样不上报 completed —— 此时 position 恰好
      // 到达/越过声明 duration。故「位置已到声明末尾」也计为「该结束了」，覆盖
      // 0秒/中途/近末尾三道看门狗(都要求 playing)原本都漏判的 Windows 场景。
      final inNearEndWindow =
          state.duration > const Duration(seconds: 3) &&
          state.duration - state.position <=
              const Duration(milliseconds: 2500);
      final endEngaged =
          inNearEndWindow &&
          (player.playing || state.position >= state.duration);
      if (endEngaged && deltaFromLast <= 150) {
        _nearEndStuckTicks += 1;
      } else {
        _nearEndStuckTicks = 0;
      }
      _lastPolledPlayerPosition = sourcePlayerPos;

      // 0 秒卡死兜底看门狗：播放意图存在但长时间(≥阈值)卡在起点
      // (loading/buffering 或位置长期 ≤0)且位置无进展时，重载当前曲目，
      // 等效于「切下一首再切回」——同一歌手动操作被确认能恢复播放。
      // 与 _stagnantPositionTicks 语义不同：后者仅在「就绪播放」累计，
      // 而 0 秒卡死恰恰发生在 loading/buffering 阶段(player.playing 仍 true)，
      // 若复用旧看门狗，该阶段计数会被恒清零、永不触发。
      if (_startupStuckTicks >= _startupStuckSkipThresholdTicks) {
        final stuckSong = state.currentSong;
        final startTicks = _startupStuckTicks;
        final stuckSongId = stuckSong?.id;
        _startupStuckTicks = 0;
        // 区分「瞬时挂起」(重载一次即恢复)与「真无可播源」(重载仍卡 0 秒):
        // 同一首连续达到重载容错上限仍无进展,判定为不可播,转入既有失败跳歌
        // 逻辑(_handlePlaybackError)标记死歌并跳下一首,而非无限重载同一首
        // 原地空转——若后端确无可播源,重载多少次都无济于事。
        if (stuckSongId != null && _startupStuckSongId == stuckSongId) {
          _startupReloadStreak += 1;
        } else {
          _startupStuckSongId = stuckSongId;
          _startupReloadStreak = 1;
        }
        if (stuckSongId != null &&
            _startupReloadStreak >= _startupReloadTolerance) {
          _playDbg(
            'startup_stuck_watchdog GIVE_UP reload_streak=$_startupReloadStreak '
            'song=$stuckSongId ticks=$startTicks sourcePlayerPos=$sourcePlayerPos '
            'processing=${processing.name} — judged unplayable, skip to next',
          );
          _startupStuckSongId = null;
          _startupReloadStreak = 0;
          _handlePlaybackError(stuckSongId);
          return;
        }
        _playDbg(
          'startup_stuck_watchdog reload song=$stuckSongId '
          'reload_streak=$_startupReloadStreak/$_startupReloadTolerance '
          'ticks=$startTicks sourcePlayerPos=$sourcePlayerPos '
          'statePos=${state.position} processing=${processing.name} '
          'playing=${player.playing}',
        );
        if (stuckSong != null) {
          unawaited(
            playSong(
              stuckSong,
              queue: state.queue,
              index: state.currentIndex,
            ),
          );
          return;
        }
      }

      // 正常情况下用底层播放器位置对齐 UI 进度。
      final drift = (playerPos - state.position).inMilliseconds.abs();
      final keepSyntheticProgress =
          _syntheticPositionFallbackActive &&
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50);
      final preserveSyntheticPosition =
          _syntheticPositionFallbackActive &&
          state.position > const Duration(milliseconds: 250) &&
          (!isReadyPlaying ||
              playerPos + const Duration(seconds: 5) < state.position);

      if (drift >= 250 &&
          !keepSyntheticProgress &&
          !preserveSyntheticPosition) {
        final canDeactivateSynthetic =
            _syntheticPositionFallbackActive &&
            isReadyPlaying &&
            sourcePlayerPos > Duration.zero &&
            drift <= 3000;
        if (canDeactivateSynthetic) {
          _syntheticPositionFallbackActive = false;
          _seekDbg('position fallback deactivated, player position recovered');
        }
        state = state.copyWith(position: playerPos);
        return;
      }
      if (drift >= 250 &&
          preserveSyntheticPosition &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _playDbg(
          'position sync skipped to preserve synthetic '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'driftMs=$drift playing=${player.playing} '
          'processing=${processing.name} song=${state.currentSong?.id}',
        );
      }
      if (drift >= 250 &&
          keepSyntheticProgress &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _playDbg(
          'position drift sync skipped while synthetic active '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'driftMs=$drift song=${state.currentSong?.id}',
        );
      }

      // iOS + LockCachingAudioSource 某些流上 position 可能卡在 0。
      // 当确认持续卡住时，按时间片推进 UI 进度，避免进度条一直 0:00。
      final shouldUseSyntheticPosition =
          isReadyPlaying &&
          sourcePlayerPos <= const Duration(milliseconds: 50) &&
          state.duration > Duration.zero &&
          _stagnantPositionTicks >= 6;
      if (shouldUseSyntheticPosition &&
          _stagnantPositionTicks != _lastStagnantLogTick &&
          _stagnantPositionTicks % 6 == 0) {
        _lastStagnantLogTick = _stagnantPositionTicks;
        _playDbg(
          'position_stagnant ticks=$_stagnantPositionTicks '
          'sourcePlayerPos=$sourcePlayerPos playerPos=$playerPos '
          'statePos=${state.position} '
          'buffered=${player.bufferedPosition} duration=${state.duration} '
          'processing=${processing.name} playing=${player.playing} '
          'song=${state.currentSong?.id} '
          'format=$_currentStreamFormat maxBitRate=$_currentStreamMaxBitRate '
          'stream=${_summarizeStreamUrl(_currentStreamUrl)}',
        );
      }
      // 近末尾守卫(Windows 专项增强)：某些源尾段 position 会停在 duration
      // 前一小段不再前推，或到达/越过声明末尾而 completed 永不触发 → 末尾永久
      // 卡死、不自动接续。Windows 解码器(via just_audio/media_kit)撞到容器 EOF
      // 常见三种异常：processing 停在 buffering；或 playing 被置 false、processing
      // 搁到 idle/其他 ≠completed。因此这里用与 processing 无关的
      // `_nearEndStuckTicks`——只要「(确实在播) 或 (位置已到声明末尾)」且位置停在
      // 末段 2.5s 窗口内不前进，累计满阈值即视为播完并走正式完成流程
      // (尊重 随机/单曲循环/顺序)。
      if (!shouldUseSyntheticPosition &&
          state.duration > const Duration(seconds: 3) &&
          state.duration - state.position <=
              const Duration(milliseconds: 2500) &&
          (player.playing || state.position >= state.duration) &&
          _nearEndStuckTicks >= _nearEndStuckTicksThreshold) {
        final doneSongId = state.currentSong?.id;
        final hasPartialStuckTicks = _nearEndStuckTicks;
        if (doneSongId != null) {
          _nearEndStuckTicks = 0;
          _isHandlingCompletion = true;
          _completionHandlingSongId = doneSongId;
          _seekDbg(
            'near-end(win) stuck -> treat as completed song=$doneSongId '
            'pos=${state.position} dur=${state.duration} '
            'ticks=$hasPartialStuckTicks processing=${processing.name}',
          );
          unawaited(this._onSongCompleted(doneSongId));
          return;
        }
      }

      // 停滞看门狗：确实在播但进度持续不走(非合成进度场景)，
      // 达到阈值即自动跳下一首自愈。统一作用于本机与远程试听，
      // 保持继续跳直到找到能前進的歌曲。
      // (stallSignal 在 Windows 上为 player.playing、移动端为 isReadyPlaying，
      //  避免 Windows 因 processing 卡在 buffering 而被看门狗漏判)
      if (stallSignal &&
          !shouldUseSyntheticPosition &&
          _stagnantPositionTicks >= _stagnantSkipThresholdTicks) {
        final stuckTicks = _stagnantPositionTicks;
        _stagnantPositionTicks = 0;
        _playDbg(
          'stall_watchdog skip_to_next song=${state.currentSong?.id} '
          'ticks=$stuckTicks sourcePlayerPos=$sourcePlayerPos '
          'statePos=${state.position} '
          'processing=${processing.name} playing=${player.playing}',
        );
        // 注意：本函数作用域内存在局部变量 `next`(Duration)，其声明在下方，
        // Dart 中局部变量会遮蔽同名成员方法，故必须显式用 this.next() 调用跳歌方法。
        unawaited(this.next());
        return;
      }

      // 非合成进度在此结束(两个守卫都要求非合成，不会在这里触发)；
      // 合成进度才继续往下，按时间片推进 UI 进度。
      if (!shouldUseSyntheticPosition) return;

      final next = _normalizeSeekPosition(
        state.position + const Duration(milliseconds: 500),
      );
      if (next <= state.position) return;

      if (!_syntheticPositionFallbackActive) {
        _syntheticPositionFallbackActive = true;
        _seekDbg(
          'position fallback activated song=${state.currentSong?.id}',
        );
      }
      state = state.copyWith(position: next);
    });
  }

  void _seekDbg(String message) {
    Logger.info('[SEEKDBG] $message');
  }

  void _playDbg(String message) {
    Logger.infoWithTag(_playDbgTag, message);
  }

  String _summarizeStreamUrl(String? url) {
    if (url == null || url.isEmpty) return 'none';
    try {
      final uri = Uri.parse(url);
      final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      final q = uri.queryParameters;
      final id = q['id'] ?? '-';
      final format = q['format'] ?? '-';
      final maxBitRate = q['maxBitRate'] ?? '-';
      final timeOffset = q['timeOffset'] ?? '-';
      return '${uri.scheme}://$host${uri.path} '
          'id=$id format=$format maxBitRate=$maxBitRate timeOffset=$timeOffset';
    } catch (_) {
      return 'invalid_url';
    }
  }

  @override
  void dispose() {
    _playbackSessionPersistTimer?.cancel();
    _volumePersistTimer?.cancel();
    unawaited(_persistPlaybackSession());
    _positionPollTimer?.cancel();
    _cancelFade();
    _networkTypeSubscription?.cancel();
    // Check if initialized/assigned before disposing
    // Since it was 'late', we can't check.
    // Converting to nullable field:
    _audioPlayer?.dispose();
    _audioHandler?.stop(); // Ensure handler is stopped too
    super.dispose();
  }

  /// 退出/关闭瞬间立即落盘播放状态(播放会话 + 音量),不等待防抖 Timer。
  ///
  /// Windows 托盘「退出」先回调本方法,落盘完成后再调 native quit 真正结束
  /// 进程 —— 因为直接结束进程时 Dart 的 dispose 不执行,防抖 Timer 也来不及
  /// 触发,最近一次进度/音量会丢失(shared_preferences 还可能被写坏)。
  Future<void> persistPlaybackStateNow() async {
    _playbackSessionPersistTimer?.cancel();
    _playbackSessionPersistTimer = null;
    _volumePersistTimer?.cancel();
    _volumePersistTimer = null;
    try {
      await _persistPlaybackSession();
    } catch (e) {
      Logger.warnWithTag(
        _playerLogTag,
        'exit persist playback session failed',
        e,
      );
    }
    try {
      await LocalStorage.setPlayerVolume(state.volume);
    } catch (e) {
      Logger.warnWithTag(_playerLogTag, 'exit persist volume failed', e);
    }
  }
}
