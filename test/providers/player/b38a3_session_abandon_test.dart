// b38a3 —— Route A 播放核心补测：**播放会话代际作废（session abandoned）分支**。
//
// lcov 里 player_provider 仍 0 命中、且能经公开 API 稳定打进去的一族分支：
//   * 等待可用地址期间被新 playSong 取代（1103/1105）；
//   * 音源加载失败后本轮已被取代 → 放弃转码重试（1246/1247）；
//   * 刷新线路之后才被取代（1266/1268）；
//   * 转码重试链路：进入 mp3 兜底的两条留痕（1335/1342）、setUrl 失败留痕
//     （1376）、转码失败刷新线路后被取代（1414/1416）；
//   * 试听（preview）链路的同族两条（1751/1753、1759/1761）；
//   * `_replaceLoadedSource` 入口「加载前即已不属于本次上下文」留痕
//     （player_seek 373）。
//
// 姿势：与既有 b38a/b38a2 系列一致 —— 驱动**真实** `_PlayerNotifierImpl`，
// just_audio 平台换替身，外部 provider 全桩。时序控制全部走**注入闸门**，
// 不用 sleep 猜时长：
//   * 音源加载闸门：`_LoadCfg.gate` / `throwOnLoad`（假平台 load()）；
//   * 地址等待闸门：`pool.activeAddr` 置空后走 `ensureActiveAddressProvider`；
//   * 路由刷新闸门：`_FakeAddressPool.probeAll()` 按调用序号挂起。
// 「新 playSong 抢占」用**同步调用** playSong 完成 —— 会话号在第一个 await
// 之前就自增（player_provider 928），所以同步调用即可确定性地作废上一轮；
// 抢占方自己停在地址闸门上，不发起第二次 setUrl（两个 setUrl 在 just_audio
// 内部会互相顶掉，导致先发起的那个 Future 永不完成）。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
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

/// 音源加载的可变闸门：测试可在任意时刻挂起/放行/打爆 load()。
class _LoadCfg {
  /// 非空时 `load()` 先等它完成（用来把播放流程精确停在加载中）。
  Completer<void>? gate;

  /// 置真后 `load()` 抛错（用来走播放失败兜底）。
  bool throwOnLoad = false;

  int loadCount = 0;
}

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id, this.cfg);

  final _LoadCfg cfg;

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  final List<String> loadedUris = <String>[];

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
    cfg.loadCount += 1;
    final gate = cfg.gate;
    if (gate != null) await gate.future;
    if (cfg.throwOnLoad) throw StateError('load boom');
    final message = request.audioSourceMessage;
    if (message is UriAudioSourceMessage) {
      loadedUris.add(message.uri);
    }
    scheduleMicrotask(() => emit(ProcessingStateMessage.ready));
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
  final _LoadCfg cfg = _LoadCfg();

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      _FakeAudioPlayerPlatform(request.id, cfg);

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
  bool isPreview = false,
  String? previewStreamUrl,
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
      coverArt: coverArt,
      isPreview: isPreview,
      previewStreamUrl: previewStreamUrl,
    );

