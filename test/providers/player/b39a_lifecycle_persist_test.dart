// b39a —— Route A 播放核心补测：**退出落盘 / 音量防抖 / 播放模式持久化 /
// 转码时长偏移保留**。真实 PlayerNotifier harness（just_audio 平台替身 +
// 外部 provider 全桩），不碰 lib/ 一行。
//
// 覆盖目标（lbp 口径）：
//   * player_provider `persistPlaybackStateNow` 的 `_awaitInFlightPersist`
//     等待（约 L2773）+ 退出补写音量（约 L2782/L2784）。
//   * player_provider `_schedulePersistVolume` 的 1s 防抖 Timer 回调
//     （约 L1855/L1857：清空 timer 句柄 + `LocalStorage.setPlayerVolume`）。
//   * player_provider `_restorePlaybackMode`（约 L2408/L2413）与
//     `_persistPlaybackMode`（约 L2421/L2423）。
//   * player_provider durationStream 的两条偏移分支：
//       - `_sourcePositionOffset > 0 && state.duration > 0` → 保留逻辑时长（约 L623-628）；
//       - 元数据缺失时 `duration + _sourcePositionOffset`（约 L665）。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:musicflow_client/data/sources/local_storage.dart';
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

class _Cfg {
  bool throwOnLoad = false;
  Duration duration = const Duration(seconds: 200);
}

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id, this.cfg);

  final _Cfg cfg;

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  final List<String> calls = <String>[];
  final List<String> loadedUris = <String>[];

  var _tick = 0;

  int count(String method) => calls.where((c) => c == method).length;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  /// 手动上报一次播放事件（duration 可指定）→ 驱动 durationStream。
  void emit(Duration duration, {ProcessingStateMessage? state}) {
    _tick += 1;
    final pos = Duration(seconds: _tick * 30);
    _events.add(
      PlaybackEventMessage(
        processingState: state ?? ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: pos,
        bufferedPosition: pos,
        duration: duration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    calls.add('load');
    if (cfg.throwOnLoad) throw StateError('load boom');
    final message = request.audioSourceMessage;
    if (message is UriAudioSourceMessage) loadedUris.add(message.uri);
    final duration = cfg.duration;
    scheduleMicrotask(() => emit(duration));
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
    _data.add(PlayerDataMessage(playing: true));
    return PlayResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    calls.add('pause');
    _data.add(PlayerDataMessage(playing: false));
    return PauseResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    calls.add('seek');
    return SeekResponse.fromMap(const <dynamic, dynamic>{});
  }

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
        const <dynamic, dynamic>{},
      );

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
  _FakeJustAudioPlatform(this.cfg);

  final _Cfg cfg;
  final List<_FakeAudioPlayerPlatform> players = <_FakeAudioPlayerPlatform>[];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = _FakeAudioPlayerPlatform(request.id, cfg);
    players.add(player);
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
  String? suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
}) =>
    Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
      duration: duration,
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

class _FakeCacheManager extends OfflineCacheManager {
  _FakeCacheManager(this.file);

  final File? file;

  @override
  Future<void> init() async {}

  @override
  File? songFile(String songId) => file;
}

class _NoopCastPeerController extends CastPeerController {
  _NoopCastPeerController(super.ref);

  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async => null;

