import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';

import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/server_url_security.dart';
import 'package:musicflow_client/core/player/shuffle_queue_indexer.dart';
import 'package:musicflow_client/core/player/playback_payload.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';
import 'package:musicflow_client/core/services/smtc_service.dart';

import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/crossfade_provider.dart';
import 'package:musicflow_client/providers/api/gd_music_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

export 'package:musicflow_client/providers/player/player_state.dart';
export 'package:musicflow_client/providers/player/favorite_scrobble_handler.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/shuffle_history.dart';
import 'package:musicflow_client/providers/player/favorite_scrobble_handler.dart';
import 'package:musicflow_client/providers/player/player_seek_policy.dart';
import 'package:musicflow_client/providers/player/transcoded_stream_seek.dart';
part 'player_platform_helpers.dart';
part 'player_stream_source.dart';
part 'player_playback_helpers.dart';
part 'player_crossfade.dart';
part 'player_playback_session.dart';
part 'player_shuffle_queue.dart';
part 'player_seek.dart';
part 'player_position_polling.dart';


/// 播放器 Provider

// ...
final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>((
  ref,
) {
  // 不固定 apiClient/musicRepository 引用，PlayerNotifier 内部通过 ref.read 动态获取
  // 这样既不建立 watch 依赖（不会被重建），又能始终拿到最新的实例
  return _PlayerNotifierImpl(ref);
});

/// 播放器状态管理器
abstract class PlayerNotifier extends StateNotifier<PlayerState> {
  final Ref _ref;
  AudioPlayer? _audioPlayer;
  MusicFlowAudioHandler? _audioHandler;

  /// Windows SMTC（系统音量浮层/锁屏媒体卡片）。仅 Windows 平台初始化。
  SmtcService? _smtc;

  /// 当前音频处理器（后台服务中初始化）。供 DLNA 等注册「任务被手动清理」回调，
  /// 以便在用户划掉 App 时释放各自的后台保活。
  MusicFlowAudioHandler? get audioHandler => _audioHandler;
  StreamSubscription<NetworkType>? _networkTypeSubscription;
  final Random _random = Random();
  // 随机「上一步/下一步」历史栈与「一轮内不重复 + 预缓存一致性」索引决策收拢到
  // 纯 Dart：真实切歌(next/previous)与预缓存复用同一出口,避免各自独立抽随机
  // 导致「缓存的下一首 ≠ 实际播的下一首」;back/forward 导航与本轮标记统一维护。
  final ShuffleHistory _shuffleHistory = ShuffleHistory();
  final ShuffleQueueIndexer _shuffleQueueIndexer = ShuffleQueueIndexer();
  final PlaybackPayloadEncoder _payloadEncoder = PlaybackPayloadEncoder();
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

  /// 0 秒卡死兜底阈值：播放意图存在且位置持续卡在起点(loading/buffering
  /// 或 position 长期 <=0)，连续达到该 tick 数(每 500ms) 即重载当前曲目，
  /// 模拟「切下一首再切回」的效果。12 tick = 6 秒。

  /// 0 秒卡死「连续重载」容错上限：同一首曲因卡在起点被看门狗连续重载达到
  /// 该次数仍无任何进展(位置始终不前进)，判定为「后端确无可播源」而非
  /// 瞬时挂起，转入既有失败跳歌逻辑(_handlePlaybackError)标记死歌并跳下一首，
  /// 避免对一首永远无法起播的歌无限重载原地空转。0 秒卡死重载走的是模拟
  /// 「切下一首再切回」路径，瞬时可恢复的挂起在 1 次重载后即会推进位置并
  /// 清零本计数；因此容错设为 2：允许 1 次自愈重试，若第 2 次连续重载仍无
  /// 进展则判死跳歌。

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
  int _nearEndStuckTicks = 0;
  bool _syntheticPositionFallbackActive = false;
  int _playDebugSession = 0;
  bool _loggedDurationUnavailableForSong = false;
  Timer? _fadeTimer;
  Completer<void>? _fadeCompleter;
  // 播放会话落盘节流：仅当序列本质上变化时才重新序列化整张队列，避免每次
  // position tick 都全量 toJson + jsonEncode（大队列会在大屏旋转封面时周期卡顿）。
  // 由 2s 放宽到 5s：降频 2.5 倍，崩溃续播最多损失 ~5s 进度，与主流播放器一致。
  Timer? _playbackSessionPersistTimer;
  Timer? _volumePersistTimer;
  bool _isPersistingPlaybackSession = false;
  bool _isRestoringPlaybackSession = false;
  // 队列序列化缓存：queue 未变化时直接复用序列化结果，避免每 tick 重序列化整队。
  // 队列序列化缓存移入 _payloadEncoder(PlaybackPayloadEncoder)。
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

