// ignore_for_file: depend_on_referenced_packages

// b37a2：`lib/providers/player/player_seek.dart` 的三条**兜底/拒收**分支
// —— 既有 `player_seek_internals_cov_test.dart`（batch28-B）擦到边但**没进过**：
//
//   * `_seekWithFallback` 非管道源（plan == null）里「裸 seek 后位置漂移 > 2s」
//     的温和重试链（源码 198-214）：既有用例把替身构造成「seek 后位置就落在
//     目标上」（drift=0 走 192 行 return），这条永远打不到。本批让替身
//     **seek 不改位置**（`stickyPosition`），drift 必然 > 2s。
//   * `_seekWithFallback` 同段微调里「源内 seek 被源拒收 → 升级全量重拉」
//     （源码 152-155）：既有用例只证了「同段不再重拉」，没让 seek 抛。
//     本批把替身的 `seek()` 做成**一次性抛错**（`failNextSeek`）。
//   * `_softResumePlayback` 里 `play()` 被拒只吞日志（源码 90-94）：既有用例的
//     替身 `play()` 从不抛，catchError 那段是死的。本批 `failNextPlay` 一次性抛。
//
// 不碰 lib/ 一行；不依赖 mocktail / fake_async（mixin 里的 220ms/120ms 走真墙钟）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

// ───────────────────── just_audio 平台替身（在 batch28-B 那份上加三个开关） ─────────────────────

class _SeekFakePlayer extends AudioPlayerPlatform {
  _SeekFakePlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  final List<String> calls = <String>[];
  final List<Duration?> seeks = <Duration?>[];
  final List<String> loadedUris = <String>[];

  Duration reportedPosition = Duration.zero;
  Duration? reportedDuration = const Duration(seconds: 200);
  ProcessingStateMessage processingState = ProcessingStateMessage.idle;
  bool playing = false;

  /// `load()` 抛错（钉「重拉失败 → 回退裸 seek」）。
  bool failLoad = false;

  /// `load()` 里不采用 request.initialPosition。
  bool ignoreInitialPosition = false;

  /// ★ 本批新增：`seek()` 后广播一个**错误的**位置（让 seek 后的 position 撒谎，
  /// 触发 `_seekWithFallback` 的漂移重试链）。
  ///
  /// 不能只靠「seek 不广播事件」：just_audio 的 `AudioPlayer.seek()` 自己会把
  /// `_playbackEvent` 乐观改成目标值，position 照样落在目标上 ⇒ drift=0。
  /// 必须让平台的 `seek()` **广播一个带错误位置的事件**，把乐观值压回去。
  Duration? seekReportOverride;

  /// ★ 本批新增：下一次 `seek()` 抛错（一次性）。
  bool failNextSeek = false;

  /// ★ 本批新增：下一次 `play()` 抛错（一次性）。
  bool failNextPlay = false;

  /// `load()` 执行中的钩子。
  Future<void> Function()? onLoad;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  int count(String method) => calls.where((c) => c == method).length;

