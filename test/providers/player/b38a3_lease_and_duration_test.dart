// b38a3 —— Route A 播放核心补测：**租约兜底 + 时长权威值 + Windows 播控**。
//
// 专啃 lcov 里仍 0 命中、靠「时间戳租约」才打得到的几条防御分支：
//   * player_provider 271/272/276/289：会话恢复租约（20s）超时后强制放行 ——
//     恢复流程里某个 await 永久挂起时，落盘闸门不能永久关闭（否则每次重启
//     都恢复成同一首旧歌）。用 `debugBeforeRestoreResume` 把恢复卡在起播前。
//   * player_playback_session 24/25/29：落盘租约（15s）超时后强制放行下一轮写。
//     用 `debugBeforePersistWrite` 把第一轮写卡在写盘前。
//   * player_provider 2797：`_awaitInFlightPersist` 的租约上限定时器 —— 退出
//     落盘时不能无限等在飞行的那一轮上。
//   * player_provider 647：元数据时长已知时，durationStream 上报值一律让位
//     （流报 210s、元数据 200s → 以 200s 为准写回）。
//   * player_provider 1502：Windows SMTC 投屏进度推送（带时长）。
//
// 本文件里两条租约用例各自要真等 ~20s / ~19s（租约就是按真实时间戳判定的，
// 无法用 fakeAsync 加速）——这是被测代码的设计选择，不是测试偷懒。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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

class _LoadCfg {
  bool throwOnLoad = false;
  Duration nextDuration = const Duration(seconds: 200);
}

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id, this.cfg);

  final _LoadCfg cfg;

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  var _tick = 0;

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
    if (cfg.throwOnLoad) throw StateError('load boom');
    final duration = cfg.nextDuration;
    scheduleMicrotask(() => emit(duration));
    return LoadResponse(duration: duration);
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
  final _LoadCfg cfg = _LoadCfg();
  _FakeAudioPlayerPlatform? last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      last = _FakeAudioPlayerPlatform(request.id, cfg);

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

Song _song(String id, {String suffix = 'mp3', int? bitRate = 320}) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
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

/// 投屏控制器替身：吐一份「服务端队列快照」，让恢复流程能走到起播前的挂起点
/// （本机无会话文件时，只有服务端快照胜出才会继续往下走）。
class _SnapCastPeerController extends CastPeerController {
  _SnapCastPeerController(super.ref, this.snap);

  final Map<String, dynamic>? snap;

  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async => snap;

  @override
  Future<void> syncLocalQueueNow() async {}
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

  ProviderContainer buildContainer({List<Override>? extra}) =>
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
          effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          offlineCacheManagerProvider.overrideWithValue(_FakeCacheManager(null)),
          offlineCacheReadyProvider.overrideWith((ref) async {}),
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

