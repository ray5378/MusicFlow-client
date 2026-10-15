// batch44 —— 播放流抗断网配套（服务端 30 分钟取流重试窗口的客户端配合）。
//
// 背景：服务端对新歌取流失败会**挂起请求自动重试**（前 1 分钟每 10s →之后
// 每分钟→总窗口 30 分钟）才显式失败。客户端在此窗口内不得提前掐断：
//
// 被钉行为：
//   1. 取流路径现状钉子：播放走 just_audio `player.setUrl` 直连 HTTP（不经
//      dio），客户端唯一会提前掐断在途流请求的是「0 秒卡死看门狗」(6s reload
//      /18s 放弃跳歌)。流加载在途（服务端重试窗口内 setUrl 不返回）期间，
//      看门狗必须延迟介入：不 reload、不跳歌 —— 否则 reload 会拆掉在途请求、
//      让服务端重开整个 30 分钟窗口，也是无节流紧凑重试（D-058 教训）。
//   2. 窗口落定成功：加载完成即正常起播，无额外 reload。
//   3. 服务端显式失败（窗口尽后报错）：setUrl 抛错 → 原格式失败进转码重试 →
//      仍失败 → _handlePlaybackError 自动跳下一首（流错误照常进入既有
//      自动重试/跳歌路径，逐首真试，不退化成紧凑连转）。
//
// 姿势与 b40e2_player_offline_skip_test.dart 完全一致：驱动真实 PlayerNotifier，
// just_audio 平台换替身（load 可挂起/可抛错），外部 provider 全桩。
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

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  int loadCount = 0;
  final List<String> loadedUris = <String>[];

  /// 每次 load 的时间戳 + uri(诊断用)。
  final List<String> loadLog = <String>[];

  /// 非空时 load 挂起直至 complete —— 模拟服务端挂起重试窗口内不返回。
  Completer<void>? loadGate;

  /// 置真时 load 直接抛错 —— 模拟服务端重试窗口尽后显式失败。
  bool throwOnLoad = false;

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

  /// 发一条「loading + 位置钉在 0 + duration=0」的事件：对照用例模拟
  /// 「服务端取流失败挂起重试窗口」这一**合法**长等待形态（platform 处于
  /// [ProcessingStateMessage.loading]，而非 idle）。
  ///
  /// 注：替身不 emit 时 just_audio 自己会把 processingState 置为 **loading**
  /// （平台加载开始即合成），所以要复现「idle 停滞」必须显式发 idle 事件。
  void emitLoadingAtStart() {
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.loading,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: Duration.zero,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  Timer? _idlePinTimer;

  /// 周期钉住「idle + 位置 0 + duration 0」：复现 Windows v5.8.0 实测日志中
  /// 「平台层压根没接管音源」的形态（processingState 落到 idle 并永远停住，
  /// 而 setUrl 的 Future 既不 resolve 也不 reject）。
  ///
  /// 两个坑，都是必须的绕法：
  /// 1. just_audio 会在 `_platformLoading` 为真时把平台发来的 idle **强制覆盖**
  ///    成 loading（“The platform may emit an idle state while it's starting up
  ///    which we override here”），所以先发一条 ready 让该覆盖失效，再钉 idle。
  /// 2. 必须**周期**重发：just_audio 在 playing 时会按 updateTime 外推 position，
  ///    只发一次会把位置一路推过 1.5s（atStart 失守 → 看门狗永远攒不到阈值）。
  void startIdlePin() {
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: Duration.zero,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
    _idlePinTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      // 每轮先发 ready（持续解除 just_audio 的 idle→loading 覆盖：每次 reload
      // 都会重新置起 _platformLoading），再发 idle 收尾 —— 一次轮询采样到的是
      // 本轮最后那条 idle。
      for (final state in const [
        ProcessingStateMessage.ready,
        ProcessingStateMessage.idle,
      ]) {
        _events.add(
          PlaybackEventMessage(
            processingState: state,
            updateTime: DateTime.now(),
            updatePosition: Duration.zero,
            bufferedPosition: Duration.zero,
            duration: Duration.zero,
            icyMetadata: null,
            currentIndex: 0,
            androidAudioSessionId: null,
          ),
        );
      }
    });
  }

  void stopIdlePin() {
    _idlePinTimer?.cancel();
    _idlePinTimer = null;
  }

  Timer? _loadingPinTimer;

  /// 周期钉住「loading + 位置 0 + duration 0」：复现「平台已接管、正等服务端
  /// 重试窗口」这一**合法**长等待形态（processingState 持续为 loading）。
  ///
  /// 与 [startIdlePin] 的差异：loading 属「非 idle」，会命中 just_audio 的
  /// `_platformLoading` 掩码清除分支并被原样上报为 loading，故**无需**先发 ready。
  /// 每 200ms 重发以钉住位置（防止 playing 时按 updateTime 外推越过 1.5s，使
  /// 0 秒卡死看门狗因 atStart 失守而自行停摆——那样就无法证明「loading 分支
  /// 才是没误杀的原因」）。
  ///
  /// [duration] 默认为 [Duration.zero]（模拟「打开后仍未知时长」）；传非零值可复现
  /// libmpv/flac「一打开就带总时长」的真实情形（见 loading 档回归钉子用例）。
  void startLoadingPin({Duration duration = Duration.zero}) {
    _loadingPinTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      _events.add(
        PlaybackEventMessage(
          processingState: ProcessingStateMessage.loading,
          updateTime: DateTime.now(),
          updatePosition: Duration.zero,
          bufferedPosition: Duration.zero,
          duration: duration,
          icyMetadata: null,
          currentIndex: 0,
          androidAudioSessionId: null,
        ),
      );
    });
  }

  void stopLoadingPin() {
    _loadingPinTimer?.cancel();
    _loadingPinTimer = null;
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loadCount += 1;
    final message = request.audioSourceMessage;
    if (message is UriAudioSourceMessage) {
      loadedUris.add(message.uri);
    }
    loadLog.add(
      '${DateTime.now().millisecondsSinceEpoch % 100000} '
      '${message is UriAudioSourceMessage ? message.uri : message.runtimeType} '
      '<<< ${StackTrace.current.toString().split('\n').take(8).join(' | ')}',
    );
    if (throwOnLoad) {
      // 模拟服务端重试窗口尽后显式失败(必须是 Exception 形态的错误,
      // 与真实 HTTP/播放器失败一致;Error 子类会撞 b41e1 的 Error 穿透守卫)。
      throw Exception('server explicit failure after retry window');
    }
    final gate = loadGate;
    if (gate != null) {
      // 服务端挂起重试：setUrl 一直不返回（在途流加载）。
      await gate.future;
    }
    scheduleMicrotask(() => emit(ProcessingStateMessage.ready));
    return LoadResponse(duration: const Duration(seconds: 200));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    return PlayResponse.fromMap(const <dynamic, dynamic>{});
  }

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
  _FakeJustAudioPlatform(this.player);

  final _FakeAudioPlayerPlatform player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => player;

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

