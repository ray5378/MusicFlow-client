// b45：[D-063] 首载流带 timeOffset —— 续播/流转落位前移，消除双载 churn。
//
// 背景（240 日志实证）：同一首 56MB WebDAV FLAC 在 45s 内被整曲缓冲 3 次，
// 且每次都是 timeOffset=0 —— playSong(initialPosition) 原先先按
// timeOffset=0 起播（大文件整曲缓冲 3~4s），音源就绪后才经 pendingSeek
// 管线整条重拉到 timeOffset=at。大文件上被放大成反复重载，用户感知为
// 「进度条在跑却没声音，切下一首才响」。
//
// 本批验证：
//   1. initialPosition 非空 → 首载 URL 带 timeOffset（整秒），播放器
//      initialPosition 收余数（<1s），全程只加载一次（无重拉、无事后 seek）。
//   2. 双载守卫：pending 与当前流偏移一致时清残留，不 seek/不重拉。
//   3. initialPosition 为空 → 行为与改造前完全一致（不退化）。
//   4. 防回归：首载落位后手动 seek 到别处仍走全量重拉（守卫只拦同位置
//      残留，不拦真 seek）。
//
// 不依赖 mocktail / fake_async；mixin 里的 220ms/120ms 走真墙钟。
// ignore_for_file: depend_on_referenced_packages

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

  MusicLibrary library() => MusicLibrary(
        id: 'lib1',
        name: '主库',
        serverType: 'MusicFlow',
        username: 'u1',
        password: 'p1',
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  SubsonicApiClient apiClient() => SubsonicApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://192.168.10.240:46400')),
      )..setLibrary(library());

  ProviderContainer buildContainer() => ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(library()),
          activeAddressProvider.overrideWith((ref) => addr()),
          effectiveQualityProvider
              .overrideWithValue(AudioQualityLevel.original),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(apiClient()),
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

  Future<PlayerNotifier> boot() async {
    final c = buildContainer();
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

  Future<_SeekFakePlayer> playSongOf(
    PlayerNotifier n,
    Song song, {
    Duration? initialPosition,
  }) async {
    final started = n.playSong(
      song,
      queue: <Song>[song],
      initialPosition: initialPosition,
    );
    final p = await awaitPlayer();
    await started;
    return p;
  }

  group('D-063 · 首载流带 timeOffset（双载消除）', () {
    test('initialPosition=90.5s → URL 带 timeOffset=90、余数 500ms 进播放器、'
        '全程一次加载零 seek', () async {
      final n = await boot();
      const resume = Duration(milliseconds: 90500);
      final p = await playSongOf(n, _song('s1'), initialPosition: resume);
      // 等 pendingSeek 管线跑完（守卫应直接清残留）。
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(p.count('load'), 1,
          reason: '双载消除：只允许一次加载，不得事后重拉');
      expect(p.loadedUris.single, contains('timeOffset=90'),
          reason: '首载 URL 必须带整秒 timeOffset');
      expect(p.reportedPosition, const Duration(milliseconds: 500),
          reason: '不足 1s 的余数应作为播放器 initialPosition');
      expect(p.count('seek'), 0,
          reason: '首载已落位，pendingSeek 守卫必须拦掉事后 seek/重拉');
      // just_audio 的 position getter = 事件位置 + 墙钟外推（pause 只停
      // 后续推进、不回滚已外推值），故用容差：落点 90.5s + 起播后推进。
      expect(
        (n.state.position - resume).inMilliseconds.abs(),
        lessThan(2000),
        reason: '起播点必须是恢复进度（容差覆盖播放推进）',
      );
      expect(n.state.currentSong?.id, 's1');
    });

    test('initialPosition 为空 → 行为不退化：URL 无 timeOffset、仍一次加载',
        () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s2'));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(p.count('load'), 1);
      expect(p.loadedUris.single, isNot(contains('timeOffset')));
      expect(p.reportedPosition, Duration.zero);
      expect(p.count('seek'), 0);
    });

    test('initialPosition 不足 1s → timeOffset=1、余数进播放器', () async {
      final n = await boot();
      const resume = Duration(milliseconds: 1500);
      final p = await playSongOf(n, _song('s3'), initialPosition: resume);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(p.count('load'), 1, reason: '仍不得重拉');
      expect(p.loadedUris.single, contains('timeOffset=1'));
      expect(p.reportedPosition, const Duration(milliseconds: 500));
      expect(p.count('seek'), 0);
    });

    test('防回归：首载落位后手动 seek 到别处仍走全量重拉'
        '（守卫只拦同位置残留）', () async {
      final n = await boot();
      const resume = Duration(milliseconds: 90500);
      final p = await playSongOf(n, _song('s4'), initialPosition: resume);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      await n.seek(const Duration(seconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(p.count('load'), 2,
          reason: 'seek 到不同逻辑段必须全量重拉（管道流不可字节 seek）');
      expect(p.loadedUris.last, contains('timeOffset=150'));
      // 同上：重拉落位 150s + 起播后外推，容差断言。
      expect(
        (n.state.position - const Duration(seconds: 150)).inMilliseconds.abs(),
        lessThan(2000),
      );
    });
  });
}
