// batch28-A：lib/providers/player/player_provider.dart 的**播放完成收敛 / 流地址摘要 /
// 模式下发容错**三段（源码 2559-2600 `_onSongCompleted`+`_scrobble`、
// 2711-2725 `_summarizeStreamUrl`、2374 `_modeApplyChain` 的 catchError）。
//
// 与 batch27（队列 / 模式 / 收藏 / 元数据）同一套姿势：驱动**真实**
// `_PlayerNotifierImpl`，外部依赖全部 override 成桩。本批多出来的唯一一件新东西是
// **替身 just_audio 平台** —— 因為上述三段全部挂在「底层播放器真的吐事件」上：
//
//   * `_onSongCompleted` 只能由 `player.playerStateStream` 上的
//     `ProcessingState.completed` 正向触发（源码 686-739），产品代码里没有任何
//     debug 注入钩子（已 grep `debug[A-Z][A-Za-z]*(` 为空）。
//   * 真实 `JustAudioPlatform.instance` 默认是 `MethodChannelJustAudio`，测试里没有
//     注册插件 → `init()` 直接抛 MissingPluginException → `setUrl` 永远失败 →
//     `playSong` 连 1110 行都走不到（这也是 2711-2725 一直空着的根因）。
//   * 2374 那条 catchError 需要底层 `setLoopMode` 真的抛异常，no-op 平台做不到。
//
// 于是本批把 `JustAudioPlatform.instance` 换成一个继承了 `JustAudioPlatform` 的替身
// （`_FakeJustAudioPlatform`），它 `init()` 返回 `_FakeAudioPlayerPlatform`——后者持
// 一个 `StreamController<PlaybackEventMessage>`，测试里往里 add 一条
// `processingState: completed` 就能让 `player.playerStateStream` 吐完成态。
//
// 踩坑索引（本批新增，接着 batch27 的 #168-D）：
// #169-D 替身必须 **`extends JustAudioPlatform`** 而不是 `implements`：setter 里有
//      `PlatformInterface.verifyToken(instance, _token)`，`_token` 是私有静态，
//      `implements` 的实现拿不到同一个 token 对象 → 赋值直接抛。
//      同理 `_FakeAudioPlayerPlatform extends AudioPlayerPlatform` 也必须是
//      `extends`：`AudioPlayerPlatform` 的每个方法都带默认 `throw UnimplementedError`，
//      `implements` 会把「没 override 的方法」变成编译期必须补的桩。
// #170-D just_audio 的 `_load()` 在 `platform.load()` 返回后还会
//      `await processingStateStream.firstWhere((s) => s != ProcessingState.loading)`。
//      替身的 `load()` **必须**主动吐一条 `ProcessingStateMessage.ready`，否则
//      `setUrl()` 永久挂住，`playSong` 卡死在 `_replaceLoadedSource`。
// #171-D `subscribeToEvents` 里有 `if (playbackEvent == _playbackEvent) return;`
//      的去重：字段全同的事件会被直接丢弃。`emit()` 里给每个事件带**不同**的
//      updateTime + updatePosition，避免「第二条 completed 没反应」这种假死。
// #172-D `AudioPlayer` 在**没有加载过任何音源**之前 `_platform` 指向内部
//      `_IdleAudioPlayer`（不会被我们的 `init()` 接管）。所以完成态用例必须先
//      `playSong(..., autoPlay: false)` 激活平台，再 `emit(completed)`；
//      直接 boot 完就发事件是**收不到**的（替身的 `initCount` 会是 0）。
// #173-D `autoPlay: false` 时 `_syncPlaybackAfterSourceReady` 只 `pause()` 后 return
//      （源码 1539-1550），不会走到 `play()`，也就不会触发 `_handlePlaybackError`
//      的自动跳歌 —— 这是给完成态用例铺底最干净的一条路。
// #174-D `loopMode` / `shuffleEnabled` 用 `state.copyWith(...)` 直接摆值即可，
//      **不要**用 `setPlaybackMode()` 摆：后者会把 `setLoopMode` / `setShuffleMode`
//      真的下发到底层，而底层流（`player.loopModeStream` 源码 743、
//      `player.shuffleModeEnabledStream` 源码 748）会把值**反写**回来（见 #167-D），
//      摆完可能被冲掉。`_onSongCompleted` 读的就是 `state.loopMode` /
//      `state.shuffleEnabled`，摆 state 是权威的。
// #175-D 同一首歌的 completed 只会被处理一次（`_isHandlingCompletion` +
//      `_completionHandlingSongId` 去重，源码 719-725）。要再触发一次，要么换一首
//      歌，要么先发一条 `ready` 把去重标记清掉（源码 713-717）。
// #176-D `next()` 开头有 `if (!state.hasNext) return;`，而 `hasNext` 只要求
//      「currentSong 非空 + 下标合法 + 队列非空」（player_state.dart:185）。也就是说
//      **在队尾** `hasNext` 照样为 true，是否回绕由 `playbackMode` 在 `next()` 尾部
//      决定 —— 这正是「order 到末尾即停 / all 回绕」的分水岭。
// #177-D `_summarizeStreamUrl` 是 `_PlayerNotifierImpl` 的**私有成员**，测试所在的
//      另一个 library 调不到它，只能从调用点打进来。最早的调用点是 1124
//      （`_buildStreamUrlOrThrow` 刚产出 streamUrl 的那条 `_playDbg`），它在
//      `_replaceLoadedSource` **之前** —— 所以哪怕 URL 非法导致后面 `setUrl` 抛
//      FormatException，2711 / 2713 / 2724 也已经打到了。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/constants/api_constants.dart';
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
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/player_state.dart';

