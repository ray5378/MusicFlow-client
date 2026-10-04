// batch29-A：lib/providers/player/player_playback_helpers.dart 的**预探测 / 元数据补齐
// / 预跳过**三段（源码 13-71 `_enrichSongMetadata`、91-134 `_probeFresh` /
// `_probeNeedsRefresh` / `_maybeProbeNearEnd` / `_isKnownUnplayable`、149-171
// `_skipKnownUnplayable`、179-287 `_probeUpcoming`）。
//
// 与 batch28-A 同一套姿势：驱动**真实** `_PlayerNotifierImpl`，外部依赖全部 override 成桩。
//
// 本批新坑（接着 batch28-A 的 #169-D~#178-D 与 batch29-A crossfade 文件的 #187-D~#195-D）：
// #197-D 这三个 mixin 同样全是 `part of 'player_provider.dart'` 的**库私有**成员，
//       测试调不到 ⇒ 只能从公开 API 打进去。各函数的入口分别是：
//         * `_probeUpcoming` ← playSong 的 998 行 / `_maybeProbeNearEnd`
//         * `_maybeProbeNearEnd` ← positionStream 监听（590 行），emit 一次音源事件即命中
//         * `_isKnownUnplayable` ← `next()`（2094 行 `_skipKnownUnplayable`）
//         * `_enrichSongMetadata` ← playSong 1002 行的 `_scheduleSongRemoteRefresh`
// #198-D `_probeCache` 是**私有**的，测试没法直接摆条目。唯一合法写入口是让
//       `_probeUpcoming` 真的发一次 `/rest/api/v1/stream/probe` 并让替身客户端返回
//       带 `verdict` 的结果 —— 所以「预跳过」类用例的编排顺序固定为
//       **playSong（埋探测结论）→ 等 postRaw → next()（读结论预跳）**。
// #199-D `_maybeProbeNearEnd` 的节流读的是系统时钟（`DateTime.now()`），
//       `_nearEndProbeMinGap` 是 60s ⇒ 同一首歌第二次触发必然被 111-113 行节流挡掉，
//       所以「补探」与「被节流」这两条用例必须分别用**不同**的歌曲 id 铺底，
//       否则第二条永远测的是节流而不是真补探。
// #200-D `_probeUpcoming` 的 shuffe 分支要 `_srvShuffleOrder` 非空，而它只能由
//       `_refreshServerShuffleSeq()` 填，后者又要求 `castPeerControllerProvider`
//       的 `localPeerId` 非空。得额外 override 一个 `CastPeerController` 替身
//       （`castPeerControllerProvider` 是 `StateNotifierProvider<CastPeerController,
//       CastPeerState>`，替身必须 extends 它才能过 override 的类型检查）。
// #201-D 空队列守卫（180 行）用 `playSong(song, queue: <Song>[])` 就能逼出来：
//       此时 `state.currentSong` 非空而 `state.queue` 为空，正好只命中 `queue.isEmpty`。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
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
import 'package:musicflow_client/providers/player/player_state.dart';