  Future<void> pump([int times = 10]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({List<Override>? extra}) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(extra: extra);
    final n = container.read(playerProvider.notifier);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 3 && !n.debugIsRestoringPlaybackSession) break;
    }
    return n;
  }

  tearDown(() {
    container.dispose();
  });

  // ── 271/272/276/289：会话恢复租约超时后强制放行 ──
  test('恢复租约超时 → 恢复标志强制失效(271/272/276/289)', () async {
    final restoreGate = Completer<void>();
    final snap = <String, dynamic>{
      'items': <dynamic>[
        <String, dynamic>{
          'songId': 's1',
          'title': '服务端曲',
          'artist': 'A',
          'album': 'B',
          'albumId': 'al1',
          'mime': 'audio/mpeg',
          'duration': 200,
        },
      ],
      'currentIndex': 0,
      'updatedAt': 9999999999999,
      'playMode': 'all',
    };
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(
      extra: <Override>[
        castPeerControllerProvider.overrideWith(
          (ref) => _SnapCastPeerController(ref, snap),
        ),
      ],
    );
    notifier = container.read(playerProvider.notifier);
    // 恢复跑在 _init() 的异步尾巴上；在它读到挂起点之前注入。
    notifier.debugBeforeRestoreResume = () => restoreGate.future;

    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (notifier.debugIsRestoringPlaybackSession) break;
    }
    expect(notifier.debugIsRestoringPlaybackSession, isTrue,
        reason: '恢复应被注入点卡在起播之前');

    // 租约 20s：超时即视为恢复已结束，强制放行落盘闸门。
    await Future<void>.delayed(const Duration(seconds: 21));
    expect(notifier.isRestoringPlaybackSession, isFalse,
        reason: '租约超时后恢复标志必须强制失效（否则落盘永久被跳过）');
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── 24/25/29 + 2797：落盘租约超时后强制放行下一轮写 ──
  test('落盘租约超时 → 强制放行本轮写(24/25/29, 2797)', () async {
    notifier = await boot();
    // 非空队列：否则 payload 为 null，_persistOnce 在挂起点之前就 return 了。
    // 用「当前曲/游标」当标记位 —— 进度会被位置轮询器每 500ms 按底层播放器
    // 位置重写，不能当观测点。
    notifier.state = notifier.state.copyWith(
      currentSong: _song('a'),
      queue: <Song>[_song('a'), _song('b')],
      currentIndex: 0,
    );

    final hang = Completer<void>();
    notifier.debugBeforePersistWrite = () => hang.future;
    // 立即落盘（不等待 5s 防抖）→ 这一轮会挂在写盘前，租约一直握着。
    unawaited(notifier.persistPlaybackStateNow());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 之后的新一轮写不再挂起；已在飞行中的那轮仍然挂着。
    notifier.debugBeforePersistWrite = null;

    // 等到超过 15s 落盘租约。
    await Future<void>.delayed(const Duration(seconds: 12));
    // 再触发一次防抖落盘（5s Timer）：此刻应撞上「租约过期 → 强制放行」。
    notifier.state = notifier.state.copyWith(
      currentSong: _song('b'),
      currentIndex: 1,
    );
    await Future<void>.delayed(const Duration(seconds: 7));

    final session = await LocalStorage.getPlaybackSession();
    expect(session, isNotNull,
        reason: '租约过期后本轮写必须真正落地（否则磁盘上永远是上一轮旧会话）');
    expect(session!['currentSongId'], 'b');
    expect(session['currentIndex'], 1);

    hang.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── 647：元数据时长已知 → 以元数据为准写回 ──
  test('元数据时长已知 → 流上报时长让位(647)', () async {
    notifier = await boot();
    await notifier.playSong(_song('a'), autoPlay: false);
    await pump();
    expect(notifier.state.duration, const Duration(seconds: 200));

    // UI 侧时长被写到 100s 时，流又上报了 210s：应以元数据 200s 为准补回。
    notifier.state = notifier.state.copyWith(
      duration: const Duration(seconds: 100),
    );
    platform.last!.emit(const Duration(seconds: 210));
    await pump();

    expect(notifier.state.duration, const Duration(seconds: 200),
        reason: '元数据时长优先：流上报的 210s 不得覆盖/成为权威值');
  });

  // ── 1502：Windows SMTC 投屏进度推送（含时长） ──
  test('Windows SMTC 投屏进度推送带时长(1502)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    notifier = await boot();
    // 不起播：位置轮询器会按底层播放器位置每 500ms 重写 state.position，
    // 起播后它会盖掉这里的观测值（currentSong == null 时轮询器直接 return）。
    notifier.state = notifier.state.copyWith(
      position: const Duration(seconds: 7),
      duration: const Duration(seconds: 200),
    );

    notifier.updateNotificationCastProgress(
      active: true,
      playing: true,
      position: const Duration(seconds: 99),
    );
    await pump();

    expect(notifier.state.position, const Duration(seconds: 7),
        reason: '投屏进度只喂系统播控中心，不得覆写本机进度');
  });
}
