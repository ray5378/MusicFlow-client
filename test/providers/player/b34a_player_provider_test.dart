// b34a：lib/providers/player/player_provider.dart 主文件剩余未覆盖分支攻坚。
//
// 依据 coverage/lcov.info 中该文件 LF:1047 / LH:828 的 219 行 miss，按方法边界
// 逐块补测（不与已有 b29a/b33 系列重复）：
//   * playQueue 空/随机起点/clamp + appendToQueue（1566-1597）
//   * togglePlayPause / play 空会话守卫 / pause 落 isPlaying=false（1547-1552、1817-1823）
//   * pause 带 crossfade 淡出全路径（1895-1899、1932-1961）
//   * setVolume 防抖落盘（1829-1852）
//   * _updateMediaItem artUri 分支（1447-1450）
//   * durationStream 元数据缺失用流时长 + 流时长 null（663-679）
//   * 播放失败无线路 → 安排重连重试 → 网络恢复自动重试成功（1231-1252、769-788、830-886）
//   * 重连重试的三个早退/清理分支（816-827、839-846、782-788）
//   * MP3 转码重试成功（1264-1276、1294-1399）与转码也失败跳歌（1365-1370、1401+）
//   * _startPlayback play() 抛错 → 跳歌（1504-1508）
//   * Windows 平台 SMTC 分支（492-504）
//   * _restorePlaybackMode 未知持久值 orElse（2397-2400）
//   * persistPlaybackStateNow + _awaitInFlightPersist 租约等待（2751-2774、2782-2790）
//   * refreshSongMetadata 当前曲 + 队列镜像更新（2668-2695）
//
// 沿用 b29a_pospoll_cov_test 的替身骨架：驱动真实 _PlayerNotifierImpl，
// just_audio 用 extends JustAudioPlatform 的替身（load 必吐 ready / load 响应）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
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
import 'package:musicflow_client/providers/player/crossfade_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

