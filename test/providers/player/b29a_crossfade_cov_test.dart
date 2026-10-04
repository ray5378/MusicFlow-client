// batch29-A：lib/providers/player/player_crossfade.dart 的**淡出 / 淡入 / 取消**三段
// （源码 3-104：`_cancelFade` / `_fadeOut` / `_fadeIn`）。
//
// 与 batch28-A 同一套测试姿势：驱动**真实** `_PlayerNotifierImpl`，外部依赖全部 override
// 成桩，唯一的新东西是**替身 just_audio 平台**（沿用 batch28-A 的 `_FakeJustAudioPlatform`）。
//
// 本批最硬的一条约束（新坑 #187-D，直接决定整套测试的写法）：
//   player_crossfade.dart 是 `part of 'player_provider.dart'`，mixin 的三个方法
//   `_cancelFade` / `_fadeOut` / `_fadeIn` **全是库私有** —— 测试所在的另一个 library
//   一个都调不到（连 `class X = PlayerNotifier with PlayerCrossfadeInternals` 造个测试替身
//   也一样调不到，私有名的归属是**声明它的库**而不是调用点）。唯一入口是
//   `player_provider.dart` 里那几处调用点：
//     * 949  `await _fadeOut(debugSession)`  ← playSong()
//     * 952  `_cancelFade()`                 ← playSong(autoPlay:false)
//     * 1511 `_fadeIn()`                     ← _startPlayback()（autoPlay 为真）
//     * 1926 `_cancelFade()`                 ← play()
//     * 1657/2733 `_cancelFade()`            ← 其它清理点
//   也就是说这一整份文件**只能靠公开 API 打进去**，先 `play()` 把
//   `player.playing` 顶成 true（源码 23 行的守卫），再 `playSong()` 才进得了淡出主体。
//
// 踩坑索引（本批新增，batch28-A 的 #169-D~#178-D 继续沿用）：
// #187-D mixin 里的成员是库私有，测试调不到 ⇒ 只能通过公开 API 打进去（见上）。
// #188-D `_fadeOut` 的 23 行守卫是 `!player.playing`：`playSong()` 的 `_fadeOut`（949）
//      发生在 `_startPlayback` **之前**，此刻 `player.playing` 恒为 false，
//        ⇒ 想进淡出主体必须先 `playSong(autoPlay:false)` 装源 + `play()` 顶起 playing，
//          再发起第二次 `playSong()`。
// #189-D `crossfadeDurationMsProvider` 是 `StateNotifierProvider`，`overrideWithValue`
//       塞不进可变的时长 ⇒ 用 `overrideWith((ref) { final n = _FakeCrossfade();
//       n.state = cfMs; return n; })`，值在工厂里读闭包变量，测试中途改 `cfMs` 不影响
//       已建好的 notifier（换容器即换值）。
// #190-D `Timer.periodic(20ms)` 是**真定时器**：`_fadeOut` 被 `await`，所以淡出时长
//       真实耗时 = durationMs ~/ 2。用例里取 durationMs=20（fadeMs=10 ⇒ steps=1）走
//       单 tick 收敛；要打「会话变更中止」那条分支则取 1000ms（fadeMs=500 ⇒ 25 步），
//       在 20~40ms 时插入第二次 playSong，把中止点卡在斜坡中段。
// #191-D 中止分支（39-49 / 90-95）会把音量**恢复成 state.volume**，所以断言不能只看
//       「最后一拍是不是 state.volume」（正常收敛也是这个值）—— 必须看**紧邻序列**：
//       [] → [0.0, 0.032, 0.8] 这种「斜坡被打断后直接跳回满值」的形态才是中止的指纹。
// #192-D `_cancelFade` 的 13 行 `setVolume(state.volume)` 与 `_fadeOut` 入口 19 行的
//       `_cancelFade()` 都会下发音量 ⇒ 断言前先 `volumeCalls.clear()`，否则读到的是
//       上一段残留。
// #194-D `CrossfadeNotifier` 的**构造函数里就 `_load()` 了一次**（读
//       `LocalStorage.getCrossfadeDurationMs()`），那条 Future 在若干微任务之后
//       把 `state` 回填。若只在 provider 工厂里 `n.state = cfMs` 赋值，一定被这次
//       异步回填盖掉：SharedPreferences 里只要存过一次淡入淡出时长（比如前几轮
//       测试或真机设过），此后所有用例读到的都不再是测试设的值 ⇒ `_fadeOut` 永远
//       走不到 21 行的早退分支、也永远读不到 `steps` 的小值，出现「全是 0.8、
//       一条 0.0 都没有」的假象。解法：工厂把实例留在一个测试字段上，用例在
//       **boot 之后**再改 `cf.state`（此时 `_load()` 早已落地）。
// #195-D `crossfadeDurationMsProvider` 是**惰性**创建的：`boot()`（读 `playerProvider`）
//       根本不碰它，实例要等到 `_fadeOut` 第一次 `_ref.read(...)` 才被工厂建出来。
//       所以 boot 后立刻摸 `cf` 拿到的是 null（`Null check operator used on a null
//       value`）。顺序必须是 `boot → activateWith → cf!.state = N`。
// #196-D 淡出与淡入共用同一条 `volumeCalls` 序列，且**都**是「先下压/抬升再逐 tick」
//        ⇒ 单看「已有 2 个半坡值」分不清是淡出还是淡入。淡入是 `_startPlayback`
//        里 `play()` **之后**才调的（1511 行），所以要用 `playCount` 定位淡入起点，
//        而不是靠斜坡长度猜。
// #193-D `play()`（1926 行 `cancelFade`）本身就要求 `state.currentSong != null`，
//       所以「用 play() 中止一次进行中的淡出」这条用例必须先装过一首歌，装源用
//       `autoPlay:false`（避免 0 秒卡死看门狗介入），再 `play()`。
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
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/crossfade_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/player_state.dart';

