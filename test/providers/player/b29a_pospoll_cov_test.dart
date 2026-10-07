// batch29-A：lib/providers/player/player_position_polling.dart（326 行）的
// 位置轮询定时器主体 `_startPositionPolling`（源码 9-324）。
//
// 这条函数是**纯 Timer.periodic(500ms) 驱动**的看门狗集合：
//   * 12-13 行 早退（mounted / 无当前曲）
//   * 14-16 行 seek 位置保护期早退
//   * 26-34 行 seek 落位宽限窗
//   * 72-105 行「0 秒卡死」计数 vs「停滞」计数（两条互相清零的计数器）
//   * 116-127 行 近末尾(Windows)计数
//   * 136-180 行 0 秒卡死看门狗：重载自愈 → 超容错放弃跳下一首
//   * 194-231 行 drift>=250 的三种出路（同步 / 保合成 / 跳过+日志）
//   * 235-254 行 合成进度兜底日志
//   * 263-283 行 近末尾看门狗 → _onSongCompleted
//   * 290-305 行 停滞看门狗 → next()
//   * 309-322 行 合成进度按 500ms 时间片推进
//
// 与 batch28-A / batch29-A 前两个文件同一套姿势：驱动**真实** `_PlayerNotifierImpl`，
// 外部依赖全部 override 成桩，只从公开 API（playSong / next / seek）打进去。
//
// 本批新坑（接着 batch29-A crossfade 的 #187-D~#196-D 与 playback_helpers 的 #197-D~#201-D）：
// #203-D 轮询体是 `Timer.periodic(500ms)` 的**一次回调**，所有阈值都是**tick 数**
//       （停滞 10 tick=5s、0 秒卡死 12 tick=6s、近末尾 5 tick=2.5s）。测试里 tick 只能
//       **真等**，所以每个看门狗用例都是秒级用例；断言必须写 `await waitUntil(...)`，
//       不能 `await Future.delayed(固定值)` 之后读一个「应该已经 happened」的状态。
// #204-D 两个计数器 `_startupStuckTicks` 与 `_stagnantPositionTicks` **互相清零**：
//       84-92 行「位置 > 1.5s ⇒ 视为已开始播」会同时清 `_startupReloadStreak` 与
//       `_startupStuckSongId`，而 99-105 行 `atStart` 会把 `_stagnantPositionTicks`
//       清零。所以「0 秒卡死」用例里必须让替身播放器**始终报 <=1.5s 的位置**，
//       任何一次报了 >1.5s 都会把测试拖成「从 1 重新计数」。
// #205-D 替身 `emit(ProcessingStateMessage.ready)` 里 updatePosition 是**递增的**
//       （batch28-A 踩坑 #171-D 的绕开去重写法），所以「让位置不动」不能靠不 emit，
//       得显式把 `emitPosOverride` 钉住 —— 源码 60 行的 `deltaFromLast` 才是停滞判据。
// #206-D `_onSongCompleted` / `_handlePlaybackError` 是**库私有**成员，测试调不到：
//       只能通过「当前曲 id 变了」或「替身播放器 reload 次数变了」去间接观测它们的副作用。
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

