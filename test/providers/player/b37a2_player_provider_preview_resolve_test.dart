// b37a2：`lib/providers/player/player_provider.dart` 的**试听解析**分支
// （`_resolvePreviewSongForPlayback` 1794-1812）与 `player_stream_source.dart`
// 的**地址兜底**分支（`_ensureActiveAddressForPlayback` 137-145），
// 外加 `_resolveCurrentBitRateKbps` 的试听/离线码率折算（67-76）。
//
// 为什么这批能打到、前面各批打不到：
//   * 既有 `player_provider_preview_transcode_cov_test.dart` 走的试听入口全部带
//     `previewStreamUrl`（踩坑 #180-D：非空且未在恢复中就**直接复用原 song**），
//     于是 `1785` 往下的「真去 gd 客户端解析」那段一次都没跑过。本批反过来：
//     造**无 URL、有 source/trackId** 的试听曲，并 override `gdMusicApiClientProvider`
//     成内存替身 —— 解析主线（1794-1812）就被点亮了。
//   * `_ensureActiveAddressForPlayback` 的兜底段要求 `_syncImmediateActiveAddress`
//     返回 null（即 `pool.activeAddress` 与 `activeAddressProvider` **同时为空**）。
//     既有各批的台子都摆了地址，所以永远走不到 `ensureActiveAddressProvider.future`
//     那条线。本批把两处都摆成 null，再 override ensure provider 给一个**不同 baseUrl**
//     的地址，把 139-141 的切库与 143-145 的日志一并覆盖。
//
// 不碰 lib/ 一行；不引入 mocktail；just_audio 平台替身姿势沿用 batch28 的那套。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/remote/gd_music_api_client.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/gd_music_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
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
  final List<Map<String, String>?> loadedHeaders = <Map<String, String>?>[];

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void emit(ProcessingStateMessage state) {
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: loadCount * 997 + 1),
        bufferedPosition: Duration(milliseconds: loadCount * 997 + 1),
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
      loadedHeaders.add(message.headers);
    }
    // 不吐 ready，`setUrl()` 会永久挂在等 processingState 离开 loading。
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

// ───────────────────────────── 其它桩 ─────────────────────────────

/// 固定吐一个合法流地址的 Subsonic 客户端替身（不依赖登录态）。
class _ScriptedSubsonicApiClient extends SubsonicApiClient {
  _ScriptedSubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'http://192.168.10.240:46400')));

  final List<String> streamUrlCalls = <String>[];
  String streamUrl = 'http://192.168.10.240:46400/rest/stream?id=s1';

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
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
    streamUrlCalls.add('$songId|format=$format|maxBitRate=$maxBitRate');
    return streamUrl;
  }
}

/// 地址池替身：`activeAddress` 可控（默认 null ⇒ 走 ensure 兜底）。
class _FakeAddressPool extends AddressPool {
  _FakeAddressPool()
      : super(Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')));

  ServerAddress? immediate;

  @override
  ServerAddress? get activeAddress => immediate;

  @override
  Future<ServerAddress?> probeAll() async => immediate;
}

/// 试听 URL 解析替身（`_resolvePreviewSongForPlayback` 1794-1812 的唯一外部依赖）。
class _FakeGdMusicApiClient extends GdMusicApiClient {
  _FakeGdMusicApiClient();

  int resolveSongUrlCalls = 0;
  int resolveCoverUrlCalls = 0;

  String resultUrl = 'https://cdn.example.test/resolved/p1.flac';
  int? resultBitRateKbps = 320;
  String? resultSuffix = 'flac';
  Map<String, String> resultHeaders = const <String, String>{
    'Referer': 'https://x.example.test',
  };
  String? coverUrl = 'https://cdn.example.test/cover/p1.jpg';

  @override
  Future<GdSongUrlResult> resolveSongUrl({
    required String source,
    required String trackId,
    int? br,
  }) async {
    resolveSongUrlCalls += 1;
    return GdSongUrlResult(
      url: resultUrl,
      bitRateKbps: resultBitRateKbps,
      suffix: resultSuffix,
      requiredHeaders: resultHeaders,
    );
  }

