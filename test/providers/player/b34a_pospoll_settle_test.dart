// b34a：lib/providers/player/player_position_polling.dart 剩余未覆盖分支
// （LF:139 / LH:97，42 miss 中可直达的部分）：
//   * 26-34 seek 落位宽限窗：宽限到期/位置前移后自动解除（第 30 行）
//   * 84-92 位置真正前进 → 清「期望自动播放」+ 复位 0 秒卡死连续重载计数（89-90）
//
// 其余 miss（69-71、183-252、311-322 合成进度 fallback 家族）经源码比对为
// **不可达死代码**：激活条件 `_stagnantPositionTicks >= 6 && sourcePlayerPos <= 50ms`
// 与 `atStart`（pos<=1.5s 即清零计数，99-100 行）自相矛盾 —— 见报告 D-xxx。
// [D-053] 该死代码家族已于 2026-10-07 按用户决策整体删除（合成进度回退不要）。
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

  /// 周期性 re-emit：playing 状态下 just_audio 的 position 会按真实时间外推
  /// （updatePosition + now - updateTime），不反复刷新 updateTime 的话钉死的
  /// 0 位置 1.5s 后就会「走起来」，看门狗计数全废。
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
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();
  final spy = _SpySubsonicApiClient();
  late _FakeJustAudioPlatform platform;
  late _FakeAudioPlayerPlatform fake;

  ProviderContainer buildContainer() => ProviderContainer(
        overrides: <Override>[
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

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot() async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer();
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    fake = await platform
        .init(InitRequest(id: 'b34a-pre')) as _FakeAudioPlayerPlatform;
    return n;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() => container.dispose());

  test('0 秒卡死重载自愈后位置前移 → 复位连续重载计数，不再重载（84-92）', () async {
    notifier = await boot();
    // 钉住替身位置在 0：wantsPlaying(autoplay) + atStart + 无进展 → 累计。
    fake.emitPosOverride = Duration.zero;
    fake.emitState = ProcessingStateMessage.ready;
    await notifier.playSong(
      _song('s1'),
      queue: <Song>[_song('s1')],
      index: 0,
      autoPlay: true,
    );

    // 12 tick（6s）触发 0 秒卡死看门狗 → playSong 重载同一首（load #2）。
    final reloaded =
        await waitUntil(() => fake.loadCount >= 2, ticks: 900);
    expect(reloaded, isTrue);
    expect(notifier.state.currentSong?.id, 's1');

    // 位置真正迈出起点 → 89-90 复位 _startupReloadStreak/_startupStuckSongId。
    fake.emitPosOverride = const Duration(seconds: 30);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // 再等两个看门狗周期：不应再触发重载（loadCount 稳定在 2）。
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(fake.loadCount, 2);
    expect(notifier.state.currentSong?.id, 's1');
  });

  test('reload-stream seek 落位宽限：位置前移后宽限自动解除（26-34），seek 目标落位',
      () async {
    notifier = await boot();
    await notifier.playSong(
      _song('s1'),
      queue: <Song>[_song('s1')],
      index: 0,
      autoPlay: false,
    );
    final loadsAfterActivate = fake.loadCount;

    // MusicFlow 管道化服务端 → seek 走 reload-stream，落位时置 15s 宽限。
    await notifier.seek(const Duration(seconds: 90));
    final seekDone = await waitUntil(
      () => notifier.state.position == const Duration(seconds: 90),
      ticks: 200,
    );
    expect(seekDone, isTrue);

    // 替身位置推进到 5s（>1.5s）→ 轮询 tick 内宽限自动解除（第 30 行），
    // 且不把本次 seek 误判为 0 秒卡死（无 reload、无跳歌）。
    fake.emitPosOverride = const Duration(seconds: 5);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(fake.loadCount, loadsAfterActivate + 1); // 只有 seek reload 那一次
    expect(notifier.state.currentSong?.id, 's1');
  });
}