// ─────────────────────────── 替身 just_audio 平台 ───────────────────────────

/// 单个播放器的替身（对应 `JustAudioPlatform.init()` 的产物）。
///
/// 只做两件事：① 把会被真 just_audio 调到的方法变成无害返回；② 暴露一个
/// `PlaybackEventMessage` 广播流，让测试能正向驱动 `player.playerStateStream`。
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

  /// 置 true 后 `setLoopMode` 抛异常（用来逼出源码 2374 的 catchError）。
  bool throwOnSetLoopMode = false;

  var _tick = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  /// 吐一条播放事件（踩坑 #171-D：时间戳与位置都递增，绕开去重）。
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
    // 踩坑 #170-D：不吐 ready，`setUrl()` 会永久挂在等 processingState 离开 loading。
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

/// 平台替身（踩坑 #169-D：必须 `extends JustAudioPlatform` 才能通过 token 校验）。
class _FakeJustAudioPlatform extends JustAudioPlatform {
  int initCount = 0;
  _FakeAudioPlayerPlatform? last;

  /// 新 `init()` 出来的播放器是否让 `setLoopMode` 抛异常。
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

Song _song(
  String id, {
  String title = '',
  String suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
  bool starred = false,
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
      starred: starred,
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

/// 离线缓存守护的替身（踩坑 #178-D）。
///
/// `playSong` 在 1206 行 `unawaited(...onSongStartedOnline(...))`，真身会一路读到
/// `offlineCacheSettingsProvider` 并继续异步跑完整个缓存 job —— 测试结束后容器已
/// dispose，那条尾巴就会炸在「Tried to read a provider from a ProviderContainer
/// that was already disposed」，而且是在**上一个用例已经通过之后**才报错。
/// 缓存不是本批的被测对象，直接换成 no-op。
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

/// Subsonic 客户端替身：记 GET 路径（`scrobble` 断言用），并**接管流地址生成**
/// —— `getStreamUrl` 是可 override 的公开方法，接管它才能喂给
/// `_summarizeStreamUrl` 我们想要的 URL 形态（踩坑 #177-D）。
class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  final List<String> getPaths = <String>[];
  final List<String> streamUrlCalls = <String>[];

  /// 默认：带端口 + id/format/maxBitRate/timeOffset 四参齐全（打满 2715-2722）。
  String streamUrl =
      'http://192.168.10.240:46400/rest/stream'
      '?id=s1&format=flac&maxBitRate=1411&timeOffset=7';

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
  }) {
    streamUrlCalls.add(songId);
    return streamUrl;
  }
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

