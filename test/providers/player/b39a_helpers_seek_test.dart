// b39a —— Route A 播放核心补测（第二批）：**元数据补齐后的 offset-seek 重判**
// 与 **重拉期间被新 seek 顶替后的 pendingSeek 补排**。
//
// 覆盖目标（lbp 口径，player_provider.dart 因批注插入整体下移约 4 行）：
//   * player_playback_helpers `_enrichSongMetadata` 内「元数据补齐后
//     `useServerTimeOffsetSeek` 与当前 `_seekByReloadStream` 不一致 →
//     更新标记与日志」（约 L58-62）。姿势：Navidrome 服务端（非管道化）+ 请求
//     高音质转码，歌曲元数据缺失（suffix=null），补齐后 suffix=flac/1411 →
//     重判恒真，与初判 false 冲突。
//   * player_seek `_reloadStreamForSeek` 在整源重拉落位后「会话已不是当前 seek →
//     `_schedulePendingSeekIfReady()`」（约 L263）；以及
//     `_schedulePendingSeekIfReady` 命中「pendingSeek 仍在 + 源已就绪」时补跑
//     `_applyPendingSeekIfNeeded()`（约 L455-457/L462）。姿势：第一次 seek 触发的
//     整源重拉被 `load` 闸门卡住（期间 `_loadedSourceSongId=null`），此时第二次
//     seek 只能排队；放闸后重拉落位 → 补排 pending。
//
// 不碰 lib/ 一行；不依赖 mocktail/fake_async。
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

  final List<String> calls = <String>[];

  /// 非空时 `load()` 会在此挂起（卡住整源重拉）——用来制造「重拉途中源
  /// 尚未就绪（`_loadedSourceSongId=null`）→ 后续 seek 只能排队」的窗口。
  Completer<void>? loadGate;

  var _tick = 0;

  static const Duration _duration = Duration(seconds: 200);

  int count(String method) => calls.where((c) => c == method).length;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void _emit(ProcessingStateMessage state) {
    _tick += 1;
    final pos = Duration(seconds: _tick * 30);
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: pos,
        bufferedPosition: pos,
        duration: _duration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    calls.add('load');
    _emit(ProcessingStateMessage.loading);
    final gate = loadGate;
    if (gate != null) await gate.future;
    _emit(ProcessingStateMessage.ready);
    return LoadResponse(duration: _duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
    _data.add(PlayerDataMessage(playing: true));
    return PlayResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    calls.add('pause');
    _data.add(PlayerDataMessage(playing: false));
    return PauseResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    calls.add('seek');
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
        const <dynamic, dynamic>{},
      );

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
  String? suffix = 'flac',
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

  Song? getSongResult;
  Completer<void>? getSongGate;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async {
    final gate = getSongGate;
    if (gate != null) await gate.future;
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

class _NoopCastPeerController extends CastPeerController {
  _NoopCastPeerController(super.ref);

  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async => null;

  @override
  Future<void> syncLocalQueueNow() async {}
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
  final spy = _SpySubsonicApiClient();
  late _FakeJustAudioPlatform platform;

  ProviderContainer buildContainer({
    String serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
  }) =>
      ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(
            MusicLibrary(
              id: 'lib1',
              name: '主库',
              serverType: serverType,
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
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          offlineCacheManagerProvider.overrideWithValue(_FakeCacheManager(null)),
          offlineCacheReadyProvider.overrideWith((ref) async {}),
          castPeerControllerProvider.overrideWith(
            (ref) => _NoopCastPeerController(ref),
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

  Future<void> pump([int times = 12]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({
    String serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
  }) async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer(serverType: serverType, quality: quality);
    final n = container.read(playerProvider.notifier);
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (i > 4 && !n.debugIsRestoringPlaybackSession) break;
    }
    return n;
  }

  setUp(() {
    repo.getSongResult = null;
    repo.getSongGate = null;
  });

  tearDown(() {
    container.dispose();
  });

  // ───── helpers 58-62：元数据补齐后 offset-seek 重判 ─────
  test('元数据补齐后 offset-seek 判定翻转 → 更新标记（helpers L58-62）', () async {
    notifier = await boot(
      serverType: 'Navidrome',
      quality: AudioQualityLevel.high,
    );
    // 补齐源：suffix/bitRate 已知 → 重判 useServerTimeOffsetSeek=true，
    // 而初判（suffix 缺失）为 false → 命中「不一致」分支。
    repo.getSongResult = _song('s1', suffix: 'flac', bitRate: 1411);
    final gate = Completer<void>();
    repo.getSongGate = gate;

    await notifier.playSong(
      _song('s1', suffix: null, bitRate: null),
      queue: <Song>[_song('s1', suffix: null, bitRate: null)],
    );
    await pump();

    // 放行补齐：此时源已就绪（_currentStreamSongId=s1、offset=0）。
    gate.complete();
    repo.getSongGate = null;
    await pump(20);

    expect(
      notifier.state.currentSong?.suffix,
      'flac',
      reason: '补齐应把 suffix 写回当前曲（证明 enrich 走到了重判段）',
    );
    expect(notifier.state.currentSong?.bitRate, 1411);
  });

  // ───── player_seek 263/455-462：重拉被顶替 → 补排 pendingSeek ─────
  test('重拉途中被新 seek 顶替 → 落位后补排 pendingSeek（seek L263/L455-462）',
      () async {
    notifier = await boot();
    await notifier.playSong(_song('s1'), queue: <Song>[_song('s1')]);
    await pump();
    final p = platform.last!;
    expect(p.count('load'), 1);

    // 卡住下一次（整源重拉）加载：期间 _loadedSourceSongId=null。
    final gate = Completer<void>();
    p.loadGate = gate;

    final firstSeek = notifier.seek(const Duration(seconds: 90));
    for (var i = 0; i < 60 && p.count('load') < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(p.count('load'), greaterThanOrEqualTo(2),
        reason: '首次 seek 应触发带 timeOffset 的整源重拉');

    // 重拉尚未落位（源未就绪）→ 这次 seek 只能排队 pending。
    await notifier.seek(const Duration(seconds: 40));

    // 放闸：重拉落位 → 顶替检测命中 → 补排 pendingSeek。
    gate.complete();
    p.loadGate = null;
    await firstSeek;
    await pump(20);

    expect(
      notifier.state.position,
      const Duration(seconds: 40),
      reason: '被顶替 seek 落位后应补跑排队中的 pendingSeek（L263/L455-462）',
    );
  });
}