// ───────────────────────────── just_audio 替身 ───────────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  int loadCount = 0;
  int playCount = 0;
  int pauseCount = 0;

  final List<String> loadedUris = <String>[];

  /// 前 N 次 load 抛错（模拟死链）。
  int failLoadCount = 0;

  /// 只允许 format=mp3 的 URL 加载成功（模拟「原始格式失败 → 转码重试」）。
  bool onlyMp3Loads = false;

  /// 前 N 次 play 抛错。
  int failPlayCount = 0;

  /// load 响应携带的时长（null = 模拟流不上报时长）。
  Duration? loadDuration = const Duration(seconds: 200);

  /// 事件消息里携带的时长。
  Duration eventDuration = const Duration(seconds: 200);

  Duration? emitPosOverride;
  ProcessingStateMessage emitState = ProcessingStateMessage.ready;
  int _tick = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      const Stream<PlayerDataMessage>.empty();

  void emit([ProcessingStateMessage? state]) {
    _tick += 1;
    final pos = emitPosOverride ?? Duration(seconds: _tick * 30);
    _events.add(
      PlaybackEventMessage(
        processingState: state ?? emitState,
        updateTime: DateTime.now(),
        updatePosition: pos,
        bufferedPosition: pos,
        duration: eventDuration,
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
    var uri = '';
    if (message is UriAudioSourceMessage) {
      uri = message.uri;
      loadedUris.add(uri);
    }
    if (failLoadCount > 0) {
      failLoadCount -= 1;
      throw StateError('b34a load fail#$loadCount');
    }
    if (onlyMp3Loads && !uri.contains('format=mp3')) {
      throw StateError('b34a need mp3 transcode');
    }
    scheduleMicrotask(() => emit());
    return LoadResponse(duration: loadDuration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (failPlayCount > 0) {
      failPlayCount -= 1;
      throw StateError('b34a play fail');
    }
    playCount += 1;
    return PlayResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    pauseCount += 1;
    return PauseResponse.fromMap(const <dynamic, dynamic>{});
  }

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
  int initCount = 0;
  _FakeAudioPlayerPlatform? last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    initCount += 1;
    // 单播放器测试：复用同一替身实例，保证 boot 期预创建与 playSong 期
    // AudioPlayer 拿到的是同一个（否则 failLoadCount 等开关会丢）。
    final existing = last;
    if (existing != null) return existing;
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

// ───────────────────────────── 其它桩 ─────────────────────────────────────

Song _song(
  String id, {
  int? duration = 200,
  String suffix = 'flac',
  String? coverArt,
}) =>
    Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: 1411,
      duration: duration,
      coverArt: coverArt,
      starred: false,
    );

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  int getSongCalls = 0;
  Song? nextSong;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async {
    getSongCalls += 1;
    return nextSong;
  }
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
  }) {
    final buf = StringBuffer('http://192.168.10.240:46400/rest/stream?id=$songId');
    if (format != null) buf.write('&format=$format');
    if (maxBitRate != null) buf.write('&maxBitRate=$maxBitRate');
    if (timeOffset != null) buf.write('&timeOffset=$timeOffset');
    return buf.toString();
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

class _FakeAddressPool extends AddressPool {
  _FakeAddressPool() : super(Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  bool routesOk = false;
  int probeCalls = 0;

  @override
  Future<ServerAddress?> probeAll() async {
    probeCalls += 1;
    if (routesOk) {
      return ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: 'http://192.168.10.240:46400',
        priority: 0,
        status: ServerAddressStatus.ok,
      );
    }
    return null;
  }
}

class _FakeConnectivityMonitor extends ConnectivityMonitor {
  _FakeConnectivityMonitor() : super(_FakeAddressPool());

  final StreamController<NetworkType> _ctrl =
      StreamController<NetworkType>.broadcast();
  NetworkType _cur = NetworkType.none;

  @override
  NetworkType get currentNetworkType => _cur;

  @override
  Stream<NetworkType> get networkTypeStream => _ctrl.stream;

  void push(NetworkType type) {
    _cur = type;
    _ctrl.add(type);
  }

  void pushError() {
    _ctrl.addError(StateError('b34a connectivity boom'));
  }
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
  // just_audio play() 内部会走 audio_session 的 setActive —— 测试环境无插件，
  // mock 掉通道让 play() 正常走完（否则 play 抛错触发自动跳歌，污染用例）。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (MethodCall call) async => null,
  );

  final repo = _FakeMusicRepository();
  final spy = _SpySubsonicApiClient();
  final connectivity = _FakeConnectivityMonitor();
  final pool = _FakeAddressPool();
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
          addressPoolProvider.overrideWithValue(pool),
          connectivityMonitorProvider.overrideWithValue(connectivity),
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

  Future<void> waitQuiet(PlayerNotifier notifier) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 4 && !notifier.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!notifier.debugIsRestoringPlaybackSession) return;
      }
    }
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
    // 预创建替身播放器：just_audio 懒初始化，首个 load 前拿不到实例。
    fake = await platform
        .init(InitRequest(id: 'b34a-pre')) as _FakeAudioPlayerPlatform;
    return n;
  }

  /// 激活替身播放器（必须先有源，事件/轮询才有落点）。
  Future<void> activate({
    List<Song>? queue,
    bool autoPlay = false,
    Song? song,
  }) async {
    await notifier.playSong(
      song ?? _song('s1'),
      queue: queue ?? <Song>[_song('s1')],
      index: 0,
      autoPlay: autoPlay,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    pool.routesOk = false;
    pool.probeCalls = 0;
    repo.getSongCalls = 0;
    repo.nextSong = null;
  });

  tearDown(() {
    container.dispose();
  });

  // ────────────── 一、playQueue / appendToQueue（1566-1597） ──────────────
  group('playQueue / appendToQueue', () {
    test('空队列直接早退；shuffleRandomStart 在随机模式下随机挑起点', () async {
      notifier = await boot();
      await notifier.playQueue(<Song>[], startIndex: 0);
      expect(notifier.state.currentSong, isNull);

      notifier.state = notifier.state.copyWith(
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        currentSong: _song('s1'),
        currentIndex: 0,
        playbackMode: PlaybackMode.shuffle,
        shuffleEnabled: true,
      );
      await notifier.playQueue(
        <Song>[_song('a1'), _song('a2'), _song('a3')],
        startIndex: 0,
        shuffleRandomStart: true,
      );
      expect(notifier.state.queue.length, 3);
      expect(
        notifier.state.currentIndex,
        allOf(greaterThanOrEqualTo(0), lessThan(3)),
      );
      // 非随机模式下 shuffleRandomStart 不生效：固定从第 0 首起。
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.all,
        shuffleEnabled: false,
      );
      await notifier.playQueue(
        <Song>[_song('b1'), _song('b2')],
        startIndex: 0,
        shuffleRandomStart: true,
      );
      expect(notifier.state.currentIndex, 0);
    });

    test('appendToQueue 只增长队尾、不动 currentIndex；空列表无操作', () async {
      notifier = await boot();
      await notifier.appendToQueue(<Song>[]);
      expect(notifier.state.queue, isEmpty);

      notifier.state = notifier.state.copyWith(
        queue: <Song>[_song('s1')],
        currentSong: _song('s1'),
        currentIndex: 0,
      );
      await notifier.appendToQueue(<Song>[_song('s2'), _song('s3')]);
      expect(notifier.state.queue.length, 3);
      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.queue.last.id, 's3');
    });
  });

  // ────────────── 二、togglePlayPause / play / pause（1547-1552、1817-1823） ──────────────
  group('togglePlayPause / pause', () {
    test('无当前曲时 togglePlayPause → play() 空会话守卫直接返回', () async {
      notifier = await boot();
      await notifier.togglePlayPause();
      expect(notifier.state.isPlaying, isFalse);
      expect(fake.playCount, 0);
    });

    test('有当前曲：toggle 起播 → 再 toggle 暂停且 isPlaying 落 false', () async {
      notifier = await boot();
      await activate(autoPlay: false);
      notifier.state = notifier.state.copyWith(isPlaying: false);
      await notifier.togglePlayPause();
      final started =
          await waitUntil(() => notifier.state.isPlaying);
      expect(started, isTrue);

      await notifier.togglePlayPause();
      final paused =
          await waitUntil(() => !notifier.state.isPlaying, ticks: 100);
      expect(paused, isTrue);
    });

    test('crossfade 开启时 pause 走淡出（_fadeOutForPause 全路径）', () async {
      notifier = await boot();
      await activate(autoPlay: true);
      await waitUntil(() => notifier.state.isPlaying);
      expect(fake.playCount, greaterThanOrEqualTo(1));

      // 动态开 crossfade：400ms → fadeMs=200 → 10 步 × 20ms ≈ 200ms 真实等待。
      // （CrossfadeNotifier 构造会异步 _load 覆盖 state，必须走 setDuration。）
      await container.read(crossfadeDurationMsProvider.notifier).setDuration(400);
      await notifier.pause();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final paused = await waitUntil(() => fake.pauseCount >= 1);
      expect(paused, isTrue);
      expect(notifier.state.isPlaying, isFalse);
    });
  });

  // ────────────── 三、setVolume 防抖落盘（1829-1852） ──────────────
  test('setVolume 立即生效，防抖 1s 后落盘 player_volume', () async {
    notifier = await boot();
    await notifier.setVolume(0.4);
    expect(notifier.state.volume, 0.4);
    await notifier.setVolume(1.4); // clamp 到 1.0
    expect(notifier.state.volume, 1.0);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    final stored = await LocalStorage.getPlayerVolume();
    expect(stored, 1.0);
  });

  // ────────────── 四、_updateMediaItem artUri（1447-1450） ──────────────
  test('带封面歌曲 playSong → artUri 分支被 Uri.parse 消费', () async {
    notifier = await boot();
    await activate(song: _song('c1', coverArt: 'abc123'));
    expect(notifier.state.currentSong?.id, 'c1');
    expect(fake.loadCount, 1);
  });

  // ────────────── 五、durationStream（663-679） ──────────────
  group('durationStream', () {
    test('元数据时长缺失（song.duration=null）→ 采用流时长', () async {
      notifier = await boot();
      fake.eventDuration = const Duration(seconds: 150);
      fake.loadDuration = const Duration(seconds: 150);
      await activate(song: _song('d1', duration: null));
      expect(notifier.state.currentSong?.duration, isNull);
      await waitUntil(
        () => notifier.state.duration == const Duration(seconds: 150),
      );
      expect(notifier.state.duration, const Duration(seconds: 150));
    });

    test('load 响应不携带时长（null）→ unavailable 分支，保持既有时长', () async {
      notifier = await boot();
      fake.eventDuration = const Duration(seconds: 150);
      fake.loadDuration = null; // _durationSubject.add(null)
      await activate(song: _song('d2', duration: null));
      // 先由事件流补齐 150s，再被 null 分支忽略（保持 150s）。
      await waitUntil(
        () => notifier.state.duration == const Duration(seconds: 150),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state.duration, const Duration(seconds: 150));
    });
  });

  // ────────────── 六、断线重试链（1231-1252、769-788、830-886） ──────────────
  group('播放失败重连重试链', () {
    test('无可用线路 → 安排重试；网络恢复 → 自动重试成功', () async {
      notifier = await boot();
      fake.failLoadCount = 1;
      pool.routesOk = false;
      await notifier.playSong(
        _song('r1'),
        queue: <Song>[_song('r1')],
        index: 0,
        autoPlay: false,
      );
      expect(pool.probeCalls, 1);
      expect(notifier.state.currentSong?.id, 'r1');

      connectivity.push(NetworkType.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      // 重试发生：load 第二次成功，playbackSource 落成 stream。
      expect(fake.loadCount, 2);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
    });

    test('网络监听 onError 分支不炸；当前曲已换歌时重试清理 + 正常重试', () async {
      notifier = await boot();
      connectivity.pushError();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 安排一次重试后把当前曲换掉 → current_song_changed 清理分支。
      fake.failLoadCount = 1;
      pool.routesOk = false;
      await notifier.playSong(
        _song('r2'),
        queue: <Song>[_song('r2')],
        index: 0,
        autoPlay: false,
      );
      notifier.state = notifier.state.copyWith(currentSong: _song('other'));
      connectivity.push(NetworkType.mobile);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fake.loadCount, 1); // 没有发起重试加载

      // 当前曲与 pendingRetry 一致 → 重试成功（r3 第二次加载成功）。
      fake.failLoadCount = 1;
      await notifier.playSong(
        _song('r3'),
        queue: <Song>[_song('r3')],
        index: 0,
        autoPlay: false,
      );
      expect(fake.loadCount, 2);
      connectivity.push(NetworkType.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(fake.loadCount, 3);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
    });
  });

  // ────────────── 七、MP3 转码重试（1264-1399） ──────────────
  group('转码重试', () {
    test('原始 mp3 失败且有线路 → format=mp3 重试成功', () async {
      notifier = await boot();
      pool.routesOk = true;
      fake.onlyMp3Loads = true;
      await notifier.playSong(
        _song('t1', suffix: 'mp3'),
        queue: <Song>[_song('t1', suffix: 'mp3')],
        index: 0,
        autoPlay: false,
      );
      expect(fake.loadCount, 2);
      expect(fake.loadedUris.last.contains('format=mp3'), isTrue);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
      expect(notifier.state.currentSong?.id, 't1');
    });

    test('转码也失败 → 跳下一首（_handlePlaybackError）', () async {
      notifier = await boot();
      pool.routesOk = true;
      fake.failLoadCount = 2; // 原始 + 转码都失败
      await notifier.playSong(
        _song('t2', suffix: 'mp3'),
        queue: <Song>[_song('t2', suffix: 'mp3'), _song('t3')],
        index: 0,
        autoPlay: false,
      );
      // t1 原始失败 → 转码失败 → 自动跳到 t3（加载成功）。
      await waitUntil(() => notifier.state.currentSong?.id == 't3');
      expect(fake.loadCount, 3);
    });
  });

  // ────────────── 八、play() 抛错 → 跳歌（1504-1508） ──────────────
  test('底层 play() 抛错 → catchError → 自动跳下一首', () async {
    notifier = await boot();
    fake.failPlayCount = 1;
    await notifier.playSong(
      _song('p1'),
      queue: <Song>[_song('p1'), _song('p2')],
      index: 0,
      autoPlay: true,
    );
    await waitUntil(() => notifier.state.currentSong?.id == 'p2');
    expect(fake.failPlayCount, 0);
  });

  // ────────────── 九、Windows SMTC 分支（492-504） ──────────────
  test('Windows 平台 → AudioService 降级 + SmtcService 初始化路径', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      notifier = await boot();
      expect(notifier.state, isNotNull);
      // 桌面路径不走 audio_service（_audioHandler 为 null），但播放仍可用。
      await activate();
      expect(notifier.state.currentSong?.id, 's1');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // ────────────── 十、_restorePlaybackMode orElse（2397-2400） ──────────────
  test('持久化的播放模式名非法 → orElse 回落 PlaybackMode.all', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'playback_mode': 'junk_mode',
    });
    notifier = await boot();
    expect(notifier.state.playbackMode, PlaybackMode.all);
  });

  // ────────────── 十一、persistPlaybackStateNow（2751-2790） ──────────────
  test('persistPlaybackStateNow 串行等待在途写（_awaitInFlightPersist 租约）', () async {
    notifier = await boot();
    await activate();

    final gate = Completer<void>();
    notifier.debugBeforePersistWrite = () => gate.future;

    final f1 = notifier.persistPlaybackStateNow();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final f2 = notifier.persistPlaybackStateNow(); // 撞上在途写 → 等待
    gate.complete();
    await f1;
    await f2;
    notifier.debugBeforePersistWrite = null;
    expect(notifier.state.currentSong?.id, 's1');
  });

  // ────────────── 十二、refreshSongMetadata（2668-2695） ──────────────
  test('refreshSongMetadata 更新当前曲与队列镜像；空 id 早退', () async {
    notifier = await boot();
    final before = repo.getSongCalls; // 前序用例的异步刷新可能已计入
    await notifier.refreshSongMetadata('  ');
    expect(repo.getSongCalls, before);

    await activate();
    repo.nextSong = _song('s1').copyWith(title: '已补齐');
    await notifier.refreshSongMetadata('s1');
    await waitUntil(() => notifier.state.currentSong?.title == '已补齐');
    expect(notifier.state.queue.first.title, '已补齐');

    // 队列里非当前曲的补齐路径。
    notifier.state = notifier.state.copyWith(
      queue: <Song>[_song('s1'), _song('s9')],
    );
    repo.nextSong = _song('s9').copyWith(title: 's9-新');
    await notifier.refreshSongMetadata('s9');
    await waitUntil(() => notifier.state.queue[1].title == 's9-新');
    expect(notifier.state.currentSong?.id, 's1');
  });
}
