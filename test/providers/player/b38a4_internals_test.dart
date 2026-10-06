// b38a4 —— Route A 播放核心补测（player_provider 内部可达分支 + 预探测缓存）。
//
// 复用 b38a/b37a2 的真实 PlayerNotifier harness：just_audio 平台换替身、
// 外部 provider 全桩。目标为 player 目录**联合覆盖率仍 0 命中**的可达分支：
//   * player_provider 2140      : syncQueueForCast 同 id 继承原红心
//   * player_provider 2156/2162 : 权威收藏列表(starredProvider)校正 current.starred
//   * player_playback_helpers 94 : _probeFresh 命中已有缓存条目
//   * player_playback_helpers 267: 预探测缓存超上限整体清空
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
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
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/crossfade_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

// ─────────────────────────── 替身 just_audio 平台 ───────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id, this._platform);

  final _FakeJustAudioPlatform _platform;

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  int playCount = 0;
  final List<double> volumeCalls = <double>[];

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final gate = _platform.gate;
    if (gate != null) await gate.future;
    if (_platform.throwOnLoad) throw StateError('load boom');
    scheduleMicrotask(
      () => _events.add(
        PlaybackEventMessage(
          processingState: ProcessingStateMessage.ready,
          updateTime: DateTime.now(),
          updatePosition: const Duration(seconds: 30),
          bufferedPosition: const Duration(seconds: 30),
          duration: const Duration(seconds: 200),
          icyMetadata: null,
          currentIndex: 0,
          androidAudioSessionId: null,
        ),
      ),
    );
    return LoadResponse(duration: const Duration(seconds: 200));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    playCount += 1;
    return PlayResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async =>
      PauseResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SeekResponse> seek(SeekRequest request) async =>
      SeekResponse.fromMap(const <dynamic, dynamic>{});

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

  /// 非空时后续 load() 先等它完成（把预览播放精确停在加载前）。
  Completer<void>? gate;

  /// 置真后 load() 抛错。
  bool throwOnLoad = false;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = _FakeAudioPlayerPlatform(request.id, this);
    last = p;
    return p;
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
  String suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
  bool starred = false,
}) =>
    Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
      duration: duration,
      starred: starred,
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
  _FakeCacheManager() : super();

  @override
  Future<void> init() async {}

  @override
  File? songFile(String songId) => null;
}

class _FakeDlnaManager extends DlnaManager {}

/// 地址池替身：`probeAll` 直接给一条 ok 线路（让失败后的路由刷新通过）。
class _FakeAddressPool extends AddressPool {
  _FakeAddressPool()
      : super(Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  ServerAddress? activeAddr;

  @override
  ServerAddress? get activeAddress => activeAddr;

  @override
  Future<ServerAddress?> probeAll() async => activeAddr;

  @override
  List<ServerAddress> get addresses =>
      activeAddr == null ? const <ServerAddress>[] : <ServerAddress>[activeAddr!];
}

/// 可写淡入淡出时长的桩 notifier。
class _FakeCrossfade extends CrossfadeNotifier {
  _FakeCrossfade() : super();
}

/// 可控连通性监控替身：绕过真实平台探测，手动推送网络类型变化以驱动
/// `_initConnectivityRetryHandling` 的重连重试链路。
class _CtlMonitor extends ConnectivityMonitor {
  _CtlMonitor() : super(AddressPool(Dio()));

  final StreamController<NetworkType> _ctl =
      StreamController<NetworkType>.broadcast();
  NetworkType _cur = NetworkType.wifi;

  @override
  NetworkType get currentNetworkType => _cur;

  @override
  Stream<NetworkType> get networkTypeStream => _ctl.stream;

  void emit(NetworkType t) {
    _cur = t;
    _ctl.add(t);
  }

  void dispose() => _ctl.close();
}

_FakeCrossfade? _cf;

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);
}

class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  /// `_probeUpcoming` 读取的探测响应。
  Map<String, dynamic> probeResponse = <String, dynamic>{};

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
  }) async {
    if (path.contains('/stream/probe')) return probeResponse;
    return <String, dynamic>{};
  }
}