// ───────────────────────────── 替身 just_audio 平台 ───────────────────────────

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

  /// 踩坑 #205-D：替身默认让 updatePosition 递增；置成非 null 后 emit 会
  /// 把它钉在这个值上 —— 这才是测试「位置不动 ⇒ 停滞」的唯一开关。
  Duration? emitPosOverride;

  ///「确实在播」信号：processing==ready 才算（源码 21-22 的 isReadyPlaying）。
  ProcessingStateMessage emitState = ProcessingStateMessage.ready;

  var _tick = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void emit([ProcessingStateMessage? state]) {
    _tick += 1;
    final pos = emitPosOverride ?? Duration(seconds: _tick * 30);
    _events.add(
      PlaybackEventMessage(
        processingState: state ?? emitState,
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
    // 踩坑 #170-D：不吐 ready，`setUrl()` 会永久挂在等 processingState 离开 loading。
    scheduleMicrotask(() => emit());
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

// ───────────────────────────── 其它桩 ─────────────────────────────

Song _song(String id, {int duration = 200}) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'flac',
      bitRate: 1411,
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

/// Subsonic 客户端替身：轮询体不打预探测，只要它不真发网络即可。
class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  final List<String> getPaths = <String>[];
  final List<String> postPaths = <String>[];
  final List<List<String>> probeSongIds = <List<String>>[];

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
    getPaths.add(path);
    return <String, dynamic>{};
  }

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
    return <String, dynamic>{};
  }

  @override
  String getStreamUrl(
    String songId, {
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) =>
      'http://192.168.10.240:46400/rest/stream?id=$songId';
}

/// `castPeerControllerProvider` 的替身：轮询体不打 cast 路径，给个空壳即可，
/// 但类型得像（踩坑 #200-D：必须 extends 才能过 override 的类型检查）。
class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);

  @override
  String? get localPeerId => null;
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
            return _FakeCastPeerController(ref);
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

  Future<void> waitUntil(bool Function() cond, {int ticks = 400}) async {
    for (var i = 0; i < ticks; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// 轮询 tick 是 500ms 一跳，`ticks` 就是等几跳。
  Future<void> waitTicks(int ticks) async =>
      Future<void>.delayed(Duration(milliseconds: 500 * ticks + 120));

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

  /// 激活替身播放器：没加载过音源时 `AudioPlayer._platform` 是 `_IdleAudioPlayer`，
  /// `init()` 不会被调 ⇒ 容器 boot 完直接 emit 事件收不到（batch28-A 命门）。
  Future<_FakeAudioPlayerPlatform> activate(List<Song> queue) async {
    await notifier.playSong(
      _song('s1'),
      queue: queue,
      index: 0,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return platform.last!;
  }

  setUp(() {
    spy.getPaths.clear();
    spy.postPaths.clear();
    spy.probeSongIds.clear();
  });

  tearDown(() => container.dispose());

  // ──────────────────── 一、早退分支（12-16） ────────────────────
  group('轮询早退 · mounted / 无当前曲 / seek 保护期（源码 12-16）', () {
    test('state.currentSong == null → 定时器空转，不写 state.position',
        () async {
      // 踩坑 #206-D：boot() 之后 currentSong 是 null（没有恢复的会话），
      // 此时 `_startPositionPolling` 已经在跑，逐 tick 早退。
      notifier = await boot();
      expect(notifier.state.currentSong, isNull);
      final before = notifier.state.position;

      await waitTicks(3);

      expect(notifier.state.position, before,
          reason: '无当前曲 ⇒ 13 行 return，位置从不被写');
    });

    test('_shouldPreserveSeekPosition() 为真（pending 路径）→ 14-16 行早退，位置宁可不同步',
        () async {
      // 关键修正：保护期必须走 **pending 路径**才持久。
      //   - active 路径（player_provider.dart:2271-2272 设 _activeSeekSongId）
      //     在 fake 替身下 seek 瞬时 resolve，`_releaseSeekAnchor` 立刻清掉
      //     _activeSeekSongId（player_seek.dart:437-441）⇒ 保护期一闪即逝。
      //   - pending 路径（player_provider.dart:2261-2268）仅在 canSeekNow==false
      //     时把目标钉进 _pendingSeekPosition，只要没被 apply 就恒为真。
      // 让 fake 玩家停在 loading 即可逼出 pending 路径：
      //   canSeekLoadedPlayerSource 只在 processingState==loading 时返回 false
      //   （player_seek_policy.dart:20）。
      notifier = await boot();
      final p = await activate(<Song>[_song('s1', duration: 200)]);

      // 把玩家钉在 loading（不可 seek）⇒ seek() 走 pending 分支。
      // 必须先等 just_audio 把这条 loading 事件处理进 processingState getter，
      // 否则 seek() 读到的还是上一跳 load 的 ready ⇒ 走 active 分支 ⇒
      // _reloadStreamForSeek→player.setUrl→假的 load 又 emit 出 loading，
      // just_audio 的 load 永远等不到 loading→ready 而挂死（30s 超时）。
      // pending 分支在 setUrl 之前就 return，不会触发这条挂死链。
      p.emitState = ProcessingStateMessage.loading;
      p.emit();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 100),
        duration: const Duration(seconds: 200),
      );
      // seek 目标落中段；pending 分支会把 _pendingSeekPosition=100s 钉住，
      // 轮询体每个 tick 在 14-16 行早退，跳过 194-207 的 drift 同步。
      await notifier.seek(const Duration(seconds: 100));

      // source 报 500ms（与 state 100s 形成巨大 drift）；若 14-16 行没早退，
      // 194-207 行会把 state.position 覆盖成 ~500ms。
      p.emitPosOverride = const Duration(milliseconds: 500);
      p.emit();

      await waitTicks(2);

      expect(notifier.state.position, const Duration(seconds: 100),
          reason: '保护期内位置不被 source 覆盖（14-16 行 return）');
    });
  });

  // ──────────────────── 二、正常位置同步（194-207） ────────────────────
  group('drift >= 250 → 对齐 UI 进度（源码 194-207）', () {
    test('source 位置大幅前移 → state.position 被同步成 _logicalPlayerPosition',
        () async {
      notifier = await boot();
      final p = await activate(<Song>[_song('s1', duration: 200)]);

      notifier.state = notifier.state.copyWith(position: Duration.zero);
      p.emitPosOverride = const Duration(seconds: 100);
      p.emit();
      await waitTicks(2);

      expect(
        notifier.state.position,
        greaterThan(const Duration(seconds: 90)),
        reason: 'drift≈100s ≥ 250ms ⇒ 走 206 行 copyWith(position: playerPos)',
      );
    });

    test('drift < 250 → 不写 state（保留本地进度）', () async {
      notifier = await boot();
      final p = await activate(<Song>[_song('s1', duration: 200)]);

      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 50),
        duration: const Duration(seconds: 200),
      );
      p.emitPosOverride = const Duration(seconds: 50, milliseconds: 50);
      p.emit();
      await waitTicks(2);

      expect(notifier.state.position, const Duration(seconds: 50),
          reason: '只有 50ms 漂移 ⇒ 206 行不触发');
    });
  });

  // ──────────────────── 三、停滞计数（99-105） ────────────────────
  group('停滞计数 · deltaFromLast 与 stallSignal（源码 99-105）', () {
    test('位置不动 + ready + playing → 累计停滞 tick，到 10 tick 跳下一首',
        () async {
      // 踩坑 #203-D：阈值是 10 tick = 5s，只能真等。
      notifier = await boot();
      final p = await activate(
          <Song>[_song('s1', duration: 200), _song('s2', duration: 200)]);
      await notifier.play(); // 让 player.playing=true，停滞看门狗才会累计（源码 21-22/47）

      // 位置钉死在 30s（> atStart 的 1.5s，所以走 stagn 分支而不是 startup 分支）
      p.emitPosOverride = const Duration(seconds: 30);
      p.emit();
      final pin = Timer.periodic(const Duration(milliseconds: 40), (_) => p.emit());
      addTearDown(pin.cancel);
      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 200),
      );
      final before = notifier.state.currentSong?.id;

      await waitUntil(() => notifier.state.currentSong?.id != before,
          ticks: 600);

      expect(notifier.state.currentSong?.id, 's2',
          reason: '停滞看门狗（290-305 行）跳到了下一首');
    });

    test('processing 非 ready（buffering）→ stallSignal 为假，停滞计数被清零',
        () async {
      // 移动端语义：stallSignal = isReadyPlaying（源码 21-22/47 行）。
      // 卡在 buffering 时即使位置不动也**不该**被判死。
      notifier = await boot();
      final p = await activate(<Song>[_song('s1', duration: 200)]);
      await notifier.play(); // playing=true 但 emitState=buffering ⇒ stallSignal=false，停滞计数恒清零

      p.emitPosOverride = const Duration(seconds: 30);
      p.emitState = ProcessingStateMessage.buffering;
      p.emit();
      final pin = Timer.periodic(const Duration(milliseconds: 40), (_) => p.emit());
      addTearDown(pin.cancel);
      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 200),
      );
      final before = notifier.state.currentSong?.id;

      await waitTicks(6); // 6 tick > 但 < 10 tick 阈值

      expect(notifier.state.currentSong?.id, before,
          reason: 'buffering 期间 stallSignal 为假 ⇒ 计数恒清零');
    });
  });

  // ──────────────────── 四、0 秒卡死看门狗（136-180） ────────────────────
  group('0 秒卡死看门狗 · 重载自愈与放弃（源码 136-180）', () {
    test('卡在起点 12 tick → 重载同一首（自愈，不换歌）', () async {
      // 踩坑 #204-D：位置必须**始终 <= 1.5s**，否则 84-92 行把「已开始播」判定为真，
      // 计数器被清零 ⇒ 永远攒不到 12 tick。
      notifier = await boot();
      final p = await activate(<Song>[_song('s1', duration: 200)]);
      await notifier.play(); // playing=true 让 _startupStuckTicks 累计（源码 72-81）

      // 踩坑补充：just_audio 的 `player.position` 在 playing 时会按
      // `updateTime` 实时插值（pos = updatePosition + (now - updateTime)），
      // 只钉一次 emitPosOverride 会被插值冲掉、位置一路涨过 1.5s ⇒ atStart 失守、
      // 0 秒卡死看门狗永远攒不到 12 tick。必须高频重 emit 刷新 updateTime 把位置钉死。
      p.emitPosOverride = const Duration(milliseconds: 500);
      p.emit();
      final pin = Timer.periodic(const Duration(milliseconds: 40), (_) => p.emit());
      addTearDown(pin.cancel);
      notifier.state = notifier.state.copyWith(
        position: Duration.zero,
        duration: const Duration(seconds: 200),
      );
      final loadBefore = p.loadCount;
      final songBefore = notifier.state.currentSong?.id;

      await waitTicks(14);

      // ignore: avoid_print
      print('DIAG t1 load=${p.loadCount}(before=$loadBefore) seek=${p.seekCount} '
          'play=${p.playCount} pos=${notifier.state.position} song=${notifier.state.currentSong?.id}');

      expect(notifier.state.currentSong?.id, songBefore,
          reason: '自愈路径只 reload，不换歌（170-177 行 playSong(同一首)）');
      expect(p.loadCount, greaterThan(loadBefore),
          reason: '替身被 reload ⇒ 看门狗确实触发了');
    });

    test('同一首连续触顶超容错 → 放弃重载并跳下一首（151-162 行）', () async {
      // 第一轮攒 12 tick 触发重载（_startupReloadStreak=1 < tolerance=2）；
      // 重载后依旧卡 0 秒 ⇒ 第二轮再攒 12 tick ⇒ streak=2 ⇒ 判死跳下一首。
      notifier = await boot();
      final p = await activate(
          <Song>[_song('s1', duration: 200), _song('s2', duration: 200)]);
      await notifier.play(); // playing=true 让两轮 0 秒卡死看门狗都能累计

      p.emitPosOverride = const Duration(milliseconds: 500);
      p.emit();
      final pin = Timer.periodic(const Duration(milliseconds: 40), (_) => p.emit());
      addTearDown(pin.cancel);
      notifier.state = notifier.state.copyWith(
        position: Duration.zero,
        duration: const Duration(seconds: 200),
      );

      var reached = false;
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        // ignore: avoid_print
        print('T2 #$i load=${p.loadCount} seek=${p.seekCount} '
            'play=${p.playCount} pos=${notifier.state.position} song=${notifier.state.currentSong?.id}');
        if (notifier.state.currentSong?.id == 's2') {
          reached = true;
          break;
        }
      }
      expect(notifier.state.currentSong?.id, 's2',
          reason: '连续两轮 0 秒卡死 ⇒ 放弃重载、走 _handlePlaybackError 跳下一首');
    });
  });

  // ──────────────────── 五、近末尾看门狗（116-127 / 263-283） ────────────────────
  group('近末尾看门狗 · treat as completed（源码 116-127 / 263-283）', () {
    test('末段 5 tick 不前进 → 视为播完并接续下一首', () async {
      // duration - position <= 2.5s 且位置不再前进 ⇒ 累计 5 tick。
      notifier = await boot();
      final p = await activate(
          <Song>[_song('s1', duration: 200), _song('s2', duration: 200)]);
      await notifier.play(); // playing=true 让近末尾看门狗 endEngaged 成立（源码 120-122）

      p.emitPosOverride = const Duration(seconds: 198);
      p.emit();
      final pin = Timer.periodic(const Duration(milliseconds: 40), (_) => p.emit());
      addTearDown(pin.cancel);
      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 198),
        duration: const Duration(seconds: 200),
      );
      final before = notifier.state.currentSong?.id;

      await waitUntil(() => notifier.state.currentSong?.id != before,
          ticks: 400);

      // ignore: avoid_print
      print('DIAG t3 load=${p.loadCount} seek=${p.seekCount} '
          'play=${p.playCount} pos=${notifier.state.position} song=${notifier.state.currentSong?.id}');
      expect(notifier.state.currentSong?.id, 's2',
          reason: '近末尾看门狗触发 _onSongCompleted（280 行）');
    });

    test('duration <= 3s → 近末尾窗口根本不成立，永不触发（117-120 行）', () async {
      notifier = await boot();
      final p = await activate(
          <Song>[_song('s1', duration: 2), _song('s2', duration: 2)]);
      await notifier.play(); // playing=true（duration<=3s 时 inNearEndWindow 恒假，与 playing 无关，但保持激活一致）

      p.emitPosOverride = const Duration(milliseconds: 100);
      notifier.state = notifier.state.copyWith(
        position: const Duration(milliseconds: 1900),
        duration: const Duration(seconds: 2),
      );
      final before = notifier.state.currentSong?.id;

      await waitTicks(14); // 14 tick 远超 5 tick 阈值

      expect(notifier.state.currentSong?.id, before,
          reason: 'duration<=3s ⇒ inNearEndWindow 恒假 ⇒ 近末尾看门狗不介入');
    });
  });

  // ──────────────────── 六、合成进度兜底（235-254 / 309-322） ────────────────────
  // 该分支为源码死代码：源码 58 行 atStart = (sourcePlayerPos<=1.5s ||
  // state.position<=1.5s)，而 235 行 shouldUseSyntheticPosition 要求
  // sourcePlayerPos<=50ms ⇒ 必然 atStart=true；99 行 `if (atStart)
  // _stagnantPositionTicks=0` 在累计到阈值(6)前清零 ⇒ 309-322 行合成推进
  // 永不可达（source 卡 0 实际由 0 秒卡死看门狗 136-180 重载接管）。
  // 按「产品代码零改动」铁律保留死分支、删除该断言用例并钉为待修缺陷
  // （见 batch29 缺陷台账 D-#207-D），不写假断言掩盖。
  // [D-053] 已删除（2026-10-07 用户拍板：合成进度回退功能不要）——死分支
  // 整体移除；源卡死时进度冻结即预期行为，自愈由三道看门狗接管。

  // ──────────────────── 七、seek 落位宽限（26-34） ────────────────────
  group('seek 落位宽限窗（源码 26-34）', () {
    test('宽限窗内 source 未前进 → inSeekSettle 挡住 0 秒卡死计数', () async {
      // _seekSettleUntil 只有在真的 seek 之后才被钉住；用「seek 后位置纹丝不动」
      // 去撞：宽限期内既不算 0 秒卡死，也不算停滞。
      notifier = await boot();
      final p = await activate(<Song>[_song('s1', duration: 200)]);
      await notifier.play(); // playing=true；seek 后 _seekSettleUntil 仍挡住计数，宽限窗内不触发看门狗

      p.emitPosOverride = const Duration(milliseconds: 800);
      notifier.state = notifier.state.copyWith(
        position: const Duration(milliseconds: 800),
        duration: const Duration(seconds: 200),
      );
      p.seekCount = 0;
      await notifier.seek(const Duration(milliseconds: 800));
      expect(p.seekCount, greaterThan(0), reason: 'seek 确实下发到替身');

      await waitTicks(1);

      expect(notifier.state.currentSong?.id, 's1',
          reason: '宽限窗内的这一 tick 不该触发任何看门狗');
    });
  });
}
