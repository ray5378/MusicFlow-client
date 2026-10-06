// b38a2 —— Route A 播放核心补测：**player_provider 的几条可达公共路径**。
//
// 专啃 lcov 中仍 0 命中、且**能经公开 API 稳定打进去**的分支：
//   * 离线缓存命中 + autoPlay → 起播后上报 scrobble（player_provider 1042/1043）；
//   * refreshSongMetadata 把完整元数据同时写回 currentSong 与队列项（2696）；
//   * 试听曲缺 bitRate 时从 previewQualityLabel 解析码率
//     （player_stream_source 56，经 _playPreviewSongInternal 的第 1740 行调用点）。
//
// 姿势与 b38a 一致：驱动**真实** `_PlayerNotifierImpl`，just_audio 平台换替身，
// 外部 provider（地址池/仓库/离线守护/投屏控制器）全桩。所有断言都打在可观测
// 状态或桩件记录上，不使用恒真断言。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:musicflow_client/data/sources/json_file_store.dart';
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
    if (throwOnLoad) throw StateError('load boom');
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
  bool throwOnLoad = false;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = _FakeAudioPlayerPlatform(request.id)
      ..throwOnLoad = throwOnLoad;
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
  String? title,
  String suffix = 'flac',
  int? bitRate = 1411,
  int? duration = 200,
  String? coverArt,
  bool isPreview = false,
  String? previewQualityLabel,
  String? previewStreamUrl,
}) =>
    Song(
      id: id,
      title: title ?? '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: suffix,
      bitRate: bitRate,
      duration: duration,
      starred: false,
      coverArt: coverArt,
      isPreview: isPreview,
      previewQualityLabel: previewQualityLabel,
      previewStreamUrl: previewStreamUrl,
    );

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  Song? getSongResult;
  bool throwOnGetSong = false;
  int getSongCalls = 0;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async {
    getSongCalls += 1;
    if (throwOnGetSong) throw StateError('getSong boom');
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

class _FakeCacheManager extends OfflineCacheManager {
  _FakeCacheManager(this.file);

  final File? file;

  @override
  Future<void> init() async {}

  @override
  File? songFile(String songId) => file;
}

class _SpySubsonicApiClient extends SubsonicApiClient {
  _SpySubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  String streamUrl = 'http://192.168.10.240:46400/rest/stream?id=s1';

  /// 记录所有被调过的 REST 路径（`/rest/scrobble` 等）。
  final List<String> paths = <String>[];

  /// 记录 get() 的 query（用于确认 scrobble 带的是当前曲 id）。
  final List<Map<String, dynamic>?> queries = <Map<String, dynamic>?>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    paths.add(path);
    queries.add(queryParameters);
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    Duration? receiveTimeout,
  }) async {
    paths.add(path);
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
    paths.add(path);
    return <String, dynamic>{};
  }
}

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);

  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async => null;

  @override
  Future<void> syncLocalQueueNow() async {}
}

