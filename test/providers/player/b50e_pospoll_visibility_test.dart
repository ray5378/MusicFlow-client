// b50e：P3 位置轮询「不可见降频」。
//
// 覆盖 lib/providers/player/player_position_polling.dart 新增的可见性降频：
//   * 降频契约：基准周期 500ms × 抽稀因子 = 2s（有效周期常量关系）；
//   * 不可见态仍**保留**看门狗：0 秒卡死看门狗按墙钟阈值触发（加权不放大），
//     证明「降频 ≠ 停摆」——后台播放遇到卡死照常自愈。
//
// 说明：这里刻意不测「不可见时 UI 位置写回次数减少」，因为 UI 位置的实时
// 推进由 `player.positionStream` 监听独立驱动（非轮询定时器），与轮询降频
// 无因果关系，断言会失真。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import 'package:musicflow_client/providers/ui/app_visibility_provider.dart';

// ───────────────────────────── just_audio 替身 ───────────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  int loadCount = 0;

  Duration? emitPosOverride;
  ProcessingStateMessage emitState = ProcessingStateMessage.ready;
  Timer? _autoEmit;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      const Stream<PlayerDataMessage>.empty();

  void emit() {
    _events.add(
      PlaybackEventMessage(
        processingState: emitState,
        updateTime: DateTime.now(),
        updatePosition: emitPosOverride ?? Duration.zero,
        bufferedPosition: emitPosOverride ?? Duration.zero,
        duration: const Duration(seconds: 200),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  /// 周期性 re-emit：playing 状态下 just_audio 的 position 会按真实时间外推，
  /// 不反复刷新 updateTime 的话钉死的 0 位置会「走起来」，看门狗计数全废。
  void startAutoEmit() {
    _autoEmit ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      emit();
    });
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loadCount += 1;
    startAutoEmit();
    scheduleMicrotask(emit);
    return LoadResponse(duration: const Duration(seconds: 200));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async =>
      PlayResponse.fromMap(const <dynamic, dynamic>{});

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

  void stopAutoEmit() {
    _autoEmit?.cancel();
    _autoEmit = null;
  }
}

class _FakeJustAudioPlatform extends JustAudioPlatform {
  _FakeAudioPlayerPlatform? last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final existing = last;
    if (existing != null) return existing;
    final player = _FakeAudioPlayerPlatform(request.id);
    last = player;
    return player;
  }
}

// ───────────────────────────── 其它桩 ─────────────────────────────────────

Song _song(String id) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'mp3',
      duration: 200,
      starred: false,
    );

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async => null;
}

class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

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
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
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
      'http://192.168.10.240:46400/rest/stream?id=$songId';
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

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);

  @override
  String? get localPeerId => null;
}

// ───────────────────────────────── 装配 ─────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (MethodCall call) async => null,
  );

  final repo = _FakeMusicRepository();
  final spy = _SpySubsonicApiClient();
  late _FakeJustAudioPlatform platform;
  _FakeAudioPlayerPlatform? fake;

  ProviderContainer buildContainer({required bool renderingActive}) =>
      ProviderContainer(
        overrides: <Override>[
          isRenderingActiveProvider.overrideWithValue(renderingActive),
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
          effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
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

  Future<bool> waitQuiet(PlayerNotifier notifier) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 4 && !notifier.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!notifier.debugIsRestoringPlaybackSession) return true;
      }
    }
    return false;
  }

  Future<bool> waitUntil(bool Function() cond, {int ticks = 400}) async {
    for (var i = 0; i < ticks; i++) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  ProviderContainer? container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({required bool renderingActive}) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    final c = buildContainer(renderingActive: renderingActive);
    container = c;
    final n = c.read(playerProvider.notifier);
    await waitQuiet(n);
    fake = await platform.init(InitRequest(id: 'b50e-pre'))
        as _FakeAudioPlayerPlatform;
    return n;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    fake?.stopAutoEmit();
    container?.dispose();
  });

  test('降频契约：可见基准 500ms × 抽稀因子 = 不可见有效周期 2s', () {
    expect(kPositionPollBaseInterval, const Duration(milliseconds: 500));
    expect(kHiddenPollDecimation, 4);
    expect(
      kPositionPollBaseInterval * kHiddenPollDecimation,
      const Duration(seconds: 2),
    );
  });

  test('不可见时仍保留看门狗：0 秒卡死按墙钟阈值自愈（加权不放大，约 6s）',
      () async {
    notifier = await boot(renderingActive: false);
    // 钉住替身位置在 0：wantsPlaying(autoplay) + atStart + 无进展 → 累计。
    // 不可见下轮询抽稀到 2s/次，但每次按因子加权 → 12 逻辑 tick 仍需约 6s
    // （若加权失效则需 ~24s，本用例 12s 预算会超时失败）。
    fake!.emitPosOverride = Duration.zero;
    fake!.emitState = ProcessingStateMessage.ready;
    await notifier.playSong(
      _song('s1'),
      queue: <Song>[_song('s1')],
      index: 0,
      autoPlay: true,
    );

    final reloaded = await waitUntil(() => fake!.loadCount >= 2, ticks: 1200);
    expect(reloaded, isTrue,
        reason: '不可见降频不得停摆：0 秒卡死看门狗应仍在墙钟阈值内触发重载');
    expect(notifier.state.currentSong?.id, 's1');
  });
}
