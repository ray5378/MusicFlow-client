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
  _FakeCastPeerController(super.ref);
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
}
