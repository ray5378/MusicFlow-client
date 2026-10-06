// b34a：lib/providers/player/player_shuffle_queue.dart（LF:130 / LH:100，30 miss）
// 未覆盖分支攻坚：
//   * _getQueuePreviousIndex 边界（队列空/单元素/越界回绕，112-113）
//   * _refreshServerShuffleSeq：pid 空、resp 非 Map、epoch 变更、正常拉取（226-250）
//   * _pickServerShuffleNext：沿序列推进 / 位置失配重定位 / 序列耗尽 reshuffle
//     / 拿不到序列回退本地随机（254-282）
//   * _syncShuffleHistoryBeforeSongChange：非随机重置、换队列重置、
//     recordHistory/clearForwardHistory（35-77）
//   * next() shuffle 前向历史导航（2036-2055）、previous() 历史栈（1982-1988）
//   * _resolveUpcomingSongForCache 顺序模式队尾回绕取队首（177）
//
// 驱动方式与 b29a 系列一致：真实 _PlayerNotifierImpl + 替身平台 + 替身 cast
// 控制器（localPeerId 可控），服务端洗牌序列由 _SpySubsonicApiClient 的
// getRaw/postRaw 桩返回。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

// ───────────────────────────── just_audio 替身 ───────────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  int loadCount = 0;
  final List<String> loadedUris = <String>[];

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      const Stream<PlayerDataMessage>.empty();

  void emit() {
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration(seconds: 10),
        bufferedPosition: Duration(seconds: 10),
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
    if (message is UriAudioSourceMessage) loadedUris.add(message.uri);
    scheduleMicrotask(emit);
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

// ───────────────────────────── 其它桩 ─────────────────────────────────────

Song _song(String id) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'mp3',
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

  /// /queue/shuffle 的桩返回值；null = 抛错。
  Object? shuffleResp = <String, dynamic>{};
  Object? reshuffleResp = <String, dynamic>{};
  int shuffleGets = 0;
  int reshufflePosts = 0;

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
  }) async {
    if (path.contains('/queue/shuffle')) {
      shuffleGets += 1;
      final resp = shuffleResp;
      if (resp == null) throw StateError('b34a shuffle get fail');
      return resp;
    }
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    if (path.contains('/queue/reshuffle')) {
      reshufflePosts += 1;
      final resp = reshuffleResp;
      if (resp == null) throw StateError('b34a reshuffle fail');
      return resp;
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

class _NoopOfflineCacheDaemon extends OfflineCacheDaemon {
  _NoopOfflineCacheDaemon(super.ref);

  Song? lastUpcoming;
  int calls = 0;

  @override
  Future<void> onSongStartedOnline({
    required Song song,
    required List<Song> queue,
    required int index,
    Song? upcomingSong,
  }) async {
    calls += 1;
    lastUpcoming = upcomingSong;
  }
}

class _CastPeerControllerWithPeer extends CastPeerController {
  _CastPeerControllerWithPeer(super.ref, this.peerId);

  final String? peerId;

  @override
  String? get localPeerId => peerId;
}

// ───────────────────────────────── 装配 ─────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  // just_audio play() 内部走 audio_session.setActive —— 测试环境无插件会抛错
  // 触发自动跳歌，mock 掉通道让 play() 正常走完。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (MethodCall call) async => null,
  );
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();
  final spy = _SpySubsonicApiClient();
  _NoopOfflineCacheDaemon? daemonInstance;
  late _FakeJustAudioPlatform platform;

  ProviderContainer buildContainer({String? localPeerId}) =>
      ProviderContainer(
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
            (ref) {
              daemonInstance = _NoopOfflineCacheDaemon(ref);
              return daemonInstance!;
            },
          ),
          castPeerControllerProvider.overrideWith(
            (ref) => _CastPeerControllerWithPeer(ref, localPeerId),
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

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({String? localPeerId}) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(localPeerId: localPeerId);
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  /// 把 notifier 摆进「随机模式 + 三歌队列、当前为第 0 首」的起手态。
  void seedShuffleState(List<Song> queue, {int currentIndex = 0}) {
    notifier.state = notifier.state.copyWith(
      queue: queue,
      currentSong: queue[currentIndex],
      currentIndex: currentIndex,
      playbackMode: PlaybackMode.shuffle,
      shuffleEnabled: true,
    );
  }

  setUp(() {
    spy.shuffleResp = <String, dynamic>{};
    spy.reshuffleResp = <String, dynamic>{};
    spy.shuffleGets = 0;
    spy.reshufflePosts = 0;
  });

  tearDown(() => container.dispose());

  // ────────────── 一、服务端权威洗牌序列（254-282） ──────────────
  group('服务端洗牌序列', () {
    test('沿序列推进：order=[0,2,1] pos 对齐当前 → next 播队列第 2 首', () async {
      notifier = await boot(localPeerId: 'peer-1');
      seedShuffleState(<Song>[_song('s1'), _song('s2'), _song('s3')]);
      spy.shuffleResp = <String, dynamic>{
        'shuffleOrder': <int>[0, 2, 1],
        'shuffleEpoch': 1,
        'shufflePos': 0, // order[0] == currentIndex(0)
      };

      await notifier.next();

      // （shuffleGets 不做精确计数：playSong 的 _probeUpcoming 在 shuffle 下
      // 也会拉一次服务端序列，见 player_playback_helpers.dart:198。）
      expect(notifier.state.currentSong?.id, 's3');
      expect(notifier.state.currentIndex, 2);
    });

    test('缓存位置与当前曲不符 → 重定位（indexOf）后再推进', () async {
      notifier = await boot(localPeerId: 'peer-1');
      seedShuffleState(<Song>[_song('s1'), _song('s2'), _song('s3')]);
      // order[0]==0 ≠ currentIndex(2) → 重定位到 order.indexOf(2)=1。
      spy.shuffleResp = <String, dynamic>{
        'shuffleOrder': <int>[0, 2, 1],
        'shuffleEpoch': 5,
        'shufflePos': 0,
      };
      notifier.state = notifier.state.copyWith(currentIndex: 2);

      await notifier.next();

      expect(notifier.state.currentSong?.id, 's2');
      expect(notifier.state.currentIndex, 1);
    });

    test('序列耗尽 → reshuffle 接力（新序列第 0 个可用位）', () async {
      notifier = await boot(localPeerId: 'peer-1');
      seedShuffleState(<Song>[_song('s1'), _song('s2')]);
      // 首次拉取：单元素序列、pos 0 指向当前 → advance 耗尽 → 触发 reshuffle。
      spy.shuffleResp = <String, dynamic>{
        'shuffleOrder': <int>[0],
        'shuffleEpoch': 1,
        'shufflePos': 0,
      };
      spy.reshuffleResp = <String, dynamic>{
        'shuffleOrder': <int>[1],
        'shuffleEpoch': 2,
      };

      await notifier.next();

      expect(spy.reshufflePosts, 1);
      expect(notifier.state.currentSong?.id, 's2');
      expect(notifier.state.currentIndex, 1);
    });

    test('shuffle 接口返回非 Map → 回退本地随机，仍能切歌', () async {
      notifier = await boot(localPeerId: 'peer-1');
      seedShuffleState(<Song>[_song('s1'), _song('s2'), _song('s3')]);
      spy.shuffleResp = <int>[1, 2, 0]; // 非 Map → false

      await notifier.next();

      expect(
        notifier.state.currentSong?.id,
        isNot('s1'),
      );
    });

    test('getRaw 抛错（离线）→ 清缓存回退本地随机', () async {
      notifier = await boot(localPeerId: 'peer-1');
      seedShuffleState(<Song>[_song('s1'), _song('s2'), _song('s3')]);
      spy.shuffleResp = null;

      await notifier.next();

      expect(notifier.state.currentSong?.id, isNot('s1'));
    });

    test('localPeerId 为空（未注册）→ 不发请求，直接本地随机', () async {
      notifier = await boot(localPeerId: null);
      seedShuffleState(<Song>[_song('s1'), _song('s2'), _song('s3')]);

      await notifier.next();

      expect(spy.shuffleGets, 0);
      expect(notifier.state.currentSong?.id, isNot('s1'));
    });
  });

  // ────────────── 二、shuffle 历史栈（1982-1988、2036-2055） ──────────────
  group('随机历史栈导航', () {
    test('previous 沿回退历史返回并压前向栈 → next 沿前向历史精确返回', () async {
      notifier = await boot(localPeerId: null);
      seedShuffleState(<Song>[_song('s1'), _song('s2'), _song('s3')],
          currentIndex: 0);

      // 先用 playSong(recordHistory) 建回退历史：back = [s1, s2]，当前 s3。
      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        index: 1,
        recordShuffleHistory: true,
        clearShuffleForwardHistory: true,
        autoPlay: false,
      );
      await notifier.playSong(
        _song('s3'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        index: 2,
        recordShuffleHistory: true,
        clearShuffleForwardHistory: true,
        autoPlay: false,
      );
      expect(notifier.state.currentSong?.id, 's3');
      expect(notifier.state.shuffleHistoryCount, 2);

      // previous：回退历史命中 idx1 → 当前 s3 压前向栈（1982-1988）。
      await notifier.previous();
      expect(notifier.state.currentSong?.id, 's2');
      expect(notifier.state.currentIndex, 1);

      // next：前向历史命中 idx2 → 精确回到 s3（2036-2055）。
      await notifier.next();
      expect(notifier.state.currentSong?.id, 's3');
      expect(notifier.state.currentIndex, 2);
      expect(notifier.state.shuffleHistoryCount, greaterThanOrEqualTo(2));
    });

    test('顺序模式 previous：currentIndex==0 回绕到队尾（_getQueuePreviousIndex 边界）',
        () async {
      notifier = await boot(localPeerId: null);
      notifier.state = notifier.state.copyWith(
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        currentSong: _song('s1'),
        currentIndex: 0,
        playbackMode: PlaybackMode.all,
        shuffleEnabled: false,
      );

      await notifier.previous();

      expect(notifier.state.currentSong?.id, 's3');
      expect(notifier.state.currentIndex, 2);
    });
  });

  // ────────────── 三、playSong 的历史同步（35-77） ──────────────
  group('_syncShuffleHistoryBeforeSongChange', () {
    test('随机模式同队列 + recordHistory/clearForward → pushBack + 清前向',
        () async {
      notifier = await boot(localPeerId: null);
      seedShuffleState(<Song>[_song('s1'), _song('s2'), _song('s3')]);

      // 记录历史并清前向：切到 s2。
      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        index: 1,
        recordShuffleHistory: true,
        clearShuffleForwardHistory: true,
        autoPlay: false,
      );
      expect(notifier.state.currentSong?.id, 's2');
      // pushBack 了 s1 → 回退历史 ≥1；前向历史被清空。
      expect(notifier.state.shuffleHistoryCount, 1);

      // 再切回 s1（同队列 + recordHistory）→ 回退历史继续增长。
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
        index: 0,
        recordShuffleHistory: true,
        clearShuffleForwardHistory: true,
        autoPlay: false,
      );
      expect(notifier.state.shuffleHistoryCount, 2);
    });

    test('非随机模式 → 历史重置（shuffleHistoryCount 归零）', () async {
      notifier = await boot(localPeerId: null);
      seedShuffleState(<Song>[_song('s1'), _song('s2')]);
      // 先在随机模式下攒一条历史。
      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s1'), _song('s2')],
        index: 1,
        recordShuffleHistory: true,
        clearShuffleForwardHistory: true,
        autoPlay: false,
      );
      expect(notifier.state.shuffleHistoryCount, 1);

      // 切回非随机模式 → 换歌时历史重置（35-39 非随机分支）。
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.all,
        shuffleEnabled: false,
      );
      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        index: 0,
        autoPlay: false,
      );
      expect(notifier.state.shuffleHistoryCount, 0);
    });

    test('换队列（不同歌单）→ 历史重置；_getQueuePreviousIndex 单元素队列返回 0',
        () async {
      notifier = await boot(localPeerId: null);
      seedShuffleState(<Song>[_song('s1'), _song('s2')]);
      await notifier.playSong(
        _song('s2'),
        queue: <Song>[_song('s1'), _song('s2')],
        index: 1,
        recordShuffleHistory: true,
        clearShuffleForwardHistory: true,
        autoPlay: false,
      );
      expect(notifier.state.shuffleHistoryCount, 1);

      // 换成完全不同的队列 → 随机模式下的换队列重置分支。
      await notifier.playSong(
        _song('x1'),
        queue: <Song>[_song('x1')],
        index: 0,
        autoPlay: false,
      );
      expect(notifier.state.shuffleHistoryCount, 0);
      expect(notifier.state.queue.length, 1);
    });
  });

  // ────────────── 四、预缓存候选（_resolveUpcomingSongForCache 177） ──────────────
  test('顺序模式队列尾 → 预缓存候选回绕取队首', () async {
    notifier = await boot(localPeerId: null);
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.all,
      shuffleEnabled: false,
    );
    await notifier.playSong(
      _song('s3'),
      queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
      index: 2,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(daemonInstance, isNotNull);
    expect(daemonInstance!.calls, greaterThanOrEqualTo(1));
    expect(daemonInstance!.lastUpcoming?.id, 's1');
  });
}
