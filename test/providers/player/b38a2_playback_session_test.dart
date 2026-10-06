// b38a2 —— Route A 播放核心补测：**播放会话恢复**（player_playback_session.dart）。
//
// 与既有 b38a 系列（真实 PlayerNotifier + just_audio 替身）同一姿势，但这里专啃
// `_restorePlaybackSession` 这条启动路径上 lcov 仍 0 命中的分支：
//   * 「新鲜度竞速」服务端快照胜出分支（useServer）：队列/索引/播放模式还原
//     （player_playback_session 200-229）；
//   * 本地会话空队列 → 立即清盘（176）；
//   * 队列内损坏条目 → 跳过该条不炸恢复（357）；
//   * `_parseStoredInt` 的 num / String 两条兼容分支（369/370）；
//   * `_resolveRestoredQueueIndex` 的 indexWhere 命中 / 负索引 / 越界夹紧
//     （388/389/392/393）；
//   * 恢复后回推服务端失败被吞（310/312）；
//   * 本机落盘播放模式为未知串 → orElse 回退 all（player_provider 2408）。
//
// 做法：测试直接把**精心构造的会话 payload** 写进 LocalStorage（JsonFileStore
// 走临时目录隔离），再启动真实 notifier 走完整恢复流程。不走任何私有成员 ——
// 全部经由 `LocalStorage` / `castPeerControllerProvider` 这两个被测代码的真实
// 输入口注入。
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
import 'package:musicflow_client/data/sources/local_storage.dart';
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