  @override
  Future<String?> resolveCoverUrl({
    required String source,
    required String picId,
    List<int> preferredSizes = const <int>[500, 300],
  }) async {
    resolveCoverUrlCalls += 1;
    return coverUrl;
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

Song _song(String id) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'flac',
      bitRate: 1411,
      duration: 200,
    );

/// 造一首**试听曲**（默认无既有 URL，逼着走 gd 解析主线）。
Song _preview(
  String id, {
  String? streamUrl,
  String? source = 'netease',
  String? trackId = 't1',
  String? picId,
  int? bitRate,
  String? coverUrl,
}) =>
    Song(
      id: id,
      title: '试听$id',
      artist: '试听歌手',
      albumId: 'al1',
      suffix: 'm4a',
      bitRate: bitRate,
      duration: 30,
      isPreview: true,
      previewStreamUrl: streamUrl,
      previewSource: source,
      previewTrackId: trackId,
      previewPicId: picId,
      previewCoverUrl: coverUrl,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (MethodCall call) async => null,
  );
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();
  final spy = _ScriptedSubsonicApiClient();
  final pool = _FakeAddressPool();
  final gd = _FakeGdMusicApiClient();
  late _FakeJustAudioPlatform platform;

  // ignore: no_leading_underscores_for_local_identifiers
  ServerAddress _addr(String url) => ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: url,
        priority: 0,
      );