  /// 预探测确认不可播的歌曲 ID 集合，播放前自动跳过（与 _probeCache 同步带上限）。
  final Set<String> _deadSongs = <String>{};

  /// 防止并发预探测。
  bool _probing = false;

  /// 预探测窗口大小：提前探测接下来几首。

  // ── Handlers ──────────────────────────────────────────────────────────────
  late final FavoriteScrobbleHandler _favoriteHandler;

  /// 动态获取最新的 API client
  SubsonicApiClient get _apiClient => _ref.read(subsonicApiClientProvider);

  /// 动态获取最新的 MusicRepository
  MusicRepository get _musicRepository =>
      _ref.read(musicRepositoryProvider) ?? MusicRepository(_apiClient);

  Future<void> _applyPendingSeekIfNeeded(); // ignore: unused_element, unused_element_parameter
  Map<String, dynamic>? _buildPlaybackSessionPayload(); // ignore: unused_element, unused_element_parameter
  String _buildStreamUrlOrThrow( String songId, { required int session, required String source, int? maxBitRate, String? format, int? timeOffset, }); // ignore: unused_element, unused_element_parameter
  void _cancelFade(); // ignore: unused_element, unused_element_parameter
  void _clearForcedNext(); // ignore: unused_element, unused_element_parameter
  void _clearPendingSeek(); // ignore: unused_element, unused_element_parameter
  void _clearStreamContext(); // ignore: unused_element, unused_element_parameter
  int? _consumePrecomputedUpcomingIndex(); // ignore: unused_element, unused_element_parameter
  ShuffleHistoryEntry? _currentShuffleEntry({ required List<Song> queue, required Song? song, required int index, }); // ignore: unused_element, unused_element_parameter
  Future<void> _enrichSongMetadata(String songId, int session); // ignore: unused_element, unused_element_parameter
  Future<ServerAddress?> _ensureActiveAddressForPlayback({ required int session, required String reason, bool logFailure = true, }); // ignore: unused_element, unused_element_parameter
  void _fadeIn(); // ignore: unused_element, unused_element_parameter
  Future<void> _fadeOut(int session); // ignore: unused_element, unused_element_parameter
  int? _getQueuePreviousIndex(); // ignore: unused_element, unused_element_parameter
  int? _getRandomIndexExcludingCurrent({bool allowRoundReset = true}); // ignore: unused_element, unused_element_parameter
  void _invalidateLoadedSource({required String reason}); // ignore: unused_element, unused_element_parameter
  void _invalidateSeekRequests(); // ignore: unused_element, unused_element_parameter
  bool _isPlaybackContextCurrent({ required int session, required String songId, }); // ignore: unused_element, unused_element_parameter
  bool _isSameQueueBySongId(List<Song> currentQueue, List<Song> nextQueue); // ignore: unused_element, unused_element_parameter
  bool _isSeekRequestCurrent({ required int seekGeneration, required int playbackSession, required String songId, }); // ignore: unused_element, unused_element_parameter
  Duration _logicalPlayerPosition(Duration sourcePosition); // ignore: unused_element, unused_element_parameter
  void _markSongDead(String songId); // ignore: unused_element, unused_element_parameter
  String? _needsTranscoding(String? suffix); // ignore: unused_element, unused_element_parameter
  int _normalizeBitRateKbps(int? bitRate); // ignore: unused_element, unused_element_parameter
  Duration _normalizeSeekPosition(Duration position); // ignore: unused_element, unused_element_parameter
  int _parseBitRateFromText(String? text); // ignore: unused_element, unused_element_parameter
  List<Song> _parsePlaybackSessionQueue(Object? rawQueue); // ignore: unused_element, unused_element_parameter
  int? _parseStoredInt(Object? value); // ignore: unused_element, unused_element_parameter
  Future<void> _persistPlaybackSession(); // ignore: unused_element, unused_element_parameter
  Future<void> _probeUpcoming(); // ignore: unused_element, unused_element_parameter
  void _releaseSeekAnchor(int seekGeneration); // ignore: unused_element, unused_element_parameter
  Future<bool> _replaceLoadedSource({ required String songId, required String label, required bool Function() ownsSource, required Future<void> Function(AudioPlayer player) setSource, }); // ignore: unused_element, unused_element_parameter
  void _resetShuffleHistory({bool updateState = true}); // ignore: unused_element, unused_element_parameter
  int _resolveCurrentBitRateKbps({ required Song song, required AudioQualityLevel quality, required PlaybackSource source, int? maxBitRate, }); // ignore: unused_element, unused_element_parameter
  int? _resolveForcedNextIndex(); // ignore: unused_element, unused_element_parameter
  int _resolveRestoredQueueIndex({ required List<Song> queue, required int preferredIndex, required String? currentSongId, }); // ignore: unused_element, unused_element_parameter
  Song? _resolveUpcomingSongForCache(); // ignore: unused_element, unused_element_parameter
  Future<void> _restorePlaybackSession(); // ignore: unused_element, unused_element_parameter
  void _schedulePendingSeekIfReady(); // ignore: unused_element, unused_element_parameter
  void _schedulePersistPlaybackSession({bool immediate = false}); // ignore: unused_element, unused_element_parameter
  void _scheduleSongRemoteRefresh(Song song, int session); // ignore: unused_element, unused_element_parameter
  Future<void> _seekWithFallback( Duration target, { required String songId, required bool Function() isCurrentSeek, required bool Function() ownsSource, }); // ignore: unused_element, unused_element_parameter
  void _setSourcePositionOffset(Duration offset); // ignore: unused_element, unused_element_parameter
  void _setStreamContext({ required String songId, required String? format, required int? maxBitRate, required bool seekByReloadStream, Duration sourcePositionOffset = Duration.zero, }); // ignore: unused_element, unused_element_parameter
  bool _shouldPreserveSeekPosition(); // ignore: unused_element, unused_element_parameter
  Duration _sourceSeekPosition(Duration logicalPosition); // ignore: unused_element, unused_element_parameter
  void _startPositionPolling(AudioPlayer player); // ignore: unused_element, unused_element_parameter
  ServerAddress? _syncImmediateActiveAddress({ required int session, required String reason, }); // ignore: unused_element, unused_element_parameter
  void _syncShuffleHistoryBeforeSongChange({ required Song nextSong, required List<Song> nextQueue, required int nextIndex, required bool recordHistory, required bool clearForwardHistory, }); // ignore: unused_element, unused_element_parameter
  void _syncShuffleHistoryState(); // ignore: unused_element, unused_element_parameter
  int? _takeLastValidBackHistoryIndex(); // ignore: unused_element, unused_element_parameter
  int? _takeLastValidForwardHistoryIndex(); // ignore: unused_element, unused_element_parameter

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