class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(
          SubsonicApiClient(
            dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
          ),
        );

  Song? getSongResult;
  bool throwOnGetSong = false;

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async {
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

  /// 记录所有被调过的 REST 路径（`/rest/scrobble` 等），供断言"确实上报了"。
  final List<String> paths = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    paths.add(path);
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

/// 投屏/本机队列控制器替身：
///   * `fetchLocalQueueForRestore` 直接吐测试构造的「服务端快照」——
///     被测的新鲜度竞速分支只能经这个口子喂数据；
///   * `syncLocalQueueNow` 可置为抛错，用于验证恢复流程不被回推失败拖死。
class _CastCfg {
  Map<String, dynamic>? snapshot;
  bool throwOnSync = false;
}

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref, this.cfg);

  final _CastCfg cfg;

  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async =>
      cfg.snapshot;

  @override
  Future<void> syncLocalQueueNow() async {
    if (cfg.throwOnSync) throw StateError('syncLocalQueueNow boom');
  }
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
  final castCfg = _CastCfg();
  late _FakeJustAudioPlatform platform;
  late Directory dir;
  ProviderContainer? container;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('b38a2_session_');
    JsonFileStore.instance.debugDirectory = dir;
    repo.getSongResult = null;
    repo.throwOnGetSong = false;
    spy.paths.clear();
    castCfg.snapshot = null;
    castCfg.throwOnSync = false;
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
            (ref) => _FakeCastPeerController(ref, castCfg),
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
    container = buildContainer(offline: offline, quality: quality, cache: cache);
    final n = container!.read(playerProvider.notifier);
    // 恢复跑在 `_init()` 的异步尾巴上，轮询到恢复窗口关闭为止。
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 6 && !n.debugIsRestoringPlaybackSession) break;
    }
    return n;
  }

  /// 轮询等待条件成立（避免用固定 sleep 猜时长造成 flaky）。
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

  /// 会话 payload 构造器。字段类型放宽到 Object?，以便把 `currentIndex`
  /// 灌成 double / String 去打 `_parseStoredInt` 的两条兼容分支。
  Map<String, dynamic> sessionPayload({
    required List<Map<String, dynamic>> queue,
    Object? currentIndex = 0,
    String? currentSongId,
    Object? positionMs = 0,
    bool isPlaying = false,
    Object? updatedAt = 0,
  }) =>
      <String, dynamic>{
        'version': 1,
        'queue': queue,
        'currentIndex': currentIndex,
        'currentSongId': currentSongId,
        'positionMs': positionMs,
        'isPlaying': isPlaying,
        'updatedAt': updatedAt,
      };

  Map<String, dynamic> songJson(String id) => <String, dynamic>{
        'id': id,
        'title': '曲$id',
        'artist': '歌手',
        'albumId': 'al1',
        'suffix': 'flac',
        'duration': 200,
        'bitRate': 1411,
        'starred': false,
      };

  List<String> idsOf(PlayerNotifier n) =>
      n.state.queue.map((Song s) => s.id).toList();

  group('A. 服务端快照胜出（新鲜度竞速 useServer 分支）', () {
    /// 服务端快照条目形状（songId / mime），与 queueItemToSong 对齐。
    Map<String, dynamic> serverItem(String songId, {String mime = 'audio/flac'}) =>
        <String, dynamic>{
          'songId': songId,
          'title': '服务$songId',
          'artist': '歌手',
          'albumId': 'al1',
          'mime': mime,
          'duration': 200,
        };

    void seedSnapshot({String? playMode, int currentIndex = 1}) {
      castCfg.snapshot = <String, dynamic>{
        'items': <Object?>[serverItem('srv1'), serverItem('srv2', mime: 'audio/mpeg')],
        'currentIndex': currentIndex,
        if (playMode != null) 'playMode': playMode,
        // 远大于本地 updatedAt(本地无会话按 0 计) → 服务端胜出。
        'updatedAt': 9999999999999,
      };
    }

    test('本地无会话 + 服务端快照 → 按快照恢复队列/索引，模式 shuffle', () async {
      seedSnapshot(playMode: 'shuffle');
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(idsOf(n), <String>['srv1', 'srv2']);
      expect(n.state.currentIndex, 1);
      await waitUntil(() => n.state.playbackMode == PlaybackMode.shuffle);
      expect(n.state.playbackMode, PlaybackMode.shuffle);
      expect(n.state.currentSong?.id, 'srv2');
    });

    test('快照 playMode=one → 还原单曲循环', () async {
      seedSnapshot(playMode: 'one');
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      await waitUntil(() => n.state.playbackMode == PlaybackMode.one);
      expect(n.state.playbackMode, PlaybackMode.one);
    });

    test('快照 playMode=all → 还原列表循环', () async {
      seedSnapshot(playMode: 'all');
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      await waitUntil(() => n.state.playbackMode == PlaybackMode.all);
      expect(n.state.playbackMode, PlaybackMode.all);
    });

    test('快照缺 playMode → switch 默认回退 order', () async {
      seedSnapshot(playMode: null);
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      await waitUntil(() => n.state.playbackMode == PlaybackMode.order);
      expect(n.state.playbackMode, PlaybackMode.order);
    });

    test('快照 currentIndex 越界 → 夹到 0', () async {
      seedSnapshot(playMode: 'order', currentIndex: 99);
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(n.state.currentIndex, 0);
      expect(n.state.currentSong?.id, 'srv1');
    });

    test('本地会话更新 → 服务端快照不抢（本地优先）', () async {
      castCfg.snapshot = <String, dynamic>{
        'items': <Object?>[serverItem('srv1')],
        'currentIndex': 0,
        'playMode': 'order',
        'updatedAt': 1000,
      };
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[songJson('loc1')],
          currentIndex: 0,
          currentSongId: 'loc1',
          updatedAt: 9999999999999,
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(idsOf(n), <String>['loc1'],
          reason: '本地 updatedAt 更新 → 必须恢复本地队列');
    });
  });

  group('B. 本地会话解析边界', () {
    test('会话队列为空 → 立即清盘（176）', () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(queue: <Map<String, dynamic>>[]),
      );
      final n = await boot();
      // 清盘发生在恢复的读盘阶段，轮询到文件消失为止。
      var cleared = false;
      for (var i = 0; i < 60 && !cleared; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        cleared = (await LocalStorage.getPlaybackSession()) == null;
      }
      expect(cleared, isTrue);
      expect(await LocalStorage.getPlaybackSession(), isNull,
          reason: '空队列会话留在盘上会让下次启动恢复出空壳');
      expect(n.state.queue, isEmpty);
    });

    test('队列含损坏条目 → 只跳过该条，其余照常恢复（357）', () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[
            songJson('a'),
            // previewPicId 是 int → Song.fromJson 的 `as String?` 强转抛错。
            <String, dynamic>{'id': 'bad', 'previewPicId': 123},
            songJson('c'),
          ],
          currentIndex: 0,
          currentSongId: 'a',
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.length == 2);
      expect(idsOf(n), <String>['a', 'c'],
          reason: '损坏条目必须被丢弃而不是把整段恢复带崩');
      expect(n.state.currentSong?.id, 'a');
    });

    test('_parseStoredInt：double 走 num 分支、String 走解析分支（369/370）',
        () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[
            songJson('a'),
            songJson('b'),
            songJson('c'),
          ],
          // 1.0 经 JSON 往返后是 double，不是 int。
          currentIndex: 1.0,
          currentSongId: 'b',
          positionMs: '42000',
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(n.state.currentIndex, 1, reason: 'double 索引必须被接受');
      expect(n.state.currentSong?.id, 'b');
      await waitUntil(
        () => n.state.position >= const Duration(milliseconds: 41000),
      );
      expect(
        n.state.position.inMilliseconds,
        greaterThanOrEqualTo(41000),
        reason: 'positionMs 以字符串存储时也必须解析成进度',
      );
    });

    test('_resolveRestoredQueueIndex：索引指向错歌 → 按 id 重新定位（388/389）',
        () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[
            songJson('a'),
            songJson('b'),
            songJson('c'),
          ],
          currentIndex: 0,
          currentSongId: 'c',
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.currentSong?.id == 'c');
      expect(n.state.currentIndex, 2,
          reason: 'currentSongId 才是对的锚点，索引只是偏好值');
    });

    test('_resolveRestoredQueueIndex：负索引夹到 0（392）', () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[
            songJson('a'),
            songJson('b'),
          ],
          currentIndex: -5,
          currentSongId: '',
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(n.state.currentIndex, 0);
      expect(n.state.currentSong?.id, 'a');
    });

    test('_resolveRestoredQueueIndex：越界索引夹到队尾（393）', () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[
            songJson('a'),
            songJson('b'),
            songJson('c'),
          ],
          currentIndex: 99,
          currentSongId: '',
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(n.state.currentIndex, 2);
      expect(n.state.currentSong?.id, 'c');
    });
  });

  group('C. 恢复后的健壮性', () {
    test('回推服务端失败被吞，恢复照常完成（310/312）', () async {
      castCfg.throwOnSync = true;
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[
            songJson('a'),
            songJson('b'),
          ],
          currentIndex: 0,
          currentSongId: 'a',
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(idsOf(n), <String>['a', 'b'],
          reason: '回推失败不能把恢复出来的队列带走');
    });

    test('恢复完成后 isRestoringPlaybackSession 必须落回 false（289）', () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[songJson('a')],
          currentIndex: 0,
          currentSongId: 'a',
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      expect(n.isRestoringPlaybackSession, isFalse,
          reason: '恢复标志卡住 true 会永久压掉所有会话落盘');
      expect(n.debugIsRestoringPlaybackSession, isFalse);
    });

    test('恢复窗口关闭后会话可正常落盘（不被恢复闸门压掉）', () async {
      await LocalStorage.savePlaybackSession(
        sessionPayload(
          queue: <Map<String, dynamic>>[songJson('a'), songJson('b')],
          currentIndex: 0,
          currentSongId: 'a',
          updatedAt: 0,
        ),
      );
      final n = await boot();
      await waitUntil(() => n.state.queue.isNotEmpty);
      await n.persistPlaybackStateNow();
      final saved = await LocalStorage.getPlaybackSession();
      expect(saved, isNotNull);
      expect((saved!['queue'] as List).length, 2);
    });
  });

  group('D. 播放模式恢复', () {
    test('盘上是合法模式串 → 原样恢复', () async {
      await LocalStorage.setPlaybackMode(PlaybackMode.one.name);
      final n = await boot();
      await waitUntil(() => n.state.playbackMode == PlaybackMode.one);
      expect(n.state.playbackMode, PlaybackMode.one);
    });

    // 注意：2408（_restorePlaybackMode 的 orElse）不可达 —— 上游
    // LocalStorage.getPlaybackMode 已把未知串归一为 'all'，firstWhere 永远
    // 命中。本用例锁死的就是这条「未知串不会打穿恢复流程」的端到端契约。
    test('盘上是未知模式串 → 归一为 all 且不抛（2408 的 orElse 为防御死代码）',
        () async {
      await LocalStorage.setPlaybackMode('__no_such_mode__');
      final n = await boot();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(n.state.playbackMode, PlaybackMode.all,
          reason: '未知模式串必须回退 all，不能让恢复流程抛异常中断');
      expect(await LocalStorage.getPlaybackMode(), 'all',
          reason: '归一化发生在 LocalStorage.getPlaybackMode，恢复侧不再二次兜底');
    });
  });
}