  @override
  Future<void> syncLocalQueueNow() async {}
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
  String getStreamUrl(
    String songId, {
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) =>
      'http://192.168.10.240:46400/rest/stream?id=$songId';

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
  late _Cfg cfg;
  late _FakeJustAudioPlatform platform;

  ProviderContainer buildContainer({
    AudioQualityLevel quality = AudioQualityLevel.original,
  }) =>
      ProviderContainer(
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
          effectiveQualityProvider.overrideWithValue(quality),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          offlineCacheManagerProvider.overrideWithValue(_FakeCacheManager(null)),
          offlineCacheReadyProvider.overrideWith((ref) async {}),
          castPeerControllerProvider.overrideWith(
            (ref) => _NoopCastPeerController(ref),
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

  Future<void> pump([int times = 12]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({
    AudioQualityLevel quality = AudioQualityLevel.original,
  }) async {
    cfg = _Cfg();
    platform = _FakeJustAudioPlatform(cfg);
    JustAudioPlatform.instance = platform;
    container = buildContainer(quality: quality);
    final n = container.read(playerProvider.notifier);
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (i > 4 && !n.debugIsRestoringPlaybackSession) break;
    }
    return n;
  }

  _FakeAudioPlayerPlatform playerOf({int loads = 1}) {
    for (final p in platform.players) {
      if (p.count('load') >= loads) return p;
    }
    throw StateError('替身平台未初始化 / load 次数不足');
  }

  tearDown(() {
    container.dispose();
  });

  // ───────── persistPlaybackStateNow：等掉在飞写 + 退出补写音量 ─────────
  test('persistPlaybackStateNow 立即落盘音量（L2773/L2782 一带）', () async {
    notifier = await boot();
    await notifier.playSong(_song('s1'), queue: <Song>[_song('s1')]);
    await pump();
    expect(notifier.state.currentSong?.id, 's1');

    // 只改 UI 状态、不落盘（模拟拖动松手前的实时跟随）。
    notifier.setVolumeLive(0.42);
    expect(notifier.state.volume, closeTo(0.42, 1e-9));

    await notifier.persistPlaybackStateNow();

    expect(
      await LocalStorage.getPlayerVolume(),
      closeTo(0.42, 1e-9),
      reason: '退出落盘必须绕过 1s 防抖、立刻写盘音量',
    );
  });

  // ───────── setVolume：1s 防抖 Timer 回调 ─────────
  test('setVolume 防抖 1s 后真正落盘（L1855/L1857）', () async {
    notifier = await boot();
    await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
    await pump();

    await notifier.setVolume(0.33);
    expect(notifier.state.volume, closeTo(0.33, 1e-9));

    // 防抖还没到点时不应落盘（旧值 0.8/上一次）。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // 越过 1s 防抖窗口 → Timer 回调把 _volumePersistTimer 置空并写盘。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(
      await LocalStorage.getPlayerVolume(),
      closeTo(0.33, 1e-9),
      reason: '1s 防抖到期后 Timer 回调应落盘音量',
    );
  });

  // ───────── 播放模式持久化 + 启动恢复 ─────────
  test('setPlaybackMode(persist) 落盘模式（L2421/L2423）', () async {
    notifier = await boot();
    await notifier.setPlaybackMode(PlaybackMode.one);
    expect(notifier.state.playbackMode, PlaybackMode.one);
    expect(
      await LocalStorage.getPlaybackMode(),
      'one',
      reason: 'persist 默认 true 必须写 LocalStorage',
    );
  });

  test('启动时从 LocalStorage 恢复播放模式（L2408/L2413）', () async {
    await LocalStorage.setPlaybackMode('shuffle');
    notifier = await boot();
    expect(
      notifier.state.playbackMode,
      PlaybackMode.shuffle,
      reason: '_init → _restorePlaybackMode 应读回 shuffle',
    );
  });

  // ───────── durationStream：偏移 > 0 时保留逻辑时长（L623-628） ─────────
  test('整源重拉 seek 后 durationStream 保留逻辑时长（L623-628）', () async {
    notifier = await boot();
    await notifier.playSong(_song('s3'), queue: <Song>[_song('s3')]);
    await pump();
    final p = playerOf();
    expect(notifier.state.duration, const Duration(seconds: 200));

    // MusicFlow 服务端 → seek 走 timeOffset 整源重拉 → _sourcePositionOffset=90s。
    await notifier.seek(const Duration(seconds: 90));
    await pump();
    expect(p.count('load'), greaterThanOrEqualTo(2),
        reason: '应发生一次整源重拉（带 timeOffset）');

    // 重拉后 durationStream 再上报一个（不同的）流时长：偏移 > 0 且逻辑时长已知
    // → 必须保留逻辑时长、不覆盖。
    p.emit(const Duration(seconds: 199));
    await pump();

    expect(
      notifier.state.duration,
      const Duration(seconds: 200),
      reason: '偏移场景下 durationStream 不得覆盖已知逻辑时长（L623-628）',
    );
  });

  // ───────── durationStream：元数据缺失时 duration + offset（L665） ─────────
  test('元数据时长缺失 + 偏移时用 sourceDuration+offset（L665）', () async {
    notifier = await boot();
    // 流也上报 0 时长（老库/导入歌的元数据与流时长都缺失）。
    cfg.duration = Duration.zero;
    await notifier.playSong(
      _song('s4', suffix: 'flac', bitRate: 1411, duration: 0),
      queue: <Song>[_song('s4', suffix: 'flac', bitRate: 1411, duration: 0)],
    );
    await pump();
    final p = playerOf();
    expect(notifier.state.duration, Duration.zero,
        reason: '元数据缺失 → 初始 duration 为 0');

    await notifier.seek(const Duration(seconds: 90));
    await pump();

    // 重拉后流上报真实时长（>0）：元数据缺失 → 逻辑时长 = 流时长 + 偏移。
    p.emit(const Duration(seconds: 200));
    await pump();

    expect(
      notifier.state.duration,
      const Duration(seconds: 290),
      reason: '元数据缺失时应写回 duration + _sourcePositionOffset（L665）',
    );
  });
}
