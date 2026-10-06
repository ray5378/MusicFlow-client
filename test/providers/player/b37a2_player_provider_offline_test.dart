// batch37-A2 —— `lib/providers/player/player_provider.dart` 播放核心**剩余未覆盖行**补测。
//
// 本文件专啃 playSong 里那条**离线回退**大分支（源码 1004-1060），以及三条散落的
// 可达分支。既有 b29a/b34a 系列全部把 `isOfflineProvider` 钉成 false，所以整段
// 离线缓存起播一直是 0 命中：
//   * 1009-1049：离线 + 本地缓存命中 → `setUrl(file://…)` 播缓存文件并结算码率；
//   * 1050-1055：缓存文件损坏（setUrl 抛） → 记日志 + 当作不可播跳下一首；
//   * 1057-1060：离线 + 无缓存 → 提示离线并走跳过不可播；
//   * 1551：非 autoPlay 落地后把 `isPlaying` 压成 false；
//   * 1447-1449：`_updateMediaItem` 在歌曲有封面时把 artUri 解析成 Uri；
//   * 1078 + 1132-1134 + player_stream_source 74-76：非原始音质、不需转码时
//     `maxBitRate = quality.maxBitRate` 并落日志（`_resolveCurrentBitRateKbps`
//     走 `quality.maxBitRate` 分支）。
//
// 姿势与 b29a 完全一致：驱动**真实** `_PlayerNotifierImpl`，just_audio 平台换替身，
// 外部 provider（地址池/仓库/离线守护/投屏控制器）全桩。
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

  /// 置真后 `load()` 抛错 → 让离线缓存的 setUrl 失败（打 1050-1055 分支）。
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

  /// 传给后续创建出来的播放器：置真则 `load()` 抛错。
  bool throwOnLoad = false;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = _FakeAudioPlayerPlatform(request.id)..throwOnLoad = throwOnLoad;
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
  String? coverArt,
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
      coverArt: coverArt,
    );

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  /// `_enrichSongMetadata` 的补齐源；null → 直接 return。
  Song? getSongResult;
  bool throwOnGetSong = false;

  /// 置非空后 `getSong` 会**挂起**到该 Completer 完成 —— 用来把「补齐落地」
  /// 精确挪到源就绪（`_setStreamContext` 已执行）之后，从而进入
  /// `_enrichSongMetadata` 里 `_currentStreamSongId == songId` 那段（48-56）。
  Completer<void>? getSongGate;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async {
    final gate = getSongGate;
    if (gate != null) await gate.future;
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

/// 离线缓存管理器替身：直接给出（或不给）缓存文件，不碰真实磁盘布局。
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
  }) async =>
      <String, dynamic>{};
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

  Future<PlayerNotifier> boot({
    bool offline = false,
    AudioQualityLevel quality = AudioQualityLevel.original,
    File? cache,
  }) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(offline: offline, quality: quality, cache: cache);
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  setUp(() {
    repo.getSongResult = null;
    repo.throwOnGetSong = false;
    repo.getSongGate = null;
  });

  tearDown(() => container.dispose());

  test('离线 + 缓存命中 → 播放本地缓存文件并结算码率（1009-1049、1551）', () async {
    final tmp = File(
      '${Directory.systemTemp.path}/b37a2_offline_cache_file.mp3',
    )..writeAsStringSync('fake-audio-bytes');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync();
    });

    notifier = await boot(offline: true, cache: tmp);
    // 非 autoPlay 落地后要把 isPlaying 压回 false（1551）。
    notifier.state = notifier.state.copyWith(isPlaying: true);
    await notifier.playSong(_song('cache1'), autoPlay: false);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(notifier.state.currentSong?.id, 'cache1');
    expect(
      platform.last?.loadedUris.any((u) => u.contains('b37a2_offline_cache_file')),
      isTrue,
      reason: '离线命中应 setUrl 本地缓存文件（1023）',
    );
    expect(
      notifier.state.isPlaying,
      isFalse,
      reason: '非 autoPlay 落地后 isPlaying 应为 false（1551）',
    );
  });

  test('离线 + 缓存文件损坏(setUrl 抛) → 记日志并跳过，不崩（1050-1055）', () async {
    final tmp = File('${Directory.systemTemp.path}/b37a2_broken_cache.mp3')
      ..writeAsStringSync('x');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync();
    });

    notifier = await boot(offline: true, cache: tmp);
    // 关键：order 模式 + 把歌放在队尾，让失败后的 `next()` 在队尾停住。
    // 若用默认 all 模式 + 单曲队列，失败回退会「回绕重播→再失败」无限紧凑重试
    // （见报告 D-b37a2-1），测试会挂死。
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
      shuffleEnabled: false,
    );
    // AudioPlayer 惰性建平台，平台级开关保证本次播放一定会走 load 失败的路径。
    platform.throwOnLoad = true;
    await notifier.playSong(
      _song('cache2'),
      queue: <Song>[_song('lead'), _song('cache2')],
      index: 1,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // 缓存损坏 → 走 _handlePlaybackError 跳过；不抛异常即达标。
    expect(notifier.state.currentSong?.id, 'cache2');
  });

  test('离线 + 无缓存 → 提示离线并走跳过不可播（1057-1060）', () async {
    notifier = await boot(offline: true, cache: null);
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
      shuffleEnabled: false,
    );
    await notifier.playSong(
      _song('nocache'),
      queue: <Song>[_song('lead'), _song('nocache')],
      index: 1,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(notifier.state.currentSong?.id, 'nocache');
    expect(
      platform.last?.loadedUris ?? const <String>[],
      isEmpty,
      reason: '无缓存时不应发任何网络/文件加载',
    );
  });

  test('在线：非原始音质且无需转码 → maxBitRate=quality.maxBitRate（1078 等）', () async {
    // 用 high(320) 音质播一个 flac（无需转码）→ 1078 行取 quality.maxBitRate，
    // 并命中 1132-1134 的「bitrate-limited stream」日志分支；带封面 → 覆盖
    // _updateMediaItem 的 artUri 解析（1447-1449）。
    notifier = await boot(
      offline: false,
      quality: AudioQualityLevel.high,
    );
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
      shuffleEnabled: false,
    );
    await notifier.playSong(
      _song('q1', suffix: 'flac', coverArt: 'cover-1'),
      queue: <Song>[_song('lead'), _song('q1', suffix: 'flac', coverArt: 'cover-1')],
      index: 1,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(notifier.state.currentSong?.id, 'q1');
    expect(notifier.state.playbackSource, PlaybackSource.stream);
  });

  test('元数据补齐：缺失字段按需补 + 流上下文内重判 timeOffset（13-66）', () async {
    // current 有 suffix/bitRate/bitDepth/samplingRate，唯独缺 channelCount
    // → needsUpdate 要一路评估到 samplingRate(26) 与 channelCount(27) 两行。
    repo.getSongResult = Song(
      id: 'm1',
      title: '完整曲',
      artist: '歌手',
      suffix: 'flac',
      bitRate: 1411,
      bitDepth: 24,
      samplingRate: 96000,
      channelCount: 2,
      duration: 200,
    );
    notifier = await boot(offline: false);
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
      shuffleEnabled: false,
    );

    final partial = Song(
      id: 'm1',
      title: '完整曲',
      artist: '歌手',
      suffix: 'flac',
      bitRate: 1411,
      bitDepth: 24,
      samplingRate: 96000,
      duration: 200,
    );
    await notifier.playSong(
      partial,
      queue: <Song>[_song('lead'), partial],
      index: 1,
      autoPlay: false,
    );
    // `_scheduleSongRemoteRefresh` 是 unawaited，等补齐落地。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      notifier.state.currentSong?.channelCount,
      2,
      reason: '缺失的 channelCount 应被补齐（29-37）',
    );
  });

  test('元数据补齐失败：仅记 debug 日志，不影响播放（69）', () async {
    repo.throwOnGetSong = true;
    addTearDown(() => repo.throwOnGetSong = false);
    notifier = await boot(offline: false);
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
      shuffleEnabled: false,
    );
    await notifier.playSong(
      _song('m2'),
      queue: <Song>[_song('lead'), _song('m2')],
      index: 1,
      autoPlay: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(notifier.state.currentSong?.id, 'm2');
  });

  test('离线 + 缓存命中 + 非原始音质 → 码率取 quality.maxBitRate（75-76）', () async {
    // 离线落地分支（1033）不带 maxBitRate 参数 → `_resolveCurrentBitRateKbps`
    // 的 stream 分支里 `maxBitRate` 为 null，落到「quality != original 且有
    // maxBitRate」这一层（player_stream_source 74-76）。
    final tmp = File('${Directory.systemTemp.path}/b37a2_offline_hq.mp3')
      ..writeAsStringSync('fake-audio-bytes');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync();
    });

    notifier = await boot(
      offline: true,
      quality: AudioQualityLevel.high,
      cache: tmp,
    );
    await notifier.playSong(_song('hq1'), autoPlay: false);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(notifier.state.currentSong?.id, 'hq1');
    expect(
      notifier.state.currentBitRateKbps,
      AudioQualityLevel.high.maxBitRate,
      reason: '离线路径没传 maxBitRate → 取 quality.maxBitRate（75-76）',
    );
  });

  test('元数据补齐在源就绪后落地 → 进流上下文重判段（47-56）', () async {
    // 既有用例的补齐在 `_setStreamContext` 之前就返回了（`_currentStreamSongId`
    // 仍为 null → 47 行短路、48-56 从不评估）。这里用 gate 把补齐**卡到**源就绪
    // 之后，让 `_currentStreamSongId == songId` 成立。
    final gate = Completer<void>();
    repo.getSongGate = gate;
    repo.getSongResult = Song(
      id: 'm3',
      title: '流内补齐',
      artist: '歌手',
      suffix: 'flac',
      bitRate: 1411,
      bitDepth: 24,
      samplingRate: 96000,
      channelCount: 2,
      duration: 200,
    );
    notifier = await boot(offline: false);
    notifier.state = notifier.state.copyWith(
      playbackMode: PlaybackMode.order,
      loopMode: LoopMode.off,
      shuffleEnabled: false,
    );

    final partial = Song(
      id: 'm3',
      title: '流内补齐',
      artist: '歌手',
      suffix: 'flac',
      bitRate: 1411,
      bitDepth: 24,
      samplingRate: 96000,
      duration: 200, // channelCount 缺失
    );
    await notifier.playSong(
      partial,
      queue: <Song>[_song('lead'), partial],
      index: 1,
      autoPlay: false,
    );

    // 等源真正装好：`load()` 完成即 `_setStreamContext` 已执行。
    for (var i = 0; i < 200 && (platform.last?.loadCount ?? 0) < 1; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(platform.last?.loadCount ?? 0, greaterThanOrEqualTo(1));

    // 放行补齐 → 47 行的 `_currentStreamSongId == songId` 成立，48-56 被评估。
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      notifier.state.currentSong?.channelCount,
      2,
      reason: '流上下文内补齐仍要写回当前曲（36-46）',
    );
  });
}