    // Windows SMTC：桌面端不走 audio_service，用 smtc_windows 独立桥接
    // 系统音量浮层/锁屏媒体卡片（显示正在播放 + 上一首/暂停/下一首可控）。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final smtc = SmtcService();
      unawaited(smtc.init());
      smtc.onNext = () => next();
      smtc.onPrevious = () => previous();
      smtc.onPlayPause = (resume) {
        if (resume) {
          play();
        } else {
          pause();
        }
      };
      _smtc = smtc;
    }

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
      _syncSmtc();
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

      // ---- 离线回退：网络断开或后端不可达时，若本地缓存命中则播放缓存文件。----
      if (_ref.read(isOfflineProvider)) {
        final cache = _ref.read(offlineCacheManagerProvider);
        await _ref.read(offlineCacheReadyProvider.future);
        final file = cache.songFile(song.id);
        if (file != null && file.existsSync()) {
          _seekDbg(
            'offline fallback play cached file song=${song.id} '
            'path=${file.path}',
          );
          try {
            final sourceReady = await _replaceLoadedSource(
              songId: song.id,
              label: 'offline_file',
              ownsSource: () => _isPlaybackContextCurrent(
                session: debugSession,
                songId: song.id,
              ),
              setSource: (player) async {
                await player.setUrl(file.uri.toString());
              },
            );
            if (!sourceReady) return;
            await _syncPlaybackAfterSourceReady(autoPlay: autoPlay);
            if (!isCurrentSession()) return;
            await _applyPendingSeekIfNeeded();
            if (!isCurrentSession()) return;
            state = state.copyWith(
              playbackSource: PlaybackSource.stream,
              currentBitRateKbps: _resolveCurrentBitRateKbps(
                song: song,
                quality: _ref.read(effectiveQualityProvider),
                source: PlaybackSource.stream,
              ),
            );
            if (!isCurrentSession()) return;
            _clearCurrentPlaybackRetry(reason: 'playback_ready_offline');
            if (autoPlay) {
              await _scrobble(song.id, submission: false);
              if (!isCurrentSession()) return;
            }
            _seekDbg(
              'offline fallback ready song=${song.id} '
              'playerPos=${_audioPlayer?.position} duration=${state.duration}',
            );
            return;
          } catch (e) {
            Logger.warn('Offline cache playback failed: ${song.title}', e);
            // 缓存文件损坏 → 按「不可播」跳过，走下一首。
            _handlePlaybackError(song.id);
            return;
          }
        }
        // 未缓存：提示离线，沿用现有「跳过不可播」找下一首。
        Logger.info('No offline cache for: ${song.title}');
        _handlePlaybackError(song.id);
        return;
      }

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

      // 触发背景缓存：当前曲 + 实际即将播放的下一首（随机模式按随机语义取样）+ 当前曲封面。
      unawaited(
        _ref
            .read(offlineCacheDaemonProvider)
            .onSongStartedOnline(
              song: song,
              queue: playQueue,
              index: playIndex,
              upcomingSong: _resolveUpcomingSongForCache(),
            ),
      );

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


  /// 更新系统媒体信息（Android 通知栏 / Windows SMTC 音量浮层）
  void _updateMediaItem(Song song) {
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

    // Windows SMTC：推送歌名/歌手/专辑/封面，并把时间轴重置到新歌起点。
    _smtc?.updateMetadata(
      title: song.title,
      artist: song.artist ?? 'Unknown Artist',
      album: song.album ?? 'Unknown Album',
      thumbnail: safeCoverArtUrl,
    );
    _syncSmtc();
  }

  /// 把当前播放状态同步到 Windows SMTC（音量浮层媒体卡片）。
  /// SMTC 由系统按播放状态自行推进显示位置，只在关键节点推送即可：
  /// 切歌（重置时间轴）、播放/暂停切换、seek 完成、投屏进度 tick。
  void _syncSmtc() {
    final smtc = _smtc;
    if (smtc == null) return;
    smtc.updateStatus(
      playing: state.isPlaying,
      position: state.position,
      duration: state.duration,
    );
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
    // Windows SMTC 同样由投屏进度驱动（本机暂停时进度会定住）。
    _smtc?.updateStatus(
      playing: playing,
      position: position,
      duration: state.duration,
    );
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
          _shuffleHistory.pushForward(currentEntry);
        }
      } else {
        _shuffleHistory.clearForward();
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
          _shuffleHistory.pushBack(currentEntry);
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
      // 尽量复用「歌曲就绪时提前算好」的下一首索引(与预缓存消费同一值,保证
      // 缓存的就是实际要播的下一首);未持有才临时抽随机。
      var nextIndex = _consumePrecomputedUpcomingIndex();
      if (nextIndex == null) {
        nextIndex = _getRandomIndexExcludingCurrent();
        if (nextIndex != null) {
          Logger.info('SHUFFLE RANDOM_FALLBACK idx=$nextIndex song=${state.queue[nextIndex].id} title=${state.queue[nextIndex].title}');
        }
      }
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
        _syncSmtc();
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
    _smtc?.dispose();
    _smtc = null;
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

/// 具体实现：所有内部职责 mixin 在此组装。
class _PlayerNotifierImpl extends PlayerNotifier
    with
        PlayerStreamSourceInternals,
        PlayerPlaybackInternals,
        PlayerCrossfadeInternals,
        PlayerPlaybackSessionInternals,
        PlayerShuffleQueueInternals,
        PlayerSeekInternals,
        PlayerPositionPollingInternals {
  _PlayerNotifierImpl(Ref ref) : super(ref);
}