// ─────────────────────────── 用例 ───────────────────────────

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
  late Directory dir;
  ProviderContainer? container;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('b38a2_pp_');
    JsonFileStore.instance.debugDirectory = dir;
    repo.getSongResult = null;
    repo.throwOnGetSong = false;
    repo.getSongCalls = 0;
    spy.paths.clear();
    spy.queries.clear();
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
  });

  tearDown(() {
    container?.dispose();
    container = null;
    JsonFileStore.instance.debugDirectory = null;
  });

  ProviderContainer buildContainer({
    required bool offline,
    AudioQualityLevel quality = AudioQualityLevel.original,
    File? cache,
  }) =>
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
          effectiveQualityProvider.overrideWithValue(quality),
          isOfflineProvider.overrideWithValue(offline),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          offlineCacheManagerProvider.overrideWithValue(
            _FakeCacheManager(cache),
          ),
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

  Future<PlayerNotifier> boot({
    bool offline = false,
    AudioQualityLevel quality = AudioQualityLevel.original,
    File? cache,
  }) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container =
        buildContainer(offline: offline, quality: quality, cache: cache);
    final n = container!.read(playerProvider.notifier);
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 6 && !n.debugIsRestoringPlaybackSession) break;
    }
    return n;
  }

  Future<void> waitUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  group('A. 离线缓存起播', () {
    test('离线 + 命中缓存 + autoPlay → 起播后上报 scrobble（1042/1043）',
        () async {
      final cache = File('${dir.path}${Platform.pathSeparator}s1.flac');
      await cache.writeAsBytes(<int>[1, 2, 3, 4]);

      final n = await boot(offline: true, cache: cache);
      await n.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        index: 0,
        autoPlay: true,
      );

      await waitUntil(
        () => spy.paths.any((String p) => p.contains('scrobble')),
      );
      expect(
        spy.paths.where((String p) => p.contains('scrobble')),
        isNotEmpty,
        reason: '离线缓存起播也必须上报播放记录（submission=false）',
      );
      final scrobbleIndex =
          spy.paths.indexWhere((String p) => p.contains('scrobble'));
      expect(spy.queries[scrobbleIndex]?['id'], 's1');
      expect(spy.queries[scrobbleIndex]?['submission'], 'false');
      expect(n.state.currentSong?.id, 's1');
    });

    test('离线 + 命中缓存 + 不自动播放 → 不上报 scrobble', () async {
      final cache = File('${dir.path}${Platform.pathSeparator}s1.flac');
      await cache.writeAsBytes(<int>[1, 2, 3, 4]);

      final n = await boot(offline: true, cache: cache);
      await n.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        index: 0,
        autoPlay: false,
      );
      await waitUntil(() => n.state.currentSong?.id == 's1');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        spy.paths.where((String p) => p.contains('scrobble')),
        isEmpty,
        reason: '未真正起播不能写播放记录',
      );
    });
  });

  group('B. refreshSongMetadata（2696）', () {
    test('当前曲即在队列内 → currentSong 与队列项一起换成完整元数据', () async {
      final n = await boot();
      final a = _song('a');
      final b = _song('b');
      n.state = n.state.copyWith(
        currentSong: a,
        queue: <Song>[a, b],
        currentIndex: 0,
      );
      repo.getSongResult = _song('a', title: '完整标题', bitRate: 320);

      await n.refreshSongMetadata('a');

      expect(n.state.currentSong?.title, '完整标题');
      expect(n.state.currentSong?.bitRate, 320);
      expect(n.state.queue[0].title, '完整标题',
          reason: '队列项必须同步刷新，否则切歌后又变回残缺元数据');
      expect(n.state.queue[1].title, '曲b', reason: '无关队列项不该被动到');
      expect(n.state.queue.length, 2);
    });

    test('歌不在队列、只匹配 currentSong → 只换 currentSong，队列原样', () async {
      final n = await boot();
      final a = _song('a');
      final b = _song('b');
      n.state = n.state.copyWith(
        currentSong: a,
        queue: <Song>[b],
        currentIndex: 0,
      );
      repo.getSongResult = _song('a', title: '完整标题');

      await n.refreshSongMetadata('a');

      expect(n.state.currentSong?.title, '完整标题');
      expect(n.state.queue.length, 1);
      expect(n.state.queue[0].id, 'b');
    });

    test('空 songId 直接返回，不查服务端', () async {
      final n = await boot();
      await n.refreshSongMetadata('   ');
      expect(repo.getSongCalls, 0);
    });
  });

  group('C. 试听曲码率解析（player_stream_source 56）', () {
    test('试听曲无 bitRate → 从 previewQualityLabel 解析出 kbps', () async {
      final n = await boot();
      final preview = _song(
        'p1',
        title: '试听曲',
        suffix: 'mp3',
        bitRate: null,
        isPreview: true,
        previewQualityLabel: '320 kbps',
        previewStreamUrl: 'https://music.example.test/preview/p1.mp3',
      );
      await n.playSong(
        preview,
        queue: <Song>[preview],
        index: 0,
        autoPlay: false,
      );

      await waitUntil(() => n.state.currentBitRateKbps == 320);
      expect(n.state.currentBitRateKbps, 320,
          reason: '试听曲没有 bitRate 字段，必须从品质标签里解析出来');
    });

    test('试听曲有 bitRate → 直接用 songBitRate，不解析文本', () async {
      final n = await boot();
      final preview = _song(
        'p2',
        title: '试听曲2',
        suffix: 'mp3',
        bitRate: 128,
        isPreview: true,
        previewQualityLabel: '320 kbps',
        previewStreamUrl: 'https://music.example.test/preview/p2.mp3',
      );
      await n.playSong(
        preview,
        queue: <Song>[preview],
        index: 0,
        autoPlay: false,
      );

      await waitUntil(() => n.state.currentSong?.id == 'p2');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(n.state.currentBitRateKbps, 128);
    });
  });
}
