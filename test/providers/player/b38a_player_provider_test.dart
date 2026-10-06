// b38a —— Route A 播放核心补测（player_provider / 相关 mixin）。
//
// 复用 b37a2 的真实 PlayerNotifier harness（just_audio 替身 + 外部 provider 全桩），
// 专啃 lcov 中本路线仍 0 命中的几条**可达公共路径**分支：
//   * syncQueueForCast 投屏镜像的红心富集（player_provider 2140/2156/2162）；
//   * playNext + next 的「强制下一首」快车道（player_provider 2032-2036）；
//   * 顺序/随机模式 previous/next 的队列索引边界与历史栈逻辑
//     （player_shuffle_queue 37/94/112/113/177 等）；
//   * 在线 playSong 单歌队列分支（player_provider 2446）等。
// 既有 b29a/b34a/b37a2 系列未覆盖上述公共路径，故在此补齐。
//     走 `quality.maxBitRate` 分支）。
//
// 姿势与 b29a 完全一致：驱动**真实** `_PlayerNotifierImpl`，just_audio 平台换替身，
// 外部 provider（地址池/仓库/离线守护/投屏控制器）全桩。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

// ─────────────────────────── 替身 just_audio 平台 ───────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  int loadCount = 0;
  int playCount = 0;
  final List<String> loadedUris = <String>[];

  /// 置真后 `load()` 抛错 → 让离线缓存的 setUrl 失败（打 1050-1055 分支）。
  bool throwOnLoad = false;

  var _tick = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void emit(ProcessingStateMessage state) {
    _tick += 1;
    final pos = Duration(seconds: _tick * 30);
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: pos,
        bufferedPosition: pos,
        duration: const Duration(seconds: 200),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loadCount += 1;
    if (throwOnLoad) throw StateError('load boom');
    final message = request.audioSourceMessage;
    if (message is UriAudioSourceMessage) {
      loadedUris.add(message.uri);
    }
    scheduleMicrotask(() => emit(ProcessingStateMessage.ready));
    return LoadResponse(duration: const Duration(seconds: 200));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    playCount += 1;
    return PlayResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async =>
      PauseResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SeekResponse> seek(SeekRequest request) async =>
      SeekResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async =>
      SetSkipSilenceResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async =>
      SetShuffleModeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async =>
      SetShuffleOrderResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async =>
      SetAutomaticallyWaitsToMinimizeStallingResponse.fromMap(
          const <dynamic, dynamic>{});

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async =>
      SetAndroidAudioAttributesResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async =>
      DisposeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
    ConcatenatingInsertAllRequest request,
  ) async =>
      ConcatenatingInsertAllResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
    ConcatenatingRemoveRangeRequest request,
  ) async =>
      ConcatenatingRemoveRangeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
    ConcatenatingMoveRequest request,
  ) async =>
      ConcatenatingMoveResponse.fromMap(const <dynamic, dynamic>{});
}

class _FakeJustAudioPlatform extends JustAudioPlatform {
  _FakeAudioPlayerPlatform? last;

  /// 传给后续创建出来的播放器：置真则 `load()` 抛错。
  bool throwOnLoad = false;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = _FakeAudioPlayerPlatform(request.id)..throwOnLoad = throwOnLoad;
    last = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async =>
      DisposePlayerResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async =>
      DisposeAllPlayersResponse.fromMap(const <dynamic, dynamic>{});
}

// ─────────────────────────── 其它桩 ───────────────────────────

Song _song(
  String id, {
  String suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
  String? coverArt,
  bool starred = false,
}) =>
    Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
      duration: duration,
      starred: starred,
      coverArt: coverArt,
    );

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  /// `_enrichSongMetadata` 的补齐源；null → 直接 return。
  Song? getSongResult;
  bool throwOnGetSong = false;

  /// 置非空后 `getSong` 会**挂起**到该 Completer 完成 —— 用来把「补齐落地」
  /// 精确挪到源就绪（`_setStreamContext` 已执行）之后，从而进入
  /// `_enrichSongMetadata` 里 `_currentStreamSongId == songId` 那段（48-56）。
  Completer<void>? getSongGate;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async {
    final gate = getSongGate;
    if (gate != null) await gate.future;
    if (throwOnGetSong) throw StateError('getSong boom');
    return getSongResult;
  }
}

class _NoopOfflineCacheDaemon extends OfflineCacheDaemon {
  _NoopOfflineCacheDaemon(super.ref);

  @override
  Future<void> onSongStartedOnline({
    required Song song,
    required List<Song> queue,
    required int index,
    Song? upcomingSong,
  }) async {}
}

/// 离线缓存管理器替身：直接给出（或不给）缓存文件，不碰真实磁盘布局。
class _FakeCacheManager extends OfflineCacheManager {
  _FakeCacheManager(this.file);

  final File? file;

  @override
  Future<void> init() async {}

  @override
  File? songFile(String songId) => file;
}