// ─────────────────────────── 替身 just_audio 平台 ───────────────────────────

/// 单个播放器的替身（对应 `JustAudioPlatform.init()` 的产物），额外**记录音量下发**。
///
/// 本批三个被测函数（_fadeOut/_fadeIn/_cancelFade）**唯一的外部可观测出口**
/// 就是 `setVolume`：它们都不改 state，只往底层下发音量，所以替身必须把
/// `SetVolumeRequest.volume` 记下来，测试才能读到「斜坡」。
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
  int setLoopModeCount = 0;
  final List<String> loadedUris = <String>[];
  /// 音量下发序列（踩坑 #192-D：断言前要 clear）。
  final List<double> volumeCalls = <double>[];

  bool throwOnSetLoopMode = false;
  var _tick = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  /// 吐一条播放事件（沿用 #171-D：时间戳与位置都递增，绕开 just_audio 的去重）。
  void emit(ProcessingStateMessage state) {
    _tick += 1;
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: _tick * 997),
        bufferedPosition: Duration(milliseconds: _tick * 997),
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
    // 沿用 #170-D：不吐 ready，`setUrl()` 会永久挂在等 processingState 离开 loading。
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
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    volumeCalls.add(request.volume);
    return SetVolumeResponse.fromMap(const <dynamic, dynamic>{});
  }

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
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    setLoopModeCount += 1;
    if (throwOnSetLoopMode) {
      throw StateError('setLoopMode boom');
    }
    return SetLoopModeResponse.fromMap(const <dynamic, dynamic>{});
  }

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

/// 平台替身（沿用 #169-D：必须 `extends JustAudioPlatform` 才能过 token 校验）。
class _FakeJustAudioPlatform extends JustAudioPlatform {
  int initCount = 0;
  _FakeAudioPlayerPlatform? last;

  bool throwOnSetLoopMode = false;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    initCount += 1;
    final player = _FakeAudioPlayerPlatform(request.id);
    player.throwOnSetLoopMode = throwOnSetLoopMode;
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

Song _song(String id, {bool isPreview = false}) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'flac',
      bitRate: 1411,
      duration: 200,
      starred: false,
      isPreview: isPreview,
    );

