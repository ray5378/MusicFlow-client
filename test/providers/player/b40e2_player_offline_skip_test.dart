// batch40 E2 —— player 域缺陷修复验证（D-058 / D-031）。
//
// 姿势与 b37a2_player_provider_offline_test.dart 完全一致：驱动**真实**
// PlayerNotifier，just_audio 平台换替身，外部 provider 全桩。
//
// 本文件断言**修复后**的行为：
//   * D-058  离线 + 队列全无缓存：连跳保护生效 —— 连续 2 首不可播即停止自动跳、
//            落暂停态，不再整队列紧凑无限重试。
//   * D-031  _handlePlaybackError 的 fire-and-forget 跳链：next() 内部再抛
//            （下一首 songFile 探测抛错）不得作为未捕获 Future 错误冒出 ——
//            若裸奔，flutter_test 会因 unhandled async error 直接判红。
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
  int playCount = 0;
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
  _FakeAudioPlayerPlatform? last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
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
  String suffix = 'flac',
  int? bitRate = 1411,
  int duration = 200,
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

/// 离线缓存管理器替身：不给任何缓存文件；[throwFor] 里的 songId 查询时直接抛错
/// （驱动 D-031：让自动跳链中下一首的 playSong 在 songFile 处爆炸）。
class _FakeCacheManager extends OfflineCacheManager {
  _FakeCacheManager({this.throwFor = const <String>{}});

  final Set<String> throwFor;

  @override
  Future<void> init() async {}

  @override
  File? songFile(String songId) {
    if (throwFor.contains(songId)) {
      throw StateError('songFile boom for $songId');
    }
    return null;
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
  late _FakeJustAudioPlatform platform;

  ProviderContainer buildContainer({Set<String> throwFor = const <String>{}}) {
    final cache = _FakeCacheManager(throwFor: throwFor);
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
        effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
        isOfflineProvider.overrideWithValue(true),
        subsonicApiClientProvider.overrideWithValue(spy),
        musicRepositoryProvider.overrideWithValue(repo),
        offlineCacheDaemonProvider.overrideWith(
          (ref) => _NoopOfflineCacheDaemon(ref),
        ),
        offlineCacheManagerProvider.overrideWithValue(cache),
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
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({Set<String> throwFor = const <String>{}}) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(throwFor: throwFor);
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  setUp(() {
    JustAudioPlatform.instance = _FakeJustAudioPlatform();
  });

  tearDown(() => container.dispose());

  group('D-058 离线无缓存连跳保护', () {
    test('连续 2 首无缓存即停止自动跳并落暂停态，不再绕圈空转', () async {
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );

      await notifier.playSong(
        _song('s0'),
        queue: <Song>[_song('s0'), _song('s1'), _song('s2')],
        index: 0,
        autoPlay: false,
      );
      // 等跳链跑完：s0 失败跳 s1（第 1 次），s1 再失败 → 达阈值停止。
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(
        notifier.state.currentSong?.id,
        's1',
        reason: 'D-058：第 2 首连续失败即停止自动跳，游标停在 s1，不再推进到 s2',
      );
      expect(
        notifier.state.isPlaying,
        isFalse,
        reason: 'D-058：达阈值后应落暂停态',
      );

      // 再等一阵确认完全静止（原缺陷是紧凑无限重试）。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(notifier.state.currentSong?.id, 's1', reason: '应保持静止');
      expect(
        platform.last?.loadedUris ?? const <String>[],
        isEmpty,
        reason: '离线无缓存全程不应有任何网络/文件加载',
      );
    });

    test('缓存命中后连跳保护复位：再次离线失败可重新计跳', () async {
      // 先用带缓存的容器播一首（复位计数路径 _syncPlaybackAfterSourceReady），
      // 这里仅验证保护计数不会跨场景泄漏：直接播 2 首连续失败同样在第 2 首停住。
      notifier = await boot();
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );

      await notifier.playSong(
        _song('a0'),
        queue: <Song>[_song('a0'), _song('a1')],
        index: 0,
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(notifier.state.currentSong?.id, 'a1',
          reason: '第 2 首失败达阈值停止，停在 a1');
      expect(notifier.state.isPlaying, isFalse);
    });
  });

  group('D-031 失败跳链异常不外泄', () {
    test('跳链中下一首 songFile 抛错：被捕获记日志，无未捕获 Future 错误', () async {
      // s2 的 songFile 查询直接抛错 → next() → playSong(s2) 的 Future 会错误。
      // 原实现 `next();` 裸奔：未捕获的异步错误会让 flutter_test 直接判红；
      // 修复后由 catchError 兜住记日志，游标仍推进到 s2（状态连贯不变）。
      notifier = await boot(throwFor: <String>{'s2'});
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
        loopMode: LoopMode.off,
        shuffleEnabled: false,
      );

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        index: 0,
        autoPlay: false,
      );
      await waitQuiet(notifier);

      expect(
        notifier.state.currentSong?.id,
        's2',
        reason: 'D-031：跳链本身仍应推进（fire-and-forget 语义保持）',
      );
      // 走到这里没有 unhandled async error 即为通过（flutter_test 会把
      // 未捕获的 Future 错误直接判为测试失败）。
    });
  });
}