  // ignore: no_leading_underscores_for_local_identifiers
  MusicLibrary _library() => MusicLibrary(
        id: 'lib1',
        name: '主库',
        serverType: 'MusicFlow',
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  ProviderContainer buildContainer({
    ServerAddress? immediateAddress,
    ServerAddress? ensureAddress,
    AudioQualityLevel quality = AudioQualityLevel.original,
  }) =>
      ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library()),
          activeAddressProvider.overrideWith(
            (ref) => immediateAddress,
          ),
          effectiveQualityProvider.overrideWithValue(quality),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          addressPoolProvider.overrideWithValue(pool),
          gdMusicApiClientProvider.overrideWithValue(gd),
          ensureActiveAddressProvider.overrideWith(
            (ref) async =>
                ensureAddress ?? _addr('http://192.168.10.240:46400'),
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

  Future<void> waitLoaded([int count = 1]) async {
    for (var i = 0; i < 250; i++) {
      if ((platform.last?.loadCount ?? 0) >= count) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({
    ServerAddress? immediateAddress,
    ServerAddress? ensureAddress,
    AudioQualityLevel quality = AudioQualityLevel.original,
  }) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(
      immediateAddress: immediateAddress,
      ensureAddress: ensureAddress,
      quality: quality,
    );
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  setUp(() {
    spy.streamUrlCalls.clear();
    spy.streamUrl = 'http://192.168.10.240:46400/rest/stream?id=s1';
    pool.immediate = null;
    gd.resolveSongUrlCalls = 0;
    gd.resolveCoverUrlCalls = 0;
    gd.resultUrl = 'https://cdn.example.test/resolved/p1.flac';
    gd.resultBitRateKbps = 320;
    gd.resultSuffix = 'flac';
    gd.resultHeaders = const <String, String>{
      'Referer': 'https://x.example.test',
    };
    gd.coverUrl = 'https://cdn.example.test/cover/p1.jpg';
  });

  // ⚠️ 恢复流程的尾巴是 fire-and-forget，立刻 dispose 会把 `after dispose` 抛给
  // 下一条用例；留一点时间再收（同 batch28 #179-D）。
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    container.dispose();
  });

  // ─────────── 一、`_resolvePreviewSongForPlayback` 的 gd 解析主线 ───────────
  group('试听解析主线（1785-1813）', () {
    test('无既有 URL + 有 source/trackId → 走 gd 解析，回填 URL/封面/码率/后缀', () async {
      // 默认台子摆了地址（走即时地址，不碰 ensure 兜底），把注意力全放在解析上。
      notifier = await boot(
        immediateAddress: _addr('http://192.168.10.240:46400'),
      );
      final song = _preview('p1', picId: 'pic1');

      await notifier.playSong(song, queue: <Song>[song], index: 0);
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 关键证据：解析替身确实被调了一次（既有各批都只拿到 0）。
      expect(gd.resolveSongUrlCalls, 1, reason: '无 URL 时必须真解析一次');
      expect(gd.resolveCoverUrlCalls, 1, reason: '有 picId 且无封面时补解析封面');

      // 1794-1813 的产物全部回填到当前曲上。
      final current = notifier.state.currentSong!;
      expect(current.id, 'p1');
      expect(current.previewStreamUrl, gd.resultUrl);
      expect(current.previewCoverUrl, gd.coverUrl);
      expect(current.previewQualityLabel, '320kbps');
      expect(current.previewRequestHeaders['Referer'], 'https://x.example.test');
      expect(current.bitRate, 320);
      expect(current.suffix, 'flac');

      // 试听分支的码率折算：byteRate>0 → 直接取（player_stream_source 67）。
      expect(notifier.state.currentBitRateKbps, 320);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
    });

    test('解析未回码率（br=null）→ 码率走 previewQualityLabel 解析，记 0', () async {
      notifier = await boot(
        immediateAddress: _addr('http://192.168.10.240:46400'),
      );
      gd.resultBitRateKbps = null;
      gd.resultSuffix = null;
      gd.resultHeaders = const <String, String>{};
      gd.coverUrl = null;
      // 无封面：既无 previewCoverUrl 也无 picId → 不再补封面（1800-1804 的守卫）。
      final song = _preview('p2', bitRate: null);

      await notifier.playSong(song, queue: <Song>[song], index: 0);
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(gd.resolveSongUrlCalls, 1);
      expect(gd.resolveCoverUrlCalls, 0, reason: '无 picId 不该发起封面解析');

      final current = notifier.state.currentSong!;
      expect(current.bitRate, isNull);
      expect(current.suffix, 'm4a', reason: 'resolved.suffix 为 null → 保留原后缀');
      // `_parseBitRateFromText('未知音质')` 取不到 kbps → 0（player_stream_source 49-56）。
      expect(notifier.state.currentBitRateKbps, 0);
    });

    test('解析抛错 → 在本试听队列内跳下一首（不进旧队列的 next）', () async {
      notifier = await boot(
        immediateAddress: _addr('http://192.168.10.240:46400'),
      );
      // 缺 source/trackId ⇒ 1790-1791 直接 StateError。
      final broken = _preview('bad', source: null, trackId: null);
      final good = _preview('p3', streamUrl: 'https://cdn.example.test/p3.m4a');

      await notifier.playSong(
        broken,
        queue: <Song>[broken, good],
        index: 0,
      );
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(notifier.state.currentSong?.id, 'p3');
      expect(gd.resolveSongUrlCalls, 0, reason: '缺 source/trackId 不该打网络');
    });
  });

  // ─────────── 二、`_ensureActiveAddressForPlayback` 的 ensure 兜底 ───────────
  group('地址兜底（player_stream_source 123-162）', () {
    test('无即时地址 → 等 ensureActiveAddressProvider，并把 baseUrl 切过去', () async {
      // pool.activeAddress 与 activeAddressProvider 同时为 null ⇒ 即时地址为 null。
      pool.immediate = null;
      notifier = await boot(
        immediateAddress: null,
        ensureAddress: _addr('http://10.0.0.9:46400'),
      );

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        index: 0,
      );
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 139-141：地址归一化后与 dio.baseUrl 不同 → 切库。
      expect(spy.dio.options.baseUrl, 'http://10.0.0.9:46400');
      expect(notifier.state.currentSong?.id, 's1');
      expect(spy.streamUrlCalls, isNotEmpty, reason: '兜底拿到地址后照常取流');
    });
  });
}