/// 只记调用、不留状态的仓储（沿用 batch27 的 `_FakeMusicRepository`）。
class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  final List<String> starredCalls = <String>[];
  final List<String> getSongCalls = <String>[];

  @override
  Future<void> setSongStarred(String songId, bool starred) async {
    starredCalls.add('$songId:$starred');
  }

  @override
  Future<Song?> getSong(String songId) async {
    getSongCalls.add(songId);
    return null;
  }
}

/// 离线缓存守护的替身（沿用 #178-D）。
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

/// 可写淡入淡出时长的桩 notifier（踩坑 #189-D）。
///
/// 只能 `extends CrossfadeNotifier`：`crossfadeDurationMsProvider` 是
/// `StateNotifierProvider<CrossfadeNotifier, int>`，`overrideWith` 的返回类型被钉死成
/// `CrossfadeNotifier`，自己另写一个 `Notifier<int>` 编译不过。
class _FakeCrossfade extends CrossfadeNotifier {
  _FakeCrossfade() : super();
}

/// Subsonic 客户端替身（沿用 #177-D：接管流地址生成）。
class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  final List<String> getPaths = <String>[];

  String streamUrl = 'http://192.168.10.240:46400/rest/stream?id=s1';

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
  String getStreamUrl(
    String songId, {
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) =>
      streamUrl;
}