// ─────────────────────────── 其它桩（与 b40e2 一致） ───────────────────────────

Song _song(String id) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'flac',
      bitRate: 1411,
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

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController();
}

/// 地址池替身:probeAll 即刻返回 ok 线路,避免播放失败路径
/// (_refreshRoutesAndCheckAvailability)触发真实网络探测(5s 超时)拖垮用例。
class _FakeAddressPool extends AddressPool {
  _FakeAddressPool() : super(Dio());

  ServerAddress get _okAddress => ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: 'http://192.168.10.240:46400',
        priority: 0,
        status: ServerAddressStatus.ok,
      );

  @override
  Future<ServerAddress?> probeAll() async => _okAddress;

  @override
  List<ServerAddress> get addresses => <ServerAddress>[_okAddress];
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

  ProviderContainer buildContainer(_FakeAudioPlayerPlatform platform) {
    return ProviderContainer(
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
        addressPoolProvider.overrideWithValue(_FakeAddressPool()),
        effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
        isOfflineProvider.overrideWithValue(false),
        subsonicApiClientProvider.overrideWithValue(spy),
        musicRepositoryProvider.overrideWithValue(repo),
        offlineCacheDaemonProvider.overrideWith(
          (ref) => _NoopOfflineCacheDaemon(ref),
        ),
        offlineCacheManagerProvider.overrideWithValue(_FakeCacheManager()),
        offlineCacheReadyProvider.overrideWith((ref) async {}),
        castPeerControllerProvider.overrideWith(() => _FakeCastPeerController(),
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
  }

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
  late _FakeJustAudioPlatform justAudio;

  setUp(() {
    justAudio = _FakeJustAudioPlatform(_FakeAudioPlayerPlatform('test'));
    JustAudioPlatform.instance = justAudio;
  });

  tearDown(() => container.dispose());

  group('抗断网:服务端挂起重试窗口内客户端不提前掐断', () {
    test('流加载在途:0 秒卡死看门狗不 reload 不跳歌,等窗口落定', () async {
      justAudio.player.loadGate = Completer<void>();
      container = buildContainer(justAudio.player);
      final notifier = container.read(playerProvider.notifier);
      await waitQuiet(notifier);

      // 服务端挂起:setUrl 一直不返回。旧实现在 6s 触发看门狗 reload、
      // 12s 再 reload、18s 放弃跳歌;修复后必须全程按兵不动。
      unawaited(
        notifier.playSong(
          _song('s0'),
          queue: <Song>[_song('s0'), _song('s1')],
          index: 0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 7600));

      expect(
        justAudio.player.loadCount,
        1,
        reason: '在途流加载(服务端重试窗口)期间不得 reload —— reload 会拆掉'
            '在途请求并让服务端重开整个 30 分钟窗口',
      );
      expect(
        notifier.state.currentSong?.id,
        's0',
        reason: '窗口内不得自动跳歌,当前曲保持 s0',
      );
    });

    test('窗口落定成功:加载完成即正常起播,无额外 reload', () async {
      justAudio.player.loadGate = Completer<void>();
      container = buildContainer(justAudio.player);
      final notifier = container.read(playerProvider.notifier);
      await waitQuiet(notifier);

      unawaited(
        notifier.playSong(
          _song('s0'),
          queue: <Song>[_song('s0')],
          index: 0,
        ),
      );
      // 先挂起 ~2s(攒若干 watchdog tick 但不达阈值),再放行 —— 模拟服务端
      // 重试 2s 后取到流。
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      justAudio.player.loadGate!.complete();
      await waitQuiet(notifier);

      expect(notifier.state.currentSong?.id, 's0');
      expect(
        notifier.state.isPlaying,
        isTrue,
        reason: '窗口落定(加载完成)后应自动起播',
      );
      // 全部加载都是 s0 原始格式:没有转码重试、没有换歌。
      for (final uri in justAudio.player.loadedUris) {
        expect(uri, contains('id=s0'));
        expect(uri, isNot(contains('format=mp3')), reason: '不得进入转码重试');
      }
      // 不出现第三次加载。注:just_audio 单次 setUrl 内部可能对替身平台发
      // 1~2 次 load(平台激活加载 + setAudioSource 显式加载,版本行为差异),
      // 两者都不是业务层 reload;真正的看门狗 reload/转码重试会带来
      // 「新的 setUrl 往返」,这里钉死上界 ≤ 2。
      expect(
        justAudio.player.loadedUris.length,
        lessThanOrEqualTo(2),
        reason: '窗口落定成功后不得再 reload(看门狗/重试均不应发生) '
            '(loadLog=${justAudio.player.loadLog})',
      );
    });
  });

  group('流显式失败进入既有自动重试/跳歌路径', () {
    test('setUrl 抛错:原格式失败 → 转码重试 → 自动跳下一首(逐首真试)', () async {
      justAudio.player.throwOnLoad = true;
      container = buildContainer(justAudio.player);
      final notifier = container.read(playerProvider.notifier);
      await waitQuiet(notifier);
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );

      unawaited(
        notifier.playSong(
          _song('s0'),
          queue: <Song>[_song('s0'), _song('s1')],
          index: 0,
        ),
      );
      await waitQuiet(notifier);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(
        notifier.state.currentSong?.id,
        's1',
        reason: '流显式失败后照常走 _handlePlaybackError 自动跳歌 '
            '(loadLog=${justAudio.player.loadLog} '
            'loadCount=${justAudio.player.loadCount} '
            'playing=${notifier.state.isPlaying} '
            'processing=${notifier.state.processingState})',
      );
      // 每首歌都被真试两遍(原格式 + MP3 转码重试),非紧凑单发:
      // id=s0 出现 2 次、id=s1 出现 2 次。
      final s0Loads = justAudio.player.loadedUris
          .where((u) => u.contains('id=s0'))
          .length;
      final s1Loads = justAudio.player.loadedUris
          .where((u) => u.contains('id=s1'))
          .length;
      expect(
        s0Loads,
        2,
        reason: 's0 应被真试:原格式 1 次 + 转码重试 1 次',
      );
      expect(
        s1Loads,
        2,
        reason: 's1 同样原格式 + 转码各真试一次',
      );
      expect(
        notifier.state.isPlaying,
        isFalse,
        reason: '队列(order 模式)尽头的失败歌落暂停态,不无限绕圈',
      );
    });
  });

  // batch45 —— 抗断网延后必须**有界且按状态判别**（修「Windows 卡死在歌曲开头」）。
  //
  // 用户 v5.8.0 Windows(via media_kit/libmpv) 实测日志坐实：反代对慢首字节回
  // 502 时，平台层压根没接管音源——`processingState` 由 loading 落到 **idle**
  // 并永远停住，`setUrl` 的 Future 既不 resolve 也不 reject。batch44 的守卫据此
  // 无限期延后 0 秒卡死看门狗 → 播放永久冻结在 0 秒且无任何可见报错。
  //
  // batch46 —— 补上 `loading` 档漏洞（本轮）：media_kit 给 libmpv 传
  // `network-timeout=0`（无限等网络），反代慢/超时把连接搞坏时 libmpv **不报错**、
  // 只长期停在 `loading@0:00`（非 idle）。旧实现把 loading 整体当「合法长等待」
  // 沿用 30min 兜底 → 同样**永久卡死**（用户实测「歌单第一首卡在开始」）。故改
  // 两极上界：idle 档 10s / loading 档 30s（只看位置零前进，不看 duration）。
  //
  // 修法：按 processingState 判别——
  //   · `idle` + 播放意图 + 位置≈0 + duration=0：平台未接管 → 短上限(10s)。
  //   · `loading` + 播放意图 + 位置零前进：平台已接管但等不到数据 → 中上限(30s)。
  //     两档超界均**清在途标记**，让既有升级链（reload→判死→跳歌）接力自愈，
  //     不新增第二套恢复逻辑。其余情形走 30min 兜底安全网。
  group('抗断网延后:按 processingState 判别,idle 停滞必须自愈', () {
    test('idle 停滞超上界 → 看门狗不再 defer,最终跳过该曲(不再永久冻结)', () async {
      // loadGate 永不完成 → setUrl 永不返回；周期钉 idle@0 → 与实测日志同形。
      justAudio.player.loadGate = Completer<void>();
      container = buildContainer(justAudio.player);
      final notifier = container.read(playerProvider.notifier);
      // idle 停滞上限注入成极小值：省去真实等待（生产默认 10s）。
      notifier.debugStreamLoadIdleStuckCeilingMs = 2000;
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );
      await waitQuiet(notifier);

      unawaited(
        notifier.playSong(
          _song('s0'),
          queue: <Song>[_song('s0'), _song('s1')],
          index: 0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      justAudio.player.startIdlePin();
      // 时序：阈值 12 tick ≈ 6s 首次触发；此时 idle 停滞已 >2s 上界 →
      // 放行 reload(第 1 次)；再过 ≈6s 同曲连续达容错上限 → 判死跳下一首。
      // 轮询式等待（上限 30s）：真正要断言的是「最终会跳过该曲、不永久冻结」，
      // 而非某个墙钟余量。固定 13.5s 太紧（需同时覆盖 2s 判定上限 + 两轮
      // 各 ~6s reload），CI 争用时易抖；轮询到状态落定即返回，语义等价且
      // 不依赖墙钟。注意：2s/6s 等真实逻辑常量保持不变，仅改等待方式。
      final idleDeadline = DateTime.now().add(const Duration(seconds: 60));
      while (notifier.state.currentSong?.id != 's1' &&
          DateTime.now().isBefore(idleDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      justAudio.player.stopIdlePin();

      expect(
        notifier.state.currentSong?.id,
        's1',
        reason: 'idle 停滞超上界后必须自愈：reload → 连续 2 次判死 → 跳下一首；'
            '修复前会永远 defer（currentSong 恒为 s0）'
            '(loadLog=${justAudio.player.loadLog})',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('processing=loading 时仍保持 batch44 长等待(不误伤断网自愈)', () async {
      justAudio.player.loadGate = Completer<void>();
      container = buildContainer(justAudio.player);
      final notifier = container.read(playerProvider.notifier);
      // idle 上限注入成 1ms：若判别错误（把 loading 当 idle），7.6s 处必已 reload。
      notifier.debugStreamLoadIdleStuckCeilingMs = 1;
      await waitQuiet(notifier);

      unawaited(
        notifier.playSong(
          _song('s0'),
          queue: <Song>[_song('s0'), _song('s1')],
          index: 0,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // 让 platform 落到 loading（合法等服务端重试窗形态）。
      justAudio.player.emitLoadingAtStart();
      await Future<void>.delayed(const Duration(milliseconds: 7600));

      expect(
        justAudio.player.loadCount,
        1,
        reason: 'loading 属合法长等待，不得因 idle 上限而提前 reload/跳歌 '
            '(loadLog=${justAudio.player.loadLog})',
      );
      expect(
        notifier.state.currentSong?.id,
        's0',
        reason: '窗口内不得自动跳歌',
      );
    });

    test(
      'processing=loading 远超 idle 上界仍不误杀(reload 需 idle,两条件为 AND)',
      timeout: const Timeout(Duration(seconds: 90)),
      () async {
        // 注入极小 idle 上界(2s)；但让 platform 持续停在 loading 并钉住位置 0。
        // 若判别式把 loading 也算「未接管」(两条件为 OR)，2s 上界后必 reload；
        // 因判别式要求 processing==idle(AND)，loading 分支走**独立的 loading 档
        // 上界(30s)**，13s(<30s)后仍不得 reload、不得跳歌。
        justAudio.player.loadGate = Completer<void>();
        container = buildContainer(justAudio.player);
        final notifier = container.read(playerProvider.notifier);
        notifier.debugStreamLoadIdleStuckCeilingMs = 2000;
        notifier.state = notifier.state.copyWith(
          playbackMode: PlaybackMode.order,
          loopMode: LoopMode.off,
          shuffleEnabled: false,
        );
        await waitQuiet(notifier);

        unawaited(
          notifier.playSong(
            _song('s0'),
            queue: <Song>[_song('s0'), _song('s1')],
            index: 0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 持续钉 loading@0 —— 保证「atStart + playing」成立、看门狗本可触发，
        // 从而真正检验判别式，而不是靠位置漂移掩盖问题。
        justAudio.player.startLoadingPin();
        await Future<void>.delayed(const Duration(milliseconds: 13000));
        justAudio.player.stopLoadingPin();

        expect(
          justAudio.player.loadCount,
          1,
          reason: 'loading 有独立 loading 档(30s)：在途远超 idle 上界(2s)也不得 reload '
              '(13s < 30s) (loadLog=${justAudio.player.loadLog})',
        );
        expect(
          notifier.state.currentSong?.id,
          's0',
          reason: 'loading 形态下不得自动跳歌（判别式两条件为 AND）',
        );
      },
    );

    test(
      'loading 无进展超 loading 档上界 → 不再 defer,最终跳过该曲(救永久卡死)',
      timeout: const Timeout(Duration(seconds: 90)),
      () async {
        // batch46 漏洞复现：libmpv `network-timeout=0` 时平台长期停在 loading@0
        // 等数据（**非 idle**），旧实现按「loading = 合法长等待」沿用 30min 兜底
        // → 永久卡死（用户实测「歌单第一首卡在开始」）。修复后 loading 无进展有
        // 独立上界；此处注入 2s 省去真实 30s 等待。
        justAudio.player.loadGate = Completer<void>();
        container = buildContainer(justAudio.player);
        final notifier = container.read(playerProvider.notifier);
        notifier.debugStreamLoadNoProgressCeilingMs = 2000;
        notifier.state = notifier.state.copyWith(
          playbackMode: PlaybackMode.order,
          loopMode: LoopMode.off,
          shuffleEnabled: false,
        );
        await waitQuiet(notifier);

        unawaited(
          notifier.playSong(
            _song('s0'),
            queue: <Song>[_song('s0'), _song('s1')],
            index: 0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 与第 6 条一致：持续钉 loading@0，保证「atStart + playing」成立、
        // 看门狗本可触发（否则无法真正检验 loading 档）。
        justAudio.player.startLoadingPin();
        // 时序：阈值 12 tick ≈ 6s 首次触发；此时 loading 无进展已 >2s 上界 →
        // 放行 reload(第 1 次)；再过 ≈6s 同曲连续达容错上限 → 判死跳下一首。
        // 轮询到状态落定即返回（上限 60s），不依赖墙钟（与 idle 用例同风格）。
        final loadingDeadline = DateTime.now().add(const Duration(seconds: 60));
        while (notifier.state.currentSong?.id != 's1' &&
            DateTime.now().isBefore(loadingDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        justAudio.player.stopLoadingPin();

        expect(
          notifier.state.currentSong?.id,
          's1',
          reason: 'loading 无进展超上界后必须自愈：reload → 连续 2 次判死 → 跳下一首；'
              '修复前会永远 defer（currentSong 恒为 s0，永久卡死）'
              '(loadLog=${justAudio.player.loadLog})',
        );
      },
    );

    test(
      'loading 无进展且 duration 非 0(libmpv 一打开就带时长)仍触发恢复',
      timeout: const Timeout(Duration(seconds: 90)),
      () async {
        // 防回归钉子：若把 `duration == 0` 当作 loading 档的必要条件，libmpv/flac
        // 一打开 duration 就非 0 → 看门狗被解除 → 又退回永久卡死。本用例把 duration
        // 钉成 320s、位置钉 0、processing 钉 loading，断言仍必须自愈。
        justAudio.player.loadGate = Completer<void>();
        container = buildContainer(justAudio.player);
        final notifier = container.read(playerProvider.notifier);
        notifier.debugStreamLoadNoProgressCeilingMs = 2000;
        notifier.state = notifier.state.copyWith(
          playbackMode: PlaybackMode.order,
          loopMode: LoopMode.off,
          shuffleEnabled: false,
        );
        await waitQuiet(notifier);

        unawaited(
          notifier.playSong(
            _song('s0'),
            queue: <Song>[_song('s0'), _song('s1')],
            index: 0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 钉 loading@0 且 duration=320s（复现 libmpv 一打开就已知总时长的真实情形）。
        justAudio.player.startLoadingPin(
          duration: const Duration(seconds: 320),
        );
        final durationDeadline = DateTime.now().add(const Duration(seconds: 60));
        while (notifier.state.currentSong?.id != 's1' &&
            DateTime.now().isBefore(durationDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        justAudio.player.stopLoadingPin();

        expect(
          notifier.state.currentSong?.id,
          's1',
          reason: 'duration 非 0 不得解除 loading 档看门狗：仍须 reload → 判死 → 跳下一首 '
              '(loadLog=${justAudio.player.loadLog})',
        );
      },
    );
  });
}