// ─────────────────────────── 替身 just_audio 平台 ───────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  int loadCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int seekCount = 0;

  final List<String> loadedUris = <String>[];
  final List<double> volumeCalls = <double>[];

  var _tick = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  /// 踩坑 #202-D：`positionStream` 监听会先把 emit 的位置写进 `state.position`、
  /// `_maybeProbeNearEnd()` 才读 state ⇒ 「剩余多少秒」完全由这一下 emit 决定。
  /// 所以测试「末段补探」必须能钉住 emit 的位置，而不是去预设 state。
  Duration? emitPosOverride;

  void emit(ProcessingStateMessage state) {
    _tick += 1;
    final pos = emitPosOverride ?? Duration(seconds: _tick * 30);
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
  Future<PauseResponse> pause(PauseRequest request) async {
    pauseCount += 1;
    return PauseResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seekCount += 1;
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
  int initCount = 0;
  _FakeAudioPlayerPlatform? last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    initCount += 1;
    final player = _FakeAudioPlayerPlatform(request.id);
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
  String title = '',
  String suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
  bool isPreview = false,
}) =>
    Song(
      id: id,
      title: title.isEmpty ? '曲$id' : title,
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
      duration: duration,
      starred: false,
      isPreview: isPreview,
    );

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  final List<String> starredCalls = <String>[];
  final List<String> getSongCalls = <String>[];
  /// 返回 null 时 `_enrichSongMetadata` 在 16 行就 return；返回完整曲时走补齐分支。
  Song? getSongResult;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {
    starredCalls.add('$songId:$starred');
  }

  @override
  Future<Song?> getSong(String songId) async {
    getSongCalls.add(songId);
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

/// Subsonic 客户端替身：接管流地址生成 + 预探测 postRaw + 洗牌序列 getRaw。
class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  final List<String> getPaths = <String>[];
  final List<String> postPaths = <String>[];
  /// 每次 `/stream/probe` 请求体里带过去的 songIds（踩坑 #198-D 的观测窗）。
  final List<List<String>> probeSongIds = <List<String>>[];

  String streamUrl = 'http://192.168.10.240:46400/rest/stream?id=s1';

  /// `/rest/api/v1/stream/probe` 的返回值。默认空 ⇒ 不写任何探测结论。
  dynamic probeResult = <String, dynamic>{};
  bool throwOnProbe = false;

  /// `/rest/api/v1/peers/<pid>/queue/shuffle` 的返回值（shuffle 预探测分支用）。
  dynamic shuffleSeqResult = <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    getPaths.add(path);
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    // 踩坑 #202-D（playback_helpers 文件）：`_refreshServerShuffleSeq` 走的是
    // `getRaw` 而不是 `get`，观测窗必须一起记，否则「shuffle 分支真的去拉了
    // 服务端序列」这条断言永远是 false。
    getPaths.add(path);
    return shuffleSeqResult;
  }

  @override
  String getStreamUrl(
    String songId, {
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) =>
      streamUrl;

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    postPaths.add(path);
    if (path.endsWith('/stream/probe')) {
      probeSongIds.add(List<String>.from((data as Map)['songIds'] as List));
    }
    if (throwOnProbe) {
      throw StateError('probe boom');
    }
    return probeResult;
  }
}