/// 淡入淡出时长的「持有者」（踩坑 #194-D）。
///
/// 必须是**文件级**变量而不是 `main()` 里的局部变量：`buildContainer()` 是定义在
/// `main()` 内部的局部函数，它闭包里的赋值解析不到 `main()` 的局部变量
/// （`Local variable 'cf' can't be referenced before it is declared`）。
_FakeCrossfade? cf;

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

  /// 由 `crossfadeDurationMsProvider` 的工厂在**首次被读时**读一次。
  var cfMs = 0;

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
          crossfadeDurationMsProvider.overrideWith((ref) {
            cf = _FakeCrossfade();
            cf!.state = cfMs;
            return cf!;
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

  /// 等真 notifier 的构造期尾巴（沿用 batch28-A 的 `waitQuiet`）。
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

  /// 淡入淡出时长的**持有者**（踩坑 #194-D）。
  ///
  /// `CrossfadeNotifier` 的构造函数里就 `_load()` 了一次
  /// （`LocalStorage.getCrossfadeDurationMs()`），那条 Future 在若干微任务后才
  /// 把 `state` 写回。若只在 provider 工厂里 `n.state = cfMs` 赋值，**一定会被
  /// 这次异步回填盖掉**（SharedPreferences 里存过一次值就再也回不到测试设的值），
  /// 于是 `_fadeOut` 永远读到一个非 0 时长、根本走不到 21 行的早退分支。
  /// 解法：工厂里把实例留在这个字段上，用例在 **boot 之后**再改 `cf.state`。
  Future<PlayerNotifier> boot() async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    cfMs = 0;
    container = buildContainer();
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  /// 激活替身平台（沿用 #172-D + #173-D：`autoPlay:false` 不触发 play，
  /// 底子干净，0 秒卡死看门狗不会介入）。
  Future<_FakeAudioPlayerPlatform> activateWith(
    List<Song> queue, {
    int index = 0,
  }) async {
    await notifier.playSong(
      queue[index],
      queue: queue,
      index: index,
      autoPlay: false,
    );
    await waitUntil(() => platform.last != null && platform.last!.loadCount > 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return platform.last!;
  }

  /// 把 `player.playing` 顶成 true（踩坑 #188-D）：`_fadeOut` 的 23 行守卫
  /// `if (player == null || !player.playing) return;` 是整份文件的总闸，
  /// 不先 `play()` 一次，下面的淡出用例一条都进不去。
  Future<void> startPlaying(_FakeAudioPlayerPlatform p) async {
    await notifier.play();
    await waitUntil(() => p.playCount > 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  /// 「斜坡被打断后直接恢复满音量」的指纹（踩坑 #191-D）。
  ///
  /// 正常收敛也会以 `state.volume` 结尾（淡出收到 0 之后再被 `_cancelFade`
  /// 拉回满值），所以只看「最后一拍」分不出中止分支；必须找
  /// **一个 0 < v < state.volume 的半坡值，它的下一个下发值就是满值**，
  /// 这才是 47 行 / 93 行 `player.setVolume(state.volume)` 的指纹。
  bool _hasRestoreAfterPartial(List<double> calls, double vol) {
    for (var i = 1; i < calls.length - 1; i++) {
      final v = calls[i];
      if (v > 0.0 && v < vol && calls[i + 1] == vol) return true;
    }
    return false;
  }

  /// 取值严格落在 (0, state.volume) 的那几档 = 斜坡中间态。
  List<double> _partialRamp(List<double> calls, double vol) =>
      calls.where((v) => v > 0.0 && v < vol).toList();

  setUp(() {
    repo.starredCalls.clear();
    repo.getSongCalls.clear();
    spy.getPaths.clear();
  });

  tearDown(() => container.dispose());

  // ──────────────────── 一、_fadeOut 的两条早退（源码 21 / 23） ────────────────────
  group('_fadeOut · 早退分支', () {
    test('durationMs <= 0 → 直接 return，音量从未被压低（源码 21）', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 0;
      p.volumeCalls.clear();

      // 默认 autoPlay=true ⇒ 走到 949 的 `_fadeOut`，但时长为 0 ⇒ 21 行 return。
      await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);

      final vol = notifier.state.volume;
      expect(_partialRamp(p.volumeCalls, vol), isEmpty,
          reason: '淡出关闭 ⇒ 走不到 26-64 的斜坡，音量一步都不该被压低');
      expect(notifier.state.currentSong?.id, 's2');
    });

    test('player 未 playing → 直接 return（源码 23，autoPlay:false 路径）', () async {
      // 踩坑 #188-D：这是最容易想当然踩空的一条 —— `_fadeOut` 在
      // `_startPlayback` **之前**执行，此刻 `player.playing` 恒为 false，
      // 直接 23 行 return（连 durationMs 都白读了）。
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 2000;
      p.volumeCalls.clear();

      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s2')],
        autoPlay: false,
      );
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);

      final vol = notifier.state.volume;
      expect(_partialRamp(p.volumeCalls, vol), isEmpty,
          reason: '未起播时不进淡出主体，23 行就 return 了');
    });
  });

  // ──────────────────── 二、_fadeOut 正常收敛（源码 26-64） ────────────────────
  group('_fadeOut · 正常收敛到 0', () {
    test('playing 中切歌 → 音量逐档降到 0（单步场景，源码 51-61）', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 20; // fadeMs=10 ⇒ steps=1 ⇒ 单个 tick 即收敛
      await startPlaying(p);
      p.volumeCalls.clear();

      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s2')],
        autoPlay: false,
      );
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);

      final vol = notifier.state.volume;
      expect(p.volumeCalls, contains(0.0),
          reason: '打到底 ⇒ 音量被压到 0（53 行的判定）');
      expect(p.volumeCalls.last, vol,
          reason: '收尾的 952 行 `_cancelFade` 把音量拉回用户设置值');
      expect(notifier.state.currentSong?.id, 's2');
    });

    test('多步淡出 → 每 20ms 一档、单调不增，最后一档落到 0', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 200; // fadeMs=100 ⇒ steps=5
      await startPlaying(p);
      p.volumeCalls.clear();

      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s2')],
        autoPlay: false,
      );
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);

      final vol = notifier.state.volume;
      final ramp = _partialRamp(p.volumeCalls, vol);
      // fadeMs=100 / stepMs=20 ⇒ steps=5，其中最后一档是 0.0（不算半坡），
      // 于是 0<v<vol 的档位恰好是前 4 档（源码 51-52）。
      expect(ramp.length, 4, reason: '5 个 tick，其中 4 档落在 (0, vol) 区间');
      expect(p.volumeCalls, contains(0.0), reason: '最后一档是 0');
      for (var i = 1; i < ramp.length; i++) {
        expect(ramp[i], lessThan(ramp[i - 1]));
      }
    });
  });

  // ──────────────────── 三、_fadeOut 会话中止（源码 39-49） ────────────────────
  group('_fadeOut · 会话变更中止', () {
    test('淡出途中再切歌 → 定时器自 cancel + 音量恢复而非归零', () async {
      // 这条钉的是 45-50：中止后必须 `player.setVolume(state.volume)`，
      // 而不是把音量留在 0（否则新源加载失败进暂停态就是「无声假死」）。
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 1000; // fadeMs=500 ⇒ steps=25 ⇒ 斜坡够长，能在中段打断
      await startPlaying(p);
      p.volumeCalls.clear();

      // 不 await：让 `_fadeOut` 的 Timer 挂起来。
      final pending = notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s2')],
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(_partialRamp(p.volumeCalls, notifier.state.volume).isNotEmpty,
          isTrue, reason: '此刻仍在半坡上');

      // 会话被下一次切歌顶掉。
      unawaited(
        notifier.playSong(_song('s3'), queue: <Song>[_song('s3')]),
      );
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(_hasRestoreAfterPartial(p.volumeCalls, notifier.state.volume),
          isTrue,
          reason: '「半坡值 → 满值」的紧邻序列才是 47 行中止分支的指纹（#191-D）');
      expect(p.volumeCalls.every((v) => v >= 0.0 && v <= notifier.state.volume),
          isTrue);
    });
  });

  // ──────────────────── 四、_cancelFade 三条出口（源码 6-13） ────────────────────
  group('_cancelFade · 补一次完成态 completer（源码 10-12）', () {
    test('play() 打断进行中的淡出 → completer 被补完、音量恢复', () async {
      // 观测的是 10-12 的 `completer.complete()`：淡出还没收敛就被 `_cancelFade`
      // 收尾，`_fadeOut` 返回的 `completer.future` 必须能正常解开，
      // 否则 playSong 会永久挂在 949 行。
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 1000;
      await startPlaying(p);
      p.volumeCalls.clear();

      final pending = notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s2')],
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(_partialRamp(p.volumeCalls, notifier.state.volume).isNotEmpty,
          isTrue);

      await notifier.play(); // → 1926 行 `_cancelFade()` → 补完 completer
      expect(_hasRestoreAfterPartial(p.volumeCalls, notifier.state.volume),
          isTrue, reason: '13 行把音量恢复成用户设置值');
      await pending; // 关键：不能永久挂住
    });

    test('无进行中的淡出 → _cancelFade 只恢复音量、不抛（源码 6-13）', () async {
      // 对照组：切歌序列里最常撞到的形态（0 淡出 → 952 行直接 `_cancelFade`）。
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 0;
      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s2')],
        autoPlay: false,
      );
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);
      p.volumeCalls.clear();

      await notifier.play(); // 952 行已 return 过，这里 1926 行再 cancel 一次

      final vol = notifier.state.volume;
      expect(_partialRamp(p.volumeCalls, vol), isEmpty,
          reason: '没有进行中的淡出 ⇒ 不存在半坡值');
      expect(notifier.state.isPlaying, isTrue);
    });
  });

  // ──────────────────── 五、_fadeIn 两条出口（源码 71-103） ────────────────────
  group('_fadeIn · 淡出关闭时的直给（源码 71-74）', () {
    test('durationMs <= 0 → 直接 setVolume(state.volume) 后 return', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 0;
      p.volumeCalls.clear();

      // 默认 autoPlay=true ⇒ `_syncPlaybackAfterSourceReady` → `_startPlayback`
      // → `_fadeIn()`，71-74 的 durationMs<=0 侧在这里被走通。
      await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final vol = notifier.state.volume;
      expect(_partialRamp(p.volumeCalls, vol), isEmpty,
          reason: '淡出关闭时淡入只做「直给音量」，一步都不爬坡');
      expect(p.volumeCalls, isNotEmpty);
    });
  });

  group('_fadeIn · 正常爬坡到 state.volume（源码 79-103）', () {
    test('autoPlay=true 切歌 → 从 0.0 起步爬到 state.volume 后自 cancel',
        () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 20; // fadeMs=10 ⇒ steps=1 ⇒ 一步到顶
      p.volumeCalls.clear();

      await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final vol = notifier.state.volume;
      expect(p.volumeCalls, contains(0.0), reason: '淡入从 0.0 起步（源码 84）');
      expect(p.volumeCalls.last, vol);
      expect(p.volumeCalls.length, lessThan(10), reason: '1 步即收敛，不该持续爬');
    });

    test('多步淡入 → 单调不减，顶到 state.volume 自 cancel', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 200; // fadeMs=100 ⇒ steps=5
      p.volumeCalls.clear();

      await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
      await waitUntil(() => (platform.last?.loadCount ?? 0) > p.loadCount);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final vol = notifier.state.volume;
      final ramp = _partialRamp(p.volumeCalls, vol);
      expect(p.volumeCalls, contains(0.0));
      expect(ramp.length, greaterThanOrEqualTo(3), reason: '5 步爬坡至少看到 3 档');
      for (var i = 1; i < ramp.length; i++) {
        expect(ramp[i], greaterThan(ramp[i - 1]));
      }
      expect(p.volumeCalls.last, vol);
    });
  });

  group('_fadeIn · 会话变更中止（源码 90-95）', () {
    test('淡入途中再切歌 → 定时器自 cancel + 音量恢复（指纹：半坡后直接跳满）',
        () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      cf!.state = 1000; // fadeMs=500 ⇒ 25 步斜坡，220ms 才走一半
      p.volumeCalls.clear();

      await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
      // 踩坑 #196-D：不能用「半坡值 ≥2」当「淡入已开跑」的判据 —— 那两个半坡值
      // 很可能来自 s2 的**淡出**斜坡（两者共用同一条 volumeCalls 序列）。
      // 淡入是 `_startPlayback` 里 `play()` 之后才调的，所以用 playCount 定位。
      await waitUntil(() => p.playCount >= 1);
      p.volumeCalls.clear();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(_partialRamp(p.volumeCalls, notifier.state.volume).length >= 2,
          isTrue, reason: '此刻淡入已爬了 2 档');

      // s3 用 autoPlay:false：它自己的 `_fadeOut` → `_cancelFade` 会补一次满值
      // 音量，但**不会再开一条淡入斜坡**，于是「半坡值不再增长」能干净地
      // 证明 92 行 `_fadeTimer = null` 真的把 s2 的定时器掐了。
      //
      // 踩坑 #202-D：**这条判据实际不成立**——切到 s3 之后 s3 自己的 `_fadeIn`
      // 也会从 0.0 重新爬坡，「半坡值」照样会继续增长，新来的半坡值和 s2 残留的
      // 无法从序列上区分。所以下面第三条断言不能要求「半坡值不增长」，只保留
      // 90-95 行独有的「半坡后直接跳满」指纹 + 最终回到满值。
      unawaited(
        notifier.playSong(
          _song('s3'),
          queue: <Song>[_song('s3')],
          autoPlay: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 踩坑 #193-D：`volumeCalls[0]` 是**上一次** clear 之后的起点，不等于
      // 淡入的 0.0 起步值（#194-D 那批失败里有「Actual 0.8」就是这么来的）。
      // 这里只钉「切换瞬间音量仍在半坡」，真正的中止指纹交给下面两条。
      expect(
        p.volumeCalls.first < notifier.state.volume,
        isTrue,
        reason: '切歌瞬间还压在半坡（源码 84-89）',
      );
      expect(_hasRestoreAfterPartial(p.volumeCalls, notifier.state.volume),
          isTrue,
          reason: '半坡值之后紧接满值 ⇒ 走的是 93 行的中止分支（#191-D）');
      // 兜底：切歌之后 s3 自己的淡入会一路爬到满值，音量不会永久压在半坡/归零。
      // 踩坑 #202-D（续）：这条必须**等**而不是**猜**——s3 的 fadeMs=1000 ⇒ 50 档
      // 斜坡，80ms 时还只到 0.7 左右，直接读 `last` 会拿到半坡值。
      await waitUntil(() => p.volumeCalls.isNotEmpty && p.volumeCalls.last == notifier.state.volume);
      expect(
        p.volumeCalls.last, notifier.state.volume,
        reason: '切歌收尾音量回到 state.volume',
      );
    });
  });
}