  void emit({
    ProcessingStateMessage? state,
    Duration? position,
    Duration? duration,
  }) {
    if (state != null) processingState = state;
    if (position != null) reportedPosition = position;
    if (duration != null) reportedDuration = duration;
    _events.add(
      PlaybackEventMessage(
        processingState: processingState,
        updateTime: DateTime.now(),
        updatePosition: reportedPosition,
        bufferedPosition: reportedPosition,
        duration: reportedDuration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  void emitPlaying(bool value) {
    playing = value;
    _data.add(PlayerDataMessage(playing: value));
  }

  void reset() {
    calls.clear();
    seeks.clear();
    loadedUris.clear();
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    calls.add('load');
    final msg = request.audioSourceMessage;
    loadedUris.add(msg is UriAudioSourceMessage ? msg.uri : '<non-uri>');
    await onLoad?.call();
    if (failLoad) {
      throw PlatformException(code: 'stub-load-failed', message: 'stub failure');
    }
    if (!ignoreInitialPosition) {
      reportedPosition = request.initialPosition ?? Duration.zero;
    }
    emit(state: ProcessingStateMessage.loading);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    emit(state: ProcessingStateMessage.ready);
    return LoadResponse(duration: reportedDuration);
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    calls.add('seek');
    seeks.add(request.position);
    if (failNextSeek) {
      failNextSeek = false;
      throw PlatformException(code: 'stub-seek-rejected', message: 'stub');
    }
    reportedPosition = seekReportOverride ?? request.position ?? Duration.zero;
    emit(position: reportedPosition);
    return SeekResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
    if (failNextPlay) {
      failNextPlay = false;
      throw PlatformException(code: 'stub-play-rejected', message: 'stub');
    }
    emitPlaying(true);
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    calls.add('pause');
    emitPlaying(false);
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    calls.add('setVolume');
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    calls.add('setSpeed');
    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async =>
      DisposeResponse();
}

class _SeekFakePlatform extends JustAudioPlatform {
  final List<_SeekFakePlayer> players = <_SeekFakePlayer>[];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = _SeekFakePlayer(request.id);
    players.add(p);
    return p;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
          DisposePlayerRequest request) async =>
      DisposePlayerResponse();

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

// ───────────────────────────── 素材 ─────────────────────────────

Song _song(String id) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'flac',
      bitRate: 1411,
      duration: 200,
    );

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository()
      : super(SubsonicApiClient(
          dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
        ));

  @override
  Future<void> setSongStarred(String songId, bool starred) async {}

  @override
  Future<Song?> getSong(String songId) async => null;
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
  final fake = _SeekFakePlatform();

  setUp(() {
    // 静态槽位跨用例残留，不重置会把上一条的替身当自己的引擎。
    JustAudioPlatform.instance = fake;
    fake.players.clear();
  });

  ServerAddress addr() => ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: 'http://192.168.10.240:46400',
        priority: 0,
      );

  MusicLibrary library({String? serverType}) => MusicLibrary(
        id: 'lib1',
        name: '主库',
        serverType: serverType,
        username: 'u1',
        password: 'p1',
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  SubsonicApiClient apiClient({String? serverType}) =>
      SubsonicApiClient(
          dio: Dio(BaseOptions(baseUrl: 'http://192.168.10.240:46400')))
        ..setLibrary(library(serverType: serverType));

  ProviderContainer buildContainer({String? serverType = 'MusicFlow'}) =>
      ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider
              .overrideWithValue(library(serverType: serverType)),
          activeAddressProvider.overrideWith((ref) => addr()),
          effectiveQualityProvider
              .overrideWithValue(AudioQualityLevel.original),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider
              .overrideWithValue(apiClient(serverType: serverType)),
          musicRepositoryProvider.overrideWithValue(repo),
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

  Future<PlayerNotifier> waitQuiet(PlayerNotifier n) async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (i > 4 && !n.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (!n.debugIsRestoringPlaybackSession) return n;
      }
    }
    return n;
  }