  ServerAddress _addr() => ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: 'http://192.168.10.240:46400',
        priority: 0,
      );

  MusicLibrary _library({String? serverType}) => MusicLibrary(
        id: 'lib1',
        name: '主库',
        serverType: serverType,
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  /// 沿用 batch27 的容器：收藏链路会 invalidate 的三个 FutureProvider 一起 override
  /// （踩坑 #159-D），否则它们会真的去打网络。
  ProviderContainer buildContainer() => ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library(serverType: 'MusicFlow')),
          activeAddressProvider.overrideWith((ref) => _addr()),
          effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
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

  /// 等真 notifier 的构造期尾巴（AudioPlayer 就绪 + 模式恢复 + 会话恢复）落定。
  Future<void> waitQuiet(PlayerNotifier notifier) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 4 && !notifier.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!notifier.debugIsRestoringPlaybackSession) return;
      }
    }
  }

  /// 轮询等条件成立（比固定 sleep 稳，也不会像 `settleState` 那样被「首拍重复」骗过）。
  Future<void> waitUntil(
    bool Function() cond, {
    int ticks = 200,
  }) async {
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

  /// 激活替身平台（踩坑 #172-D）：不先 `playSong` 加载一次音源，`AudioPlayer`
  /// 的 `_platform` 还指向内部 `_IdleAudioPlayer`，替身的 `init()` 不会被调用，
  /// 后面 `emit(completed)` 也就没人接。
  ///
  /// 用 `autoPlay: false` 是为了踩坑 #173-D：不触发 `play()` → 不触发
  /// `_handlePlaybackError` 自动跳歌，底子干净。
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

  List<String> ids(List<Song> q) => q.map((s) => s.id).toList();

  setUp(() {
    repo.starredCalls.clear();
    repo.getSongCalls.clear();
    spy.getPaths.clear();
    spy.streamUrlCalls.clear();
    spy.streamUrl =
        'http://192.168.10.240:46400/rest/stream'
        '?id=s1&format=flac&maxBitRate=1411&timeOffset=7';
  });

  tearDown(() => container.dispose());

  // ───────────────────── 一、替身平台接线自检 ─────────────────────
  group('替身 just_audio 平台 · 接线自检', () {
    test('boot 阶段不加载音源 → 替身 init() 尚未被调用', () async {
      notifier = await boot();

      expect(platform.initCount, 0,
          reason: '没有音源时 _platform 还是内部 _IdleAudioPlayer（踩坑 #172-D）');
      expect(platform.last, isNull);
    });

    test('playSong(autoPlay:false) 加载音源 → 替身接管并吐 ready', () async {
      notifier = await boot();

      final p = await activateWith(<Song>[_song('s1')]);

      expect(platform.initCount, 1);
      expect(p.loadCount, 1);
      expect(p.loadedUris, <String>[spy.streamUrl]);
      // autoPlay=false ⇒ 不 play（源码 1539-1550）；pause 那一下发生在
      // `_replaceLoadedSource` **之前**，此时 `_platform` 还是内部
      // _IdleAudioPlayer，所以替身这边 pauseCount 仍是 0 —— 这也是踩坑 #172-D
      // 的另一条佐证：pause 不会激活替身。
      expect(p.playCount, 0);
      expect(p.pauseCount, 0);
      // ready 被真 notifier 的 playerStateStream 监听接住，写进了 state。
      expect(notifier.state.processingState, ProcessingState.ready);
      expect(notifier.state.currentSong?.id, 's1');
    });

    test('emit(completed) 能被 playerStateStream 接住并写进 state', () async {
      notifier = await boot();
      // 布成「order + 已在队尾」：完成态在 2589 就 return，不会顺带起播下一首，
      // 于是不会有一条新的 ready 把 processingState 又冲回 ready。
      final p = await activateWith(
        <Song>[_song('s1'), _song('s2')],
        index: 1,
      );
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      expect(notifier.state.processingState, ProcessingState.ready);

      p.emit(ProcessingStateMessage.completed);
      await waitUntil(
        () => notifier.state.processingState == ProcessingState.completed,
      );

      expect(notifier.state.processingState, ProcessingState.completed);
    });
  });

  // ───────────────────── 二、_onSongCompleted 四条收敛路径 ─────────────────────
  group('_onSongCompleted · shuffle 分支（源码 2568-2573）', () {
    test('随机模式播完 → 走 next() 且不回绕到刚播完那首', () async {
      notifier = await boot();
      final p = await activateWith(
        <Song>[_song('s1'), _song('s2'), _song('s3')],
      );
      // 踩坑 #174-D：直接摆 state，不走 setPlaybackMode（避免底层流反写）。
      notifier.state = notifier.state.copyWith(
        shuffleEnabled: true,
        playbackMode: PlaybackMode.shuffle,
        loopMode: LoopMode.off,
      );
      final loadsBefore = p.loadCount;

      p.emit(ProcessingStateMessage.completed);
      await waitUntil(() => p.loadCount > loadsBefore, ticks: 300);

      // 随机兜底排除当前曲，所以播完的 s1 不会被再挑中一次。
      expect(notifier.state.currentSong?.id, isNot('s1'));
      expect(ids(notifier.state.queue), <String>['s1', 's2', 's3'],
          reason: 'next() 不该动队列本身');
      expect(p.seekCount, 0,
          reason: 'shuffle 分支在 2573 就 return，不碰 seek / _startPlayback');
    });

    test('随机模式 + 空队列 → 只 return，不起播下一首', () async {
      // 2569 的 `state.queue.isNotEmpty` 为假的情形。
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      notifier.state = notifier.state.copyWith(
        queue: <Song>[],
        currentSong: _song('s1'),
        currentIndex: 0,
        shuffleEnabled: true,
        playbackMode: PlaybackMode.shuffle,
      );
      final loadsBefore = p.loadCount;

      p.emit(ProcessingStateMessage.completed);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(p.loadCount, loadsBefore, reason: '空队列时 shuffle 分支直接 return');
      expect(notifier.state.currentSong?.id, 's1');
    });
  });

  group('_onSongCompleted · one 分支（源码 2577-2582）', () {
    test('单曲循环播完 → seek(0) + _startPlayback，当前曲原地不动', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1'), _song('s2')]);
      notifier.state = notifier.state.copyWith(
        loopMode: LoopMode.one,
        playbackMode: PlaybackMode.one,
        shuffleEnabled: false,
        position: const Duration(seconds: 30),
      );
      final loadsBefore = p.loadCount;

      p.emit(ProcessingStateMessage.completed);
      await waitUntil(() => p.playCount > 0, ticks: 300);

      // 2580 的 seek(Duration.zero)：进度被拉回 0（无论走「立即 seek」还是
      // 「挂 pendingSeek 先写 state.position」两条支路，落点都是 0）。
      expect(notifier.state.position, Duration.zero);
      // 2581-2582：曲子没换 ⇒ _startPlayback(fadeIn:false) 真的调了 play()。
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.currentIndex, 0);
      expect(p.playCount, greaterThanOrEqualTo(1));
      // 没有换歌 ⇒ 没有新的 load。
      expect(p.loadCount, loadsBefore);
      // 没有走 next() ⇒ 队列没被动过。
      expect(ids(notifier.state.queue), <String>['s1', 's2']);
    });
  });

  group('_onSongCompleted · order 到末尾即停（源码 2584-2589）', () {
    test('顺序模式 + 已在队尾 → atEnd 直接 return，不动下标也不起播', () async {
      notifier = await boot();
      final p = await activateWith(
        <Song>[_song('s1'), _song('s2')],
        index: 1,
      );
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      final loadsBefore = p.loadCount;
      final playsBefore = p.playCount;

      p.emit(ProcessingStateMessage.completed);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(notifier.state.currentIndex, 1);
      expect(notifier.state.currentSong?.id, 's2');
      expect(ids(notifier.state.queue), <String>['s1', 's2']);
      expect(p.loadCount, loadsBefore, reason: 'order 到末尾不该起播下一首');
      expect(p.playCount, playsBefore);
    });
  });

  group('_onSongCompleted · 顺序推进 / 列表循环回绕（源码 2590-2594）', () {
    test('顺序模式 + 非队尾 → next() 推进到下一首', () async {
      notifier = await boot();
      final p = await activateWith(
        <Song>[_song('s1'), _song('s2'), _song('s3')],
      );
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      final loadsBefore = p.loadCount;

      p.emit(ProcessingStateMessage.completed);
      await waitUntil(() => p.loadCount > loadsBefore, ticks: 300);
      await waitUntil(() => notifier.state.currentIndex == 1, ticks: 300);

      expect(notifier.state.currentIndex, 1);
      expect(notifier.state.currentSong?.id, 's2');
    });

    test('列表循环 + 已在队尾 → 不属 order 分支，hasNext 走 next() 回绕到首曲',
        () async {
      // 踩坑 #176-D：队尾时 hasNext 仍是 true，回绕与否由 next() 尾部的
      // playbackMode 判定（源码 2096-2100）决定。
      notifier = await boot();
      final p = await activateWith(
        <Song>[_song('s1'), _song('s2'), _song('s3')],
        index: 2,
      );
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.all,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      final loadsBefore = p.loadCount;

      p.emit(ProcessingStateMessage.completed);
      await waitUntil(() => p.loadCount > loadsBefore, ticks: 300);

      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 's1');
    });
  });

  group('_scrobble · 完成态上报（源码 2563-2564 / 2599-2600）', () {
    test('非试听曲播完 → 以 submission=true 上报一次 scrobble', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1'), _song('s2')]);
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.getPaths.clear();

      p.emit(ProcessingStateMessage.completed);
      await waitUntil(() => spy.getPaths.contains(ApiConstants.scrobble));

      expect(spy.getPaths, contains(ApiConstants.scrobble));
    });

    test('试听曲播完 → 不上报（isPreview 的 != true 判定）', () async {
      // 2563 的另一侧：试听片段不算一次真实收听，不该污染播放历史。
      // 队列只放一首（order 到末尾即停），这样完成态不会顺带起播下一首 ——
      // 否则 next() 里的 playSong(autoPlay:true) 会自己上报一次
      // submission=false 的 scrobble，把这条断言搅浑。
      notifier = await boot();
      // 试听曲走 `_playPreviewSongInternal`，根本不加载音源；所以底子用普通曲铺，
      // 铺完再把 currentSong 换成试听版。
      final p = await activateWith(<Song>[_song('s1')]);
      notifier.state = notifier.state.copyWith(
        queue: <Song>[_song('s1', isPreview: true)],
        currentIndex: 0,
        currentSong: _song('s1', isPreview: true),
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      spy.getPaths.clear();

      p.emit(ProcessingStateMessage.completed);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(spy.getPaths, isNot(contains(ApiConstants.scrobble)));
    });
  });

  group('完成态去重（源码 713-725）', () {
    test('同一首歌连发两条 completed → 只处理一次', () async {
      // 用「单曲循环」做观测窗：完成态走 seek(0)+_startPlayback，**不换歌也就不
      // 会有新的 load / ready 事件**去把 `_isHandlingCompletion` 重置掉，于是第二
      // 条 completed 的去重效果可以直接钉在 `playCount` 上。
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1'), _song('s2')]);
      notifier.state = notifier.state.copyWith(
        loopMode: LoopMode.one,
        playbackMode: PlaybackMode.one,
        shuffleEnabled: false,
      );

      p.emit(ProcessingStateMessage.completed);
      await waitUntil(() => p.playCount > 0, ticks: 300);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(p.playCount, 1);

      p.emit(ProcessingStateMessage.completed);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(p.playCount, 1,
          reason: '同一首歌的完成态只应收敛一次，重复事件不该再起播一遍');
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.currentIndex, 0);
    });
  });

  // ───────────────────── 三、_summarizeStreamUrl（源码 2711-2725） ─────────────────────
  group('_summarizeStreamUrl · 经 playSong 打进去', () {
    test('带端口 + 四参齐全的流地址 → 走完 Uri.parse 到 return 的整条 try 体',
        () async {
      // 踩坑 #177-D：最早的调用点是 1124，`_buildStreamUrlOrThrow` 刚返回就打。
      notifier = await boot();
      spy.streamUrl =
          'http://192.168.10.240:46400/rest/stream'
          '?id=s1&format=flac&maxBitRate=1411&timeOffset=7';

      await notifier.playSong(_song('s1'), queue: <Song>[_song('s1')]);
      await waitUntil(() => (platform.last?.loadCount ?? 0) > 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // 1124 已被执行 ⇒ 后面整条直连链路跑通，state 落在 stream 源上。
      expect(spy.streamUrlCalls, contains('s1'));
      expect(platform.last!.loadedUris,
          <String>['http://192.168.10.240:46400/rest/stream'
              '?id=s1&format=flac&maxBitRate=1411&timeOffset=7']);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
      expect(notifier.state.currentSong?.id, 's1');
    });

    test('不带端口的流地址 → host 走「只有域名」那一侧（2715 三元）', () async {
      notifier = await boot();
      spy.streamUrl = 'https://music.example.test/rest/stream?id=s2';

      await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
      await waitUntil(() => (platform.last?.loadCount ?? 0) > 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(platform.last!.loadedUris,
          <String>['https://music.example.test/rest/stream?id=s2']);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
    });

    test('非法 URL → Uri.parse 抛 FormatException，落 catch 的 invalid_url', () async {
      // 这条钉的是 2723-2724：`Uri.parse` 对畸形百分号转义会抛，
      // `_summarizeStreamUrl` 必须自己吞掉并返回占位串（否则一条坏地址能把
      // 整条起播日志链路打断）。
      notifier = await boot();
      // 未闭合的 IPv6 主机括号：`Uri.parse` 一定会抛 FormatException。
      // （`%zz` 这种畸形转义 Dart 反而宽容地归一化成 `%25zz`，抛不出来。）
      final bad = 'http://[::1/rest/stream?id=s3';
      // 先自证这个串确实会让 Uri.parse 抛 —— 断言不是凭空写的。
      expect(() => Uri.parse(bad), throwsA(isA<FormatException>()));
      spy.streamUrl = bad;
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );

      // setUrl 随后也会因同一个 FormatException 失败；整条失败链由 playSong
      // 的 catch 收走（不会抛给调用方）。单曲队列 + order ⇒ next() 在队尾停住，
      // 不会连跳（踩坑 #176-D）。
      await notifier.playSong(
        _song('s3'),
        queue: <Song>[_song('s3')],
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(spy.streamUrlCalls, contains('s3'));
      expect(platform.last, isNull,
          reason: '坏 URL 在 setUrl 之前就炸了，替身平台不该收到任何 load');
      expect(notifier.state.currentSong?.id, 's3');
    });
  });

  // ───────────────────── 四、_modeApplyChain 的 catchError（源码 2374） ─────────────────────
  group('setPlaybackMode · 底层下发失败的兜底', () {
    test('setLoopMode 抛异常 → 被 catchError 吞掉，切模式本身照常返回', () async {
      notifier = await boot();
      // 先激活替身平台，否则 `setLoopMode` 打到的是内部 _IdleAudioPlayer（不抛）。
      final p = await activateWith(<Song>[_song('s1')]);
      p.throwOnSetLoopMode = true;
      final loopsBefore = p.setLoopModeCount;

      await notifier.setPlaybackMode(PlaybackMode.one, persist: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(p.setLoopModeCount, greaterThan(loopsBefore),
          reason: '底层真的被调了一次并抛出');
      // catchError 把异常吞掉 ⇒ 状态乐观值保留、调用方不会被异常打断。
      expect(notifier.state.playbackMode, PlaybackMode.one);
      expect(notifier.state.loopMode, LoopMode.one);
    });

    test('不下发失败时不进 catchError（对照组：正常档也能落位）', () async {
      notifier = await boot();
      final p = await activateWith(<Song>[_song('s1')]);
      p.throwOnSetLoopMode = false;

      await notifier.setPlaybackMode(PlaybackMode.shuffle, persist: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.state.playbackMode, PlaybackMode.shuffle);
      expect(notifier.state.shuffleEnabled, isTrue);
    });
  });
}