/// `castPeerControllerProvider` 的替身（踩坑 #200-D）。
class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);

  /// 置成非空后 `_refreshServerShuffleSeq()` 才会去打 `/queue/shuffle`。
  String? peerIdOverride;

  @override
  String? get localPeerId => peerIdOverride;
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
  late _FakeCastPeerController peer;

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
          castPeerControllerProvider.overrideWith((ref) {
            peer = _FakeCastPeerController(ref);
            return peer;
          }),
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

  Future<void> waitUntil(bool Function() cond, {int ticks = 200}) async {
    for (var i = 0; i < ticks; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot() async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer();
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  /// 等预探测真的发过一次请求（playSong 里是 `unawaited(_probeUpcoming())`）。
  Future<void> waitProbe() async {
    await waitUntil(() => spy.probeSongIds.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  List<String> ids(List<Song> q) => q.map((s) => s.id).toList();

  setUp(() {
    repo.starredCalls.clear();
    repo.getSongCalls.clear();
    repo.getSongResult = null;
    spy.getPaths.clear();
    spy.postPaths.clear();
    spy.probeSongIds.clear();
    spy.throwOnProbe = false;
    spy.probeResult = <String, dynamic>{};
    spy.shuffleSeqResult = <String, dynamic>{};
  });

  tearDown(() => container.dispose());

  // ────────────────── 一、`_probeUpcoming` 的入口守卫（源码 180 / 242） ──────────────────
  group('_probeUpcoming · 早退', () {
    test('空队列 → 180 行直接 return，不发探测请求（源码 180）', () async {
      // 踩坑 #201-D：`queue: <Song>[]` 时 `state.currentSong` 仍是当前曲，
      // 只命中 `queue.isEmpty` 这半个守卫 —— 正好把 180 行的空队列侧单独钉住。
      notifier = await boot();
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[],
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(spy.probeSongIds, isEmpty, reason: '空队列不预探测');
      expect(notifier.state.currentSong?.id, 's1');
    });

    test('order 模式到末尾不回绕 → cands 为空，242 行 return', () async {
      // 228 行的 `else if` 为假（不是 all 模式）⇒ 窗口越界也不补候选 ⇒ 无候选可探。
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      await notifier.playSong(
        _song('s3'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        index: 2,
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(spy.probeSongIds, isEmpty, reason: 'order 末尾不回绕 ⇒ 无候选');
    });
  });

  // ────────────────── 二、候选收集（188 / 219-241） ──────────────────
  group('_probeUpcoming · 候选收集', () {
    test('线性窗口取后 3 首 → postRaw 带 songIds=[s2,s3,s4]', () async {
      notifier = await boot();
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3'), _song('s4')],
        autoPlay: false,
      );
      await waitProbe();

      expect(spy.probeSongIds.first, <String>['s2', 's3', 's4']);
      expect(spy.postPaths, contains('/rest/api/v1/stream/probe'));
    });

    test('远程歌 / 试听歌跳过预探测（188 行的 isRemoteSong）', () async {
      notifier = await boot();
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[
          _song('s1'),
          _song('s2', isPreview: true),
          _song('remote:9'),
          _song('s3'),
        ],
        autoPlay: false,
      );
      await waitProbe();

      expect(spy.probeSongIds.first, <String>['s3'],
          reason: '试听歌与 remote: 前缀歌都不该进候选（187-188 行）');
    });

    test('all 模式回绕 → 越过队尾后从队首补候选', () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.all,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      await notifier.playSong(
        _song('s3'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        index: 2,
        autoPlay: false,
      );
      await waitProbe();

      // idx=3/4/5 回绕成 0/1/2：wrap==currentIndex(2) 的那首自家跳过。
      // 候选 = 「回绕到队首的 s1 + 队次一首 s2」，不能只写 s2。
      expect(spy.probeSongIds.first, <String>['s1', 's2'],
          reason: 'idx=3→wrap0=s1、idx=4→wrap1=s2，idx=5→wrap2==currentIndex 跳过');
    });

    test('shuffle 模式 → 沿服务端洗牌序列取候选（源码 197-217）', () async {
      // 踩坑 #200-D：需要 `localPeerId` 非空 + `/queue/shuffle` 返回非空序列。
      notifier = await boot();
      peer.peerIdOverride = 'p1';
      spy.shuffleSeqResult = <String, dynamic>{
        'shuffleOrder': <int>[0, 1, 2, 3],
        'shufflePos': 0,
        'shuffleEpoch': 1,
      };
      notifier.state = notifier.state.copyWith(
        shuffleEnabled: true,
        playbackMode: PlaybackMode.shuffle,
        loopMode: LoopMode.off,
      );
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3'), _song('s4')],
        autoPlay: false,
      );
      await waitProbe();

      expect(spy.postPaths, anyOf(contains('/rest/api/v1/stream/probe')));
      expect(spy.probeSongIds.first, <String>['s2', 's3', 's4'],
          reason: 'pos=0 ⇒ 序列后续是 1/2/3 ⇒ 候选 s2/s3/s4');
      expect(
        spy.getPaths.any((p) => p.endsWith('/queue/shuffle')),
        isTrue,
        reason: 'shuffle 分支确实去拉了服务端序列',
      );
    });
  });

  // ────────────────── 三、探测结论固化（253-280） ──────────────────
  group('_probeUpcoming · 四态结论固化', () {
    test('verdict=unplayable → 落缓存，next() 预跳到再下一首', () async {
      // 踩坑 #198-D：`_probeCache` 私有，只能靠「探测 → next()」两步编排来观测。
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': false, 'verdict': 'unplayable'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2', title: '坏源'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentIndex, 2,
          reason: 's2 被判不可播 ⇒ 预跳过，直接落到 s3');
      expect(notifier.state.currentSong?.id, 's3');
      expect(ids(notifier.state.queue), <String>['s1', 's2', 's3'],
          reason: '预跳过只推进游标，不改队列（护栏 4）');
    });

    test('verdict=playable → 落缓存，next() 不预跳', () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': true, 'verdict': 'playable'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentIndex, 1, reason: 'playable 照常播下一首');
      expect(notifier.state.currentSong?.id, 's2');
    });

    test('transient / unknown → 不固化，next() 照常播（264 行 continue）', () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': false, 'verdict': 'transient'},
          <String, dynamic>{'songId': 's3', 'ok': true, 'verdict': 'unknown'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3'), _song('s4')],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentSong?.id, 's2',
          reason: 'transient/unknown 不是「已知不可播」⇒ 不预跳');
    });

    test('旧服务端无 verdict + ok=true → 推断 playable，固化后 next() 不预跳',
        () async {
      // 踩坑 #197-D：260-261 行的兜底是 `(r['verdict'] as String?) ??
      // (ok ? 'playable' : 'unknown')`。旧服务端只吐 ok 字段时，
      // 旧判据 = ok 直接当「能播」；新判据仍走 playable ⇒ 落缓存 ⇒ 不预跳。
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.all,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': true},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2', title: '老判据'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentSong?.id, 's2',
          reason: '无 verdict + ok=true ⇒ playable ⇒ 固化 ⇒ 不是「已知不可播」');
    });

    test('旧服务端无 verdict + ok=false → 推断 unknown，不固化，next() 照播',
        () async {
      // 踩坑 #197-D 的另一半：推断出的是 unknown 而不是 unplayable，
      // 264 行的 `continue` 照样不放行 ⇒ 缓存为空 ⇒ next() 不会预跳。
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.all,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': false},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2', title: '老判据'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentSong?.id, 's2',
          reason: '无 verdict + ok=false ⇒ unknown ⇒ 264 行 continue ⇒ 不固化');
    });

    test('songId 为空的条目被忽略（256-257 行）', () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': '', 'ok': true},
          <String, dynamic>{'songId': 's2', 'ok': false, 'verdict': 'unplayable'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2', title: '坏源'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentSong?.id, 's3',
          reason: '空 songId 只被 continue 跳过，不影响 s2 的结论');
    });

    test('postRaw 抛异常 → 281-283 catch，且不复发（finally 复位 _probing）',
        () async {
      notifier = await boot();
      spy.throwOnProbe = true;
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(spy.probeSongIds.length, 1, reason: '确实发过一次请求');
      // `_probing` 没被卡住 ⇒ 后续 `_maybeProbeNearEnd` 打的探测还能正常发出去。
      spy.throwOnProbe = false;
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': true, 'verdict': 'playable'},
        ],
      };
      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 195),
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      // 位置由 emit 带过去（踩坑 #202-D：copyWith 会被同一次 emit 覆盖）。
      platform.last!.emitPosOverride = const Duration(seconds: 195);
      platform.last!.emit(ProcessingStateMessage.ready);
      await waitUntil(() => spy.probeSongIds.length >= 2);

      expect(spy.probeSongIds.length, 2,
          reason: 'finally 复位后 `_probing` 能再次放行');
    });
  });

  // ────────────────── 四、`_maybeProbeNearEnd`（102-124） ──────────────────
  group('_maybeProbeNearEnd · 补探与节流', () {
    test('剩余 > 60s → 108 行 return，不发探测（源码 105-108）', () async {
      // 踩坑 #201-D：`platform.last` 是 `_IdleAudioPlayer` 之外的那个实例，
      // 只有真的 playSong 过（把 AudioPlayer 顶成非 idle）才非 null —— 直接
      // boot() 就 emit 会得到「null 检查未通过」的空转，用例看着绿其实没打中。
      //
      // 踩坑 #202-D（playback_helpers）：`positionStream` 监听会**先**把 emit 的
      // 位置写进 `state.position`、`_maybeProbeNearEnd()`**后**才读 state ——
      // 所以「剩余多少秒」是由**这一下 emit 的位置**决定的，靠 copyWith 预设
      // state.position 会被同一次 emit 覆盖掉，白设。
      notifier = await boot();
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        autoPlay: false,
      );
      spy.probeSongIds.clear();
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': true, 'verdict': 'playable'},
        ],
      };
      // emit 落在 10s ⇒ 剩余 190s ⇒ 108 行 return。
      platform.last!.emitPosOverride = const Duration(seconds: 10);
      platform.last!.emit(ProcessingStateMessage.ready);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(spy.probeSongIds, isEmpty,
          reason: '剩余 190s 远超 60s 提前量 ⇒ 不补探');
    });

    test('剩余 <= 60s → 打日志并发一次补探（源码 116-123）', () async {
      notifier = await boot();
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': true, 'verdict': 'playable'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe(); // 切歌那一次已探过 s2/s3
      spy.probeSongIds.clear();
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': false, 'verdict': 'unplayable'},
        ],
      };
      // 把进度推到末段 ⇒ remaining = 5s <= 60s 提前量（位置由下面这一下 emit 带过去）。
      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 195),
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      platform.last!.emitPosOverride = const Duration(seconds: 195);
      platform.last!.emit(ProcessingStateMessage.ready);
      await waitUntil(() => spy.probeSongIds.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(spy.probeSongIds.isNotEmpty, isTrue,
          reason: '末段补探该被触发（116-123 行）');
    });

    test('同曲 60s 内二次触发 → 被节流 return（110-113）', () async {
      // 踩坑 #199-D：上一条用例已经把 `_nearEndProbeSongId` 钉在 s1 上，
      // 所以这一条必须换一首**没探过**的歌，才能测出「补探真的发生了」；
      // 然后同曲再触发一次，才测出节流。
      notifier = await boot();
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': true, 'verdict': 'playable'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe();
      spy.probeSongIds.clear();
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's9', 'ok': true, 'verdict': 'playable'},
        ],
      };
      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 195),
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      platform.last!.emitPosOverride = const Duration(seconds: 195);
      platform.last!.emit(ProcessingStateMessage.ready);
      await waitUntil(() => spy.probeSongIds.isNotEmpty);
      expect(spy.probeSongIds.isNotEmpty, isTrue,
          reason: '首次末段触发应该真的补探（前置条件）');

      spy.probeSongIds.clear();
      // 节流判据是「同一首歌 + 60s 内」，跟位置无关，但位置还是得末段，
      // 否则 108 行先 return，测到的就不是节流而是提前量那条。
      platform.last!.emitPosOverride = const Duration(seconds: 196);
      platform.last!.emit(ProcessingStateMessage.ready);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(spy.probeSongIds, isEmpty,
          reason: '同一首歌 60s 内再触发 ⇒ 111-113 节流 return');
    });
  });

  // ────────────────── 五、`_isKnownUnplayable` / `_skipKnownUnplayable` ──────────────────
  group('_skipKnownUnplayable · 预跳过（149-171）', () {
    test('连续两首不可播 → 一次跳过两首，落到第三首且连跳合并成一条提示',
        () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': false, 'verdict': 'unplayable'},
          <String, dynamic>{'songId': 's3', 'ok': false, 'verdict': 'unplayable'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[
          _song('s1'),
          _song('s2', title: '坏源甲'),
          _song('s3', title: '坏源乙'),
          _song('s4'),
        ],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(notifier.state.currentIndex, 3, reason: 's2/s3 都被预跳过 ⇒ 落 s4');
      expect(notifier.state.currentSong?.id, 's4');
      // 走到「下一首也不可播」时 `_skipKnownUnplayable` 会提示（l10nNowCurrent
      // + ToastNotifier.show）；测试里没有 BuildContext，这里只钉「没抛异常」。
      expect(ids(notifier.state.queue), <String>['s1', 's2', 's3', 's4'],
          reason: '预跳过不改队列');
    });

    test('队列里没有不可播 → 下标原样返回（对照组，159 行为空）', () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.all,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.probeResult = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's2', 'ok': true, 'verdict': 'playable'},
        ],
      };
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        autoPlay: false,
      );
      await waitProbe();
      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentSong?.id, 's2');
    });
  });

  // ────────────────── 六、`_enrichSongMetadata`（13-71） ──────────────────
  group('_enrichSongMetadata · 元数据补齐（源码 13-71）', () {
    test('仓储返回完整曲 → 补齐当前曲并同步回队列（16/29-46 行）', () async {
      notifier = await boot();
      // 原曲故意缺 suffix/bitDepth/samplingRate/channelCount，
      // 让它落在 22-28 的 needsUpdate 为真的分支上。
      final raw = _song('s1');
      repo.getSongResult = raw.copyWith(suffix: 'flac', bitDepth: 24);
      final partial = Song(
        id: 's1',
        title: '曲s1',
        artist: '歌手',
        albumId: 'al1',
        bitRate: 1411,
        duration: 200,
      );
      await notifier.playSong(
        partial,
        queue: <Song>[partial],
        autoPlay: false,
      );
      await waitUntil(() => repo.getSongCalls.contains('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final cur = notifier.state.currentSong;
      expect(cur?.suffix, 'flac', reason: '补齐了缺失的 suffix（30 行）');
      expect(cur?.bitDepth, 24, reason: '补齐了 bitDepth');
      expect(ids(notifier.state.queue), <String>['s1']);
      expect(notifier.state.queue.first.suffix, 'flac',
          reason: '队列里同下标那一项也被同步（40-46 行）');
    });

    test('仓储返回 null → 16 行 return，state 一动不动', () async {
      notifier = await boot();
      repo.getSongResult = null;
      final raw = _song('s1');
      await notifier.playSong(
        raw,
        queue: <Song>[raw],
        autoPlay: false,
      );
      await waitUntil(() => repo.getSongCalls.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.currentSong?.suffix, 'flac');
      expect(notifier.state.currentSong?.title, '曲s1');
    });

    test('会话已切换 / 当前曲已换 → 丢弃补齐结果（18-20 行）', () async {
      notifier = await boot();
      repo.getSongResult = _song('s1').copyWith(suffix: 'mp3');
      final raw = _song('s1');
      await notifier.playSong(
        raw,
        queue: <Song>[raw],
        autoPlay: false,
      );
      await waitUntil(() => repo.getSongCalls.isNotEmpty);
      // 补齐还在飞的时候把当前曲换成 s9。
      notifier.state = notifier.state.copyWith(
        currentSong: _song('s9'),
        playbackMode: PlaybackMode.all,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(notifier.state.currentSong?.id, 's9');
      expect(notifier.state.currentSong?.suffix, 'flac',
          reason: '会话/曲目标已经变了 ⇒ 16-20 行的三道守卫把它丢掉');
    });
  });
}