  Future<PlayerNotifier> boot({String? serverType = 'MusicFlow'}) async {
    final c = buildContainer(serverType: serverType);
    // 重拉的尾巴是 fire-and-forget，立刻 dispose 会把 after-dispose 抛给下一条。
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      c.dispose();
    });
    final n = c.read(playerProvider.notifier);
    return waitQuiet(n);
  }

  Future<_SeekFakePlayer> awaitPlayer({int loads = 1}) async {
    for (var i = 0; i < 300; i++) {
      for (final p in fake.players) {
        if (p.count('load') >= loads) return p;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('替身平台始终没被初始化，players=${fake.players.length}');
  }

  Future<_SeekFakePlayer> playSongOf(PlayerNotifier n, Song song) async {
    final started = n.playSong(song, queue: <Song>[song]);
    final p = await awaitPlayer();
    await started;
    return p;
  }

  // ─────── 一、非管道源：裸 seek 后位置漂移 > 2s → pause → 再 seek → 恢复 ───────
  group('_seekWithFallback · 漂移兜底（198-214）', () {
    test('非管道源裸 seek 后引擎位置撒谎 > 2s → 暂停重试并在恢复后继续播', () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.play();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(p.playing, isTrue, reason: '前置：替身必须真的处于 playing（要打恢复分支）');

      // seek 广播错误位置（仍是起点）→ 220ms 后 `actual` 仍停在起点，
      // drift ≈ 90s > 2000ms。
      p.seekReportOverride = Duration.zero;
      p.reset();

      await n.seek(const Duration(seconds: 90));

      // 一次裸 seek + 漂移后必须再补一次（还给暂停 / 恢复留了痕）。
      expect(p.count('load'), 0, reason: '非管道源不做 timeOffset 重拉');
      expect(p.count('seek'), greaterThanOrEqualTo(2),
          reason: '漂移 > 2s 必须原地重试一次');
      expect(p.count('pause'), greaterThanOrEqualTo(1),
          reason: '重试前要先暂停（shouldResume=true）');
      expect(p.count('play'), greaterThanOrEqualTo(1),
          reason: '重试后要恢复播放（_startPlayback）');
      expect(n.state.position, const Duration(seconds: 90),
          reason: '对外仍是用户拖到的目标');

      p.seekReportOverride = null;
    });

    test('非管道源未在播：漂移重试不 pause、不恢复播放（走 false 侧）', () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s2'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // playSong 默认 autoPlay=true 会真的起播，先暂停把 playing 压回 false
      // ⇒ shouldResume=false，走重试链的 false 侧。
      await n.pause();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(p.playing, isFalse);

      p.seekReportOverride = Duration.zero;
      p.reset();

      await n.seek(const Duration(seconds: 120));

      expect(p.count('seek'), greaterThanOrEqualTo(2), reason: '仍然要原地重试');
      expect(p.count('pause'), 0, reason: '没在播就不该暂停');
      expect(n.state.position, const Duration(seconds: 120));

      p.seekReportOverride = null;
    });
  });

  // ─────── 二、同段微调：源内 seek 被拒 → 升级全量重拉（152-155） ───────
  group('_seekWithFallback · 同段拒收升级重拉', () {
    test('第二次拖到同段，源内 seek 被源拒收 → 日志后升级整源重拉', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 第一次：整源重拉到 90s，落位偏移=90。
      await n.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      p.reset();

      // 第二次同段：走「源内 seek」那条，让源拒收 → 升级重拉。
      p.failNextSeek = true;
      await n.seek(const Duration(seconds: 90));

      expect(p.count('load'), 1,
          reason: '源内 seek 被拒后必须升级为整源重拉（152-155 → 157）');
      expect(n.state.position, const Duration(seconds: 90));
    });
  });

  // ─────── 三、_softResumePlayback：补 play 被拒只吞日志（90-94） ───────
  group('_softResumePlayback · play 被拒', () {
    test('重拉后播放意图仍在，但补 play() 被拒 → 只记日志不炸调用方', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.play();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(p.playing, isTrue);

      // 重拉期间替身把 playing 压回 false（新源首包瞬态）→ shouldResume 已记 true
      // → 重拉尾巴会调 _softResumePlayback，而这一下 play() 被源拒收。
      p.onLoad = () async => p.emitPlaying(false);
      p.failNextPlay = true;
      p.reset();

      await expectLater(n.seek(const Duration(seconds: 45)), completes);

      expect(p.count('play'), greaterThanOrEqualTo(1),
          reason: '确实下发过补 play（才能进 catchError）');
      expect(n.state.position, const Duration(seconds: 45));

      p.onLoad = null;
    });
  });

  // ─────── 四、Windows 平台：停滞信号改用 player.playing（position_polling 45-47） ───────
  group('player_position_polling · Windows 停滞信号', () {
    test('Windows 桌面轮询 tick 走 isWinDesktop 侧（45-47）', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('w1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 源就绪**之后**再切平台：`_init()` 已按 android 建好（避开 Windows SMTC
      // 分支），而轮询回调每 tick 现读 `defaultTargetPlatform` —— 于是
      // `isWinDesktop=true`，`stallSignal` 取 `player.playing`（46-47 的 Windows 侧，
      // 既有 b34a 系列全程 android，命中恒为 false 侧）。
      final prev = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        // ≥2 个 500ms 轮询 tick，确保 Windows 分支真的被评估过。
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      } finally {
        debugDefaultTargetPlatformOverride = prev;
      }

      expect(n.state.currentSong?.id, 'w1');
      expect(
        p.count('load'),
        1,
        reason: '短暂窗口内不该触发 0 秒卡死/停滞看门狗的重载',
      );
    });
  });
}