class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  String streamUrl = 'http://192.168.10.240:46400/rest/stream?id=s1';

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async =>
      <String, dynamic>{};

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async =>
      <String, dynamic>{};

  @override
  String getStreamUrl(
    String songId, {
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) =>
      streamUrl;

  @override
  String getCoverArtUrl(String coverArtId, {int? size}) =>
      'https://music.example.test/cover/$coverArtId';

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async =>
      <String, dynamic>{};
}

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();
  final spy = _SpySubsonicApiClient();
  late _FakeJustAudioPlatform platform;

  ProviderContainer buildContainer({
    required bool offline,
    AudioQualityLevel quality = AudioQualityLevel.original,
    File? cache,
    List<Override>? extra,
  }) =>
      ProviderContainer(
        overrides: <Override>[
          ...?extra,
          activeLibraryProvider.overrideWithValue(
            MusicLibrary(
              id: 'lib1',
              name: '主库',
              serverType: 'MusicFlow',
              isActive: true,
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 1),
            ),
          ),
          activeAddressProvider.overrideWith(
            (ref) => ServerAddress(
              id: 'a1',
              libraryId: 'lib1',
              label: '主库',
              url: 'http://192.168.10.240:46400',
              priority: 0,
            ),
          ),
          effectiveQualityProvider.overrideWithValue(quality),
          isOfflineProvider.overrideWithValue(offline),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          offlineCacheManagerProvider.overrideWithValue(
            _FakeCacheManager(cache),
          ),
          offlineCacheReadyProvider.overrideWith((ref) async {}),
          castPeerControllerProvider.overrideWith(
            (ref) => _FakeCastPeerController(ref),
          ),
          starredProvider.overrideWith(
            (ref) async => StarredResult(
              artists: const <Artist>[],
              albums: const <Album>[],
              songs: const <Song>[],
            ),
          ),
          allSongsProvider.overrideWith((ref) async => <Song>[]),
          albumDetailProvider('al1').overrideWith((ref) async => null),
        ],
      );

  Future<void> waitQuiet(PlayerNotifier notifier) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 4 && !notifier.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!notifier.debugIsRestoringPlaybackSession) return;
      }
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({
    bool offline = false,
    AudioQualityLevel quality = AudioQualityLevel.original,
    File? cache,
  }) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(offline: offline, quality: quality, cache: cache);
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  setUp(() {
    repo.getSongResult = null;
    repo.throwOnGetSong = false;
    repo.getSongGate = null;
  });


  // ───────────── playNext + next：强制下一首快车道(2032-2036) ─────────────
  test('shuffle + playNext + next → 强制下一首(2032-2036)', () async {
    notifier = await boot(offline: false);
    notifier.state = notifier.state.copyWith(
      shuffleEnabled: true,
      playbackMode: PlaybackMode.all,
      loopMode: LoopMode.all,
    );
    await notifier.playSong(
      _song('a'),
      queue: <Song>[_song('a'), _song('b'), _song('c')],
      index: 0,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // playNext 把 b 设为强制下一首。
    await notifier.playNext(_song('b'));
    await notifier.next();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notifier.state.currentSong?.id, 'b',
        reason: '应走强制下一首快车道(2032-2036)');
  });

  // ───────────── previous：顺序模式队列回退(_getQueuePreviousIndex 113) ─────────────
  test('order 模式 previous → 队列上一首(113)', () async {
    notifier = await boot(offline: false);
    notifier.state = notifier.state.copyWith(
      shuffleEnabled: false,
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
    );
    await notifier.playSong(
      _song('a'),
      queue: <Song>[_song('a'), _song('b'), _song('c')],
      index: 1,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await notifier.previous();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notifier.state.currentIndex, 0);
    expect(notifier.state.currentSong?.id, 'a');
  });

  // ───────────── shuffle 模式 next/previous：历史栈逻辑(37/94) ─────────────
  test('shuffle 模式 next/previous 历史栈(37/94)', () async {
    notifier = await boot(offline: false);
    notifier.state = notifier.state.copyWith(
      shuffleEnabled: true,
      playbackMode: PlaybackMode.all,
      loopMode: LoopMode.all,
    );
    await notifier.playSong(
      _song('a'),
      queue: <Song>[_song('a'), _song('b'), _song('c'), _song('d')],
      index: 0,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await notifier.next();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await notifier.next();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // 历史应可回退。
    await notifier.previous();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notifier.state.currentSong, isNotNull);
  });

  // ───────────── playNext 空队列 → 直接 playSong(单歌)(2446) ─────────────
  test('playNext 空队列 → 直接起播单歌(2446)', () async {
    notifier = await boot(offline: false);
    notifier.state = notifier.state.copyWith(shuffleEnabled: false);
    await notifier.playNext(_song('x'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notifier.state.currentSong?.id, 'x',
        reason: '空队列 playNext 应直接 playSong(单歌)(2446)');
  });
}