ServerAddress _addr({ServerAddressStatus status = ServerAddressStatus.ok}) =>
    ServerAddress(
      id: 'a1',
      libraryId: 'lib1',
      label: '主库',
      url: 'http://192.168.10.240:46400',
      priority: 0,
      status: status,
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

/// 地址池替身：
///   * `activeAddr` 置空 → 播放流程会落进「等待可用地址」的分支并停在那里；
///   * `probeAll()` 按**调用序号**挂起 → 把流程精确停在「刷新线路」那一步。
class _FakeAddressPool extends AddressPool {
  _FakeAddressPool()
      : super(Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  ServerAddress? activeAddr;

  /// 第 n 次 probeAll 的闸门；未配置则用 [immediate] 直接返回。
  final Map<int, Completer<ServerAddress?>> gates =
      <int, Completer<ServerAddress?>>{};

  /// 无闸门时的探测结果（null → 无可用线路）。
  ServerAddress? immediate;

  int calls = 0;

  @override
  ServerAddress? get activeAddress => activeAddr;

  @override
  Future<ServerAddress?> probeAll() async {
    final index = calls++;
    final gate = gates[index];
    if (gate == null) return immediate;
    return gate.future;
  }

  @override
  List<ServerAddress> get addresses {
    final current = immediate;
    return current == null ? const <ServerAddress>[] : <ServerAddress>[current];
  }
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
  final pool = _FakeAddressPool();
  late _FakeJustAudioPlatform platform;

  /// 「等待可用地址」的闸门：默认不放行，测试按需 complete。
  late Completer<ServerAddress> addrGate;

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
          ensureActiveAddressProvider.overrideWith((ref) => addrGate.future),
          addressPoolProvider.overrideWithValue(pool),
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

  /// 让在途的异步流程跑够轮次（闸门之外的步骤都是同步/微任务，200ms 足够）。
  Future<void> pump() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
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

  /// 抢占当前播放会话：抽掉活跃地址后同步发起 playSong —— 会话号立即自增，
  /// 而它自己停在地址闸门上，不会再发起一次 setUrl。
  void preempt() {
    pool.activeAddr = null;
    unawaited(notifier.playSong(_song('z')));
  }

  setUp(() {
    pool.activeAddr = _addr();
    pool.immediate = null;
    pool.gates.clear();
    pool.calls = 0;
    addrGate = Completer<ServerAddress>();
  });

  tearDown(() {
    container.dispose();
  });

  // ── 1103/1105：等待可用地址期间被新 playSong 取代 ──
  test('地址等待期间被新 playSong 取代 → 放弃本轮(1103/1105)', () async {
    pool.activeAddr = null; // 两轮都要等地址
    notifier = await boot();

    final first = notifier.playSong(_song('a')); // 会话 1 → 停在地址等待
    final second = notifier.playSong(_song('b')); // 会话 2 → 会话 1 作废
    await pump();
    addrGate.complete(_addr());

    await pump();
    await first.timeout(const Duration(seconds: 10));
    await second.timeout(const Duration(seconds: 10));

    // 会话 1 在 1102 判定作废并 return，最终落地的是会话 2 的曲。
    expect(notifier.state.currentSong?.id, 'b');
  });

  // ── 1246/1247：加载失败时本轮已被取代 → 放弃转码重试 ──
  test('音源加载失败后被新 playSong 取代 → 放弃转码重试(1246/1247)', () async {
    notifier = await boot();
    final cfg = platform.cfg;
    cfg.gate = Completer<void>();
    cfg.throwOnLoad = true;
    pool.immediate = _addr(); // 有线路：未被作废的话会继续走 mp3 转码重试

    // mp3 无需转码 → 失败后的兜底是 _playWithTranscoding（会再发起一次加载）。
    final first = notifier.playSong(_song('a', suffix: 'mp3'));
    await pump();
    expect(cfg.loadCount, 1, reason: '会话 1 应停在音源加载闸门上');

    preempt();
    await pump();
    cfg.gate!.completeError(StateError('load boom'));
    await pump();
    await first.timeout(const Duration(seconds: 10));

    expect(cfg.loadCount, 1,
        reason: '会话 1 已被作废：不应再发起 mp3 转码重试的那次加载');
  });

  // ── 1266/1268：刷新线路之后才被取代 ──
  test('刷新线路期间被新 playSong 取代 → 放弃本轮(1266/1268)', () async {
    notifier = await boot();
    platform.cfg.throwOnLoad = true; // 加载立即失败 → 进刷新线路
    pool.immediate = _addr(); // 有线路：未被作废则继续走转码重试
    pool.gates[0] = Completer<ServerAddress?>(); // 第 1 次 probeAll 挂起

    final first = notifier.playSong(_song('a'));
    await pump();
    expect(pool.calls, 1, reason: '会话 1 应停在刷新线路上');

    preempt();
    await pump();
    pool.gates[0]!.complete(_addr());
    await pump();
    await first.timeout(const Duration(seconds: 10));

    expect(platform.cfg.loadCount, 1,
        reason: '刷新线路后发现会话已被取代：不再发起转码重试');
  });

  // ── 1335/1342/1376 + 1414/1416：转码重试链路 ──
  test('转码重试 setUrl 失败后刷新线路被取代(1335/1342/1376/1414/1416)', () async {
    notifier = await boot();
    platform.cfg.throwOnLoad = true; // 直连与转码两次 setUrl 都失败
    pool.immediate = _addr();
    pool.gates[0] = Completer<ServerAddress?>()..complete(_addr());
    pool.gates[1] = Completer<ServerAddress?>(); // 第 2 次探测(1412)挂起

    final first = notifier.playSong(_song('a', suffix: 'mp3'));
    await pump();
    // 直连 1 次 + mp3 转码 1 次，然后停在 1412 的探测闸门上。
    expect(platform.cfg.loadCount, 2,
        reason: '应已尝试直连与 mp3 转码两次加载');

    preempt();
    await pump();
    pool.gates[1]!.complete(null);
    await pump();
    await first.timeout(const Duration(seconds: 10));

    expect(platform.cfg.loadCount, 2,
        reason: '转码失败刷新线路后被取代：不再跳下一首');
  });

  // ── 1751/1753：试听加载失败时被取代 ──
  test('试听加载失败后被新 playSong 取代(1751/1753)', () async {
    notifier = await boot();
    final cfg = platform.cfg;
    cfg.gate = Completer<void>();
    cfg.throwOnLoad = true;
    pool.immediate = _addr(); // 有线路：未被作废则走 _handlePlaybackError 跳歌

    final preview = _song(
      'p1',
      suffix: 'mp3',
      isPreview: true,
      previewStreamUrl: 'https://music.example.test/preview/p1.mp3',
    );
    final first = notifier.playSong(preview);
    await pump();
    expect(cfg.loadCount, 1, reason: '试听曲应停在音源加载闸门上');

    preempt();
    await pump();
    cfg.gate!.completeError(StateError('load boom'));
    await pump();
    await first.timeout(const Duration(seconds: 10));

    expect(cfg.loadCount, 1, reason: '试听本轮已作废：不再跳下一首');
  });

  // ── 1759/1761：试听刷新线路后被取代 ──
  test('试听刷新线路期间被新 playSong 取代(1759/1761)', () async {
    notifier = await boot();
    platform.cfg.throwOnLoad = true;
    pool.immediate = _addr();
    pool.gates[0] = Completer<ServerAddress?>();

    final preview = _song(
      'p1',
      suffix: 'mp3',
      isPreview: true,
      previewStreamUrl: 'https://music.example.test/preview/p1.mp3',
    );
    final first = notifier.playSong(preview);
    await pump();
    expect(pool.calls, 1, reason: '试听曲应停在刷新线路上');

    preempt();
    await pump();
    pool.gates[0]!.complete(_addr());
    await pump();
    await first.timeout(const Duration(seconds: 10));

    expect(platform.cfg.loadCount, 1, reason: '试听本轮已作废：不再跳下一首');
  });

  // ── player_seek 373：加载前即已不属于本次播放上下文 ──
  test('加载前当前曲已被换掉 → 源装配直接放弃(player_seek 373)', () async {
    pool.activeAddr = null; // 停在地址等待，便于在加载前改掉当前曲
    notifier = await boot();
    final cfg = platform.cfg;

    final first = notifier.playSong(_song('a')); // 停在地址等待
    await pump();

    // 地址就绪前当前曲被换掉：ownsSource() 判否 → 装配在加载前就放弃。
    notifier.state = notifier.state.copyWith(currentSong: _song('zzz'));
    addrGate.complete(_addr());
    await pump();
    await first.timeout(const Duration(seconds: 10));

    expect(cfg.loadCount, 0, reason: '上下文已失效，不应发起音源加载');
    expect(notifier.state.currentSong?.id, 'zzz');
  });
}