Song _previewSong(String id) => Song(
      id: id,
      title: '试听$id',
      artist: '歌手',
      suffix: 'mp3',
      duration: 60,
      isPreview: true,
      previewStreamUrl: 'https://music.example.test/preview/$id.mp3',
    );

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
  final dlnaManager = _FakeDlnaManager();
  final pool = _FakeAddressPool();

  late List<Song> starredSongs;
  late Completer<ServerAddress> addrGate;

  ProviderContainer buildContainer({
    List<Override>? extra,
    bool nullActiveAddress = false,
    _CtlMonitor? monitor,
  }) =>
      ProviderContainer(
        overrides: <Override>[
          ...?extra,
          if (monitor != null)
            connectivityMonitorProvider.overrideWith((ref) => monitor),
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
            (ref) => nullActiveAddress
                ? null
                : ServerAddress(
                    id: 'a1',
                    libraryId: 'lib1',
                    label: '主库',
                    url: 'http://192.168.10.240:46400',
                    priority: 0,
                  ),
          ),
          ensureActiveAddressProvider.overrideWith((ref) => addrGate.future),
          effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          crossfadeDurationMsProvider.overrideWith((ref) {
            _cf = _FakeCrossfade();
            _cf!.state = 0;
            return _cf!;
          }),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          offlineCacheManagerProvider.overrideWithValue(_FakeCacheManager()),
          offlineCacheReadyProvider.overrideWith((ref) async {}),
          dlnaManagerProvider.overrideWithValue(dlnaManager),
          addressPoolProvider.overrideWithValue(pool),
          castPeerControllerProvider.overrideWith(
            (ref) => _FakeCastPeerController(ref),
          ),
          starredProvider.overrideWith(
            (ref) async => StarredResult(
              artists: const <Artist>[],
              albums: const <Album>[],
              songs: starredSongs,
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

  late ProviderContainer container;
  late PlayerNotifier notifier;
  late _FakeJustAudioPlatform platform;

  Future<PlayerNotifier> boot({
    bool nullActiveAddress = false,
    _CtlMonitor? monitor,
  }) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container =
        buildContainer(nullActiveAddress: nullActiveAddress, monitor: monitor);
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  Future<void> waitUntil(bool Function() cond, {int ticks = 200}) async {
    for (var i = 0; i < ticks; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  bool hasRestoreAfterPartial(List<double> calls, double vol) {
    for (var i = 1; i < calls.length - 1; i++) {
      final v = calls[i];
      if (v > 0.0 && v < vol && calls[i + 1] == vol) return true;
    }
    return false;
  }

  setUp(() {
    starredSongs = <Song>[];
    spy.probeResponse = <String, dynamic>{};
    pool.activeAddr = ServerAddress(
      id: 'a1',
      libraryId: 'lib1',
      label: '主库',
      url: 'http://192.168.10.240:46400',
      priority: 0,
      status: ServerAddressStatus.ok,
    );
    addrGate = Completer<ServerAddress>();
  });

  tearDown(() => container.dispose());

  // ───────── syncQueueForCast 红心继承（2140） ─────────
  test('syncQueueForCast: 同 id 继承原红心(2140)', () async {
    // 权威列表同样含 x（否则 2162 会把它校正回 false）。
    starredSongs = <Song>[_song('x', starred: true)];
    notifier = await boot();
    // 当前曲 x 已收藏，投屏镜像项 x 恒 starred=false → 2140 继承原值。
    notifier.state = notifier.state.copyWith(
      currentSong: _song('x', starred: true),
    );

    notifier.syncQueueForCast(<Map<String, dynamic>>[
      <String, dynamic>{'songId': 'x', 'title': '曲x'},
    ], 0);

    expect(notifier.state.currentSong?.id, 'x');
    expect(notifier.state.currentSong?.starred, isTrue,
        reason: '继承原红心(2140)');
  });

  // ───────── 权威收藏校正（2156/2162） ─────────
  test('syncQueueForCast: 权威列表把未收藏校正为已收藏(2156/2162)', () async {
    // 权威列表含 x → 与镜像项(starred=false)不同 → 2162 校正。
    starredSongs = <Song>[_song('x', starred: true)];
    notifier = await boot();
    notifier.state = notifier.state.copyWith(
      currentSong: _song('x', starred: false),
    );

    notifier.syncQueueForCast(<Map<String, dynamic>>[
      <String, dynamic>{'songId': 'x', 'title': '曲x'},
    ], 0);

    expect(notifier.state.currentSong?.id, 'x');
    expect(notifier.state.currentSong?.starred, isTrue,
        reason: '命中权威列表(2156) → 校正为已收藏(2162)');
  });

  // ───────── 预探测缓存：命中已有条目(94) ─────────
  test('预探测：all 回绕候选命中已有缓存 → _probeFresh 走条目分支(94)',
      () async {
    spy.probeResponse = <String, dynamic>{
      'results': <dynamic>[
        <String, dynamic>{'songId': 'b', 'ok': true, 'verdict': 'playable'},
      ],
    };
    notifier = await boot();
    notifier.state =
        notifier.state.copyWith(playbackMode: PlaybackMode.all);
    // 第一轮 index=0：候选 b/c，响应只固化 b。
    await notifier.playSong(
      _song('a'),
      queue: <Song>[_song('a'), _song('b'), _song('c')],
      index: 0,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 第二轮 index=2（all 回绕）：wrap 命中 b，缓存已有 → _probeFresh 走条目分支(94)。
    await notifier.playSong(
      _song('c'),
      queue: <Song>[_song('a'), _song('b'), _song('c')],
      index: 2,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(notifier.state.currentSong?.id, 'c');
  });

  // ───────── 预探测缓存：超上限整体清空(267) ─────────
  test('预探测：缓存超上限 → 整体清空(267)', () async {
    spy.probeResponse = <String, dynamic>{
      'results': <dynamic>[
        for (var i = 0; i < 501; i++)
          <String, dynamic>{
            'songId': 's$i',
            'ok': true,
            'verdict': 'playable',
          },
      ],
    };
    notifier = await boot();
    await notifier.playSong(
      _song('a'),
      queue: <Song>[_song('a'), _song('b')],
      index: 0,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(notifier.state.currentSong?.id, 'a');
  });

  // ───────── 连续失败自动跳：转码重试入口 + 连跳节流闸(387) ─────────
  // 注：player_provider 1303/1335/1342/1376 等行含 `?? _playDebugSession` 右操作数，
  // 仅当转码重试以 debugSession==null 调用时才求值（现有链路均带 session）→ 未覆盖。
  test('连续音源失败 → 转码重试链路 + 连跳节流闸(player_seek:387, provider:1333)',
      () async {
    notifier = await boot();
    platform.throwOnLoad = true; // 所有音源加载都失败（须在 boot 建平台之后置位）
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
      shuffleEnabled: false,
    );

    // order 模式 + 3 首全部失败：逐首自动跳，第 3 次加载前 _consecutiveFailSkips>=2
    // 命中连跳节流闸(387)；每次直连失败后进入转码重试(1303..)。
    await notifier.playSong(
      _song('a', suffix: 'flac'),
      queue: <Song>[_song('a'), _song('b'), _song('c')],
      index: 0,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(notifier.state.currentSong?.id, isNotNull);
  });

  // ───────── 等地址期间被试听 playSong 顶掉会话 → 放弃本轮(1103/1105) ─────────
  test('等地址期间被试听 playSong 顶掉会话 → 放弃本轮(1103/1105)', () async {
    pool.activeAddr = null; // 走 ensureActiveAddress 闸门
    notifier = await boot(nullActiveAddress: true);
    final first = notifier.playSong(_song('a')); // 会话 1 → 停在地址闸门
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // 试听 playSong 在 1620 同步自增会话号（不 await 地址），顶掉会话 1。
    unawaited(notifier.playSong(_previewSong('p1')));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    addrGate.complete(
      ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: 'http://192.168.10.240:46400',
        priority: 0,
        status: ServerAddressStatus.ok,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await first.timeout(const Duration(seconds: 10));

    expect(notifier.state.currentSong?.id, 'p1',
        reason: '会话 1 在 1102 判定作废 → 1103/1105 留痕并 return');
  });

  // ───────── 随机历史：同 id 不同 index 记为「不同曲」(37) ─────────
  test('shuffle 强制下一首同 id 不同 index → 记入历史(37)', () async {
    notifier = await boot();
    notifier.state = notifier.state.copyWith(
      shuffleEnabled: true,
      playbackMode: PlaybackMode.all,
      loopMode: LoopMode.all,
    );
    await notifier.playSong(
      _song('a'),
      queue: <Song>[_song('a'), _song('b')],
      index: 0,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // playNext 插入一份同 id 曲目到 index 1，forced id == 当前曲 id。
    await notifier.playNext(_song('a'));
    await notifier.next();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    // 命中 37：currentEntry.songId == nextSong.id，但 preferredIndex != nextIndex。
    expect(notifier.state.currentSong?.id, 'a');
    expect(notifier.state.currentIndex, 1);
    expect(notifier.state.shuffleHistoryCount, greaterThan(0),
        reason: '同 id 不同 index 视为不同曲 → 记入历史(37/39)');
  });

  // ───────── 淡出途中会话被顶掉 → 定时器自中止(40-48) ─────────
  test('淡出途中试听 playSong 顶掉会话 → 中止并恢复音量(40-48)', () async {
    notifier = await boot();
    await notifier.playSong(_song('s1'), queue: <Song>[_song('s1')], autoPlay: false);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _cf!.state = 1000; // fadeMs=500 ⇒ 25 步斜坡
    await notifier.play(); // 顶起 playing，进入 __fadeOut 主体
    final pl = platform.last!;
    await waitUntil(() => pl.playCount > 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    pl.volumeCalls.clear();

    final pending = notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      pl.volumeCalls.any((v) => v > 0.0 && v < notifier.state.volume),
      isTrue,
      reason: '此刻应在淡出半坡上',
    );

    // 试听 playSong 走 _playPreviewSongInternal（1620 自增会话号且不 cancelFade）；
    // 用加载闸门把预览停在起播之前，让淡出定时器先 tick 到「会话已变」(40-48)。
    platform.gate = Completer<void>();
    unawaited(notifier.playSong(_previewSong('p1')));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    platform.gate!.complete();
    platform.gate = null;
    await pending.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(hasRestoreAfterPartial(pl.volumeCalls, notifier.state.volume), isTrue,
        reason: '半坡后直接跳回满值 ⇒ 走 47 行中止分支');
  });

  // ───────── 淡入途中会话被顶掉 → 定时器自中止(90-93) ─────────
  test('淡入途中试听 playSong 顶掉会话 → 中止并恢复音量(90-93)', () async {
    notifier = await boot();
    await notifier.playSong(_song('s1'), queue: <Song>[_song('s1')], autoPlay: false);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _cf!.state = 1000;
    final pl = platform.last!;
    pl.volumeCalls.clear();

    // autoPlay=true ⇒ _startPlayback 起一条淡入斜坡。
    await notifier.playSong(_song('s2'), queue: <Song>[_song('s2')]);
    await waitUntil(() => pl.playCount > 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pl.volumeCalls, isNotEmpty, reason: '淡入已从 0 起步');

    // 加载闸门把预览停在起播前 → 淡入定时器先 tick 到「会话已变」(90-93)，
    // 且预览不会起自己的淡入把音量再拉下去。
    platform.gate = Completer<void>();
    unawaited(notifier.playSong(_previewSong('p2')));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    platform.gate!.complete();
    platform.gate = null;
    // 等预览自身淡入收敛：最终音量回到 state.volume（中止分支 93 与正常收敛同值）。
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    expect(pl.volumeCalls.last, notifier.state.volume,
        reason: '音量最终恢复到 state.volume，不残留半坡值');
  });

  // ───────── 重连重试：无当前曲 → 清理重试态(840) ─────────
  test('断网重连重试：无当前曲 → 清理重试态(840)', () async {
    pool.activeAddr = null; // 无即时地址 → 走 ensure 闸门
    final mon = _CtlMonitor();
    notifier = await boot(nullActiveAddress: true, monitor: mon);
    // 无路由 → playSong 未就绪即调度「重连重试」，并已把当前曲置为 b。
    final f = notifier.playSong(_song('b'), queue: <Song>[_song('b')], index: 0);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final guard = addrGate.future.then<void>((_) {}, onError: (Object _) {});
    addrGate.completeError(StateError('no route'));
    await guard;
    await f.catchError((Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(notifier.state.currentSong?.id, 'b');

    // 清空队列（保留重试标记）→ currentSong 归零，但重试意图仍在。
    await notifier.clearQueue(keepCurrent: false);
    expect(notifier.state.currentSong, isNull);

    // 网络类型变化 → _retryCurrentPlaybackIfNeeded → song==null → 840 清理重试态。
    mon.emit(NetworkType.mobile);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    mon.dispose();
    expect(notifier.state.currentSong, isNull);
  });

  // ───────── 重连重试：currentIndex 与当前曲错位 → 队列内重定位(865-868) ─────────
  test('断网重连重试：currentIndex 与当前曲错位 → 队列内重定位(865-868)',
      () async {
    final mon = _CtlMonitor();
    notifier = await boot(nullActiveAddress: true, monitor: mon);
    pool.activeAddr = null;
    // queue[0]=a 却播 b(index 0)：currentSong=b 而 queue[currentIndex]≠b。
    final f = notifier.playSong(
      _song('b'),
      queue: <Song>[_song('a'), _song('b')],
      index: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final guard = addrGate.future.then<void>((_) {}, onError: (Object _) {});
    addrGate.completeError(StateError('no route'));
    await guard;
    await f.catchError((Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(notifier.state.currentSong?.id, 'b');

    // 网络变化 → 重试 → 844 通过(pending==b)，但 864 判否 → 865-868 队列内 indexWhere 重定位。
    mon.emit(NetworkType.mobile);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    mon.dispose();
    expect(notifier.state.currentSong?.id, 'b');
  });
}
