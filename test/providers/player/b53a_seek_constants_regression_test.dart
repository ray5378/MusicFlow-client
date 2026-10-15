// ignore_for_file: depend_on_referenced_packages

// b53a —— T08「seek 魔法数抽命名常量」的**行为回归护栏**。
//
// ─────────────────────────── 这个文件在守什么 ───────────────────────────
// T08 把 seek 路径上散落的 4 个魔法数抽成 lib/providers/player/player_seek.dart
// 顶部的**库内私有常量**（`player_provider.dart` 的 part 文件）：
//   * `_kSeekVerifyDelay  = 220ms` —— 落位后的稳定观察窗，之后才回读 position 判漂移
//   * `_kSeekRetryDelay   = 120ms` —— 漂移重试前 pause→seek→play 的收尾等待
//   * `_kSeekDriftToleranceMs = 2000` —— 漂移容忍阈值（毫秒）
//   * `_kSeekSettleWindow = 15s`  —— 落位宽限窗（写 `_seekSettleUntil`）
//
// 常量是库内私有，测试**无法直接 import**；日后有人改数值（或搬动调用点），
// 编译与既有用例都可能照绿，而行为已经变了。本文件用**行为边界**把其中三个
// 数值钉死（纯增量新增，不改 lib/ 一行，不改既有测试）。
//
// 逐条守什么 / 被改坏后的后果：
//   1) 漂移阈值 2000ms（非管道源 `_seekWithFallback` 裸 seek 分支）：回读的
//      `|实际 - 目标|` ≤2000ms 视为落位成功、**不**重试；>2000ms 才补一次温和
//      「pause→seek→play」原地重试。阈值被**改大** → just_audio 撒谎的漂移位置
//      会被当成功，「拖了从头播」再无兜底；被**改小** → 正常抖动被误判成失败，
//      每次拖动多下一次 seek（用户可感的迟滞/双 seek）。
//   2) 稳定观察窗 220ms：读回 position 判漂移前**必须先过观察窗**——既不能立即读
//      （会把解码器刚起播的抖动读成「seek 没生效」），也不能只有 120ms（那是重试
//      后的收尾等待，语义完全不同）。本组把 220ms 与 120ms / 0ms 区分开。
//   3) 宽限窗 15s：reload-stream 重拉成功后写 `_seekSettleUntil = now + 15s`，
//      期间不累加「0 秒卡死」计数、不计近末尾完成；source 前进过 1500ms 即**提前**
//      解除。改小 → 新源从余数(<1s)起步被误判成卡死 → reload→再犯则跳歌；
//      改大 → 真卡死被宽限窗拖住、自愈变迟。
//
// ─────────────────────────── 为什么这样测（稳定性策略） ───────────────────────────
// 常量私有 + mixin 内走**真墙钟**（不能用 fake_async：其假时钟与真实 Timer 会互相
// 喂饱挂死，既有 *_cov_test.dart 文件头已注明），故一律用「命令序列计数 + 墙钟下界」
// 这类黑盒判据，不追求逐毫秒：
//   * 2000 / 2001 边界：让平台替身的 `seek()` 广播一个**撒谎的**位置
//     （`seekReportOverride`，复用 b37a2 的后门），并把播放器置于暂停
//     （playing=false，just_audio 的 position 不外推）→ 回读值精确可控，两侧差异
//     即常量本身。
//   * 220ms：无「position getter 读取时刻」的直接钩子（读的是 just_audio 的字段，
//     不经过平台替身），故用**代理判据**——非重试路径下 `seek()` 全程耗时 ≥200ms
//     （该路径里唯一可能的等待就是 220ms 观察窗；120ms 会被下界排除）；重试路径下
//     首/次两次 seek 之间的间隔同样 ≈220ms（不是 0 / 不是 120）。
//   * 15s：直接经 `PlaybackPositionPollingHost` 暴露的公开 getter `seekSettleUntil`
//     断言（`PlayerNotifier` 自身实现了该窄接口）。
//
// 已由既有用例覆盖、本文件**不再重复硬凑**的部分见文末「未纳入项」。
//
// ─────────────────────────── 复用的既有 harness ───────────────────────────
//   * fake just_audio 平台 `_SeekFakePlayer` / `_SeekFakePlatform` 与容器装配、
//     boot/awaitPlayer/playSongOf/waitQuiet 流程：照搬
//     test/providers/player/b37a2_player_seek_drift_test.dart 的 44-233 / 260-364。
//     （`seekReportOverride` 后门见该文件 71-73 行；「seek 广播错误位置让 position
//     撒谎」的由来见 66-73 行注释。）
//   * 「非管道服务端（Navidrome）裸 seek 不做 timeOffset 重拉」的路由前提：
//     test/providers/player/player_seek_internals_cov_test.dart 五组 674-689；
//     路由判据本体见 test/providers/player/seek_reload_routing_test.dart 213-220。
//   * 「reload-stream 落位后 source 前进过 1500ms 自动解除宽限」的先例：
//     test/providers/player/b34a_pospoll_settle_test.dart 403-428。
import 'dart:async';

import 'package:dio/dio.dart';
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

// ─────────── just_audio 平台替身（复用 b37a2 那份，额外记录各次 seek 的墙钟） ───────────

class _SeekFakePlayer extends AudioPlayerPlatform {
  _SeekFakePlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  final List<String> calls = <String>[];
  final List<Duration?> seeks = <Duration?>[];

  /// 每次 `seek()` 下发的墙钟毫秒（用来量「两次 seek 之间的间隔」= 220ms 观察窗）。
  final List<int> seekTimesMs = <int>[];

  final List<String> loadedUris = <String>[];

  Duration reportedPosition = Duration.zero;
  Duration? reportedDuration = const Duration(seconds: 200);
  ProcessingStateMessage processingState = ProcessingStateMessage.idle;
  bool playing = false;

  /// `seek()` 后广播一个**错误的**位置，让 seek 后的 position 撒谎
  /// （b37a2 66-73：只靠「seek 不广播」不行，just_audio 自己会把乐观值压回目标）。
  Duration? seekReportOverride;

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
    seekTimesMs.clear();
    loadedUris.clear();
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    calls.add('load');
    final msg = request.audioSourceMessage;
    loadedUris.add(msg is UriAudioSourceMessage ? msg.uri : '<non-uri>');
    reportedPosition = request.initialPosition ?? Duration.zero;
    emit(state: ProcessingStateMessage.loading);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    emit(state: ProcessingStateMessage.ready);
    return LoadResponse(duration: reportedDuration);
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    calls.add('seek');
    seeks.add(request.position);
    seekTimesMs.add(DateTime.now().millisecondsSinceEpoch);
    reportedPosition = seekReportOverride ?? request.position ?? Duration.zero;
    emit(position: reportedPosition);
    return SeekResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
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

  // ═══════════════════════════════════════════════════════════════════════════
  // 一、漂移阈值 2000ms 边界（_kSeekDriftToleranceMs）
  //
  // 非管道服务端（Navidrome）走 `_seekWithFallback` 的**裸 seek + 漂移兜底**分支
  // （player_seek.dart 206-247）：seek → 等 220ms → 回读 `|实际-目标|` →
  // ≤2000 直接 return；>2000 才补一次原地重试。本组把「2000 这一整」钉死。
  // ═══════════════════════════════════════════════════════════════════════════
  group('一、漂移阈值 2000ms（_kSeekDriftToleranceMs）', () {
    // 目标 90s、回读 88s → 漂移恰好 2000ms（= 阈值，属容忍内）。
    test('回读漂移恰好 2000ms → 视为落位成功，不再补第二次 seek', () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 暂停：playing=false 时 just_audio 的 position 不按墙钟外推 → 回读值精确。
      await n.pause();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(p.playing, isFalse, reason: '前置：应已暂停，回读值才不会被墙钟外推污染');

      p.seekReportOverride = const Duration(milliseconds: 88000); // |88s-90s|=2000
      p.reset();

      final sw = Stopwatch()..start();
      await n.seek(const Duration(seconds: 90));
      sw.stop();

      expect(p.count('load'), 0,
          reason: '非管道服务端不做 timeOffset 重拉（分支前提，若为 1 说明走错了路）');
      expect(p.count('seek'), 1,
          reason: '漂移 2000ms 落在阈值内 → 绝不补第二次 seek');
      expect(n.state.position, const Duration(seconds: 90));

      // 稳定观察窗 220ms 的代理判据：非重试路径里唯一的等待就是它。
      // 下界 200ms 同时排除「立即读回(≈0)」与「120ms 收尾等待」。
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(200),
          reason: '落位后必须先过 ~220ms 稳定观察窗才回读判漂移');
      expect(sw.elapsedMilliseconds, lessThanOrEqualTo(800),
          reason: '观察窗不该被放大到数百 ms 以上（防常量被改大）');
    });

    test('回读漂移 1999ms（阈值内侧）→ 同样不重试（钉下界一侧）', () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.pause();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      p.seekReportOverride = const Duration(milliseconds: 88001); // 漂移 1999ms
      p.reset();

      await n.seek(const Duration(seconds: 90));

      expect(p.count('seek'), 1, reason: '1999ms 仍在 2000ms 容忍内 → 不重试');
    });

    test('回读漂移 2001ms（阈值外侧）→ 越过阈值，补一次原地重试（且不重拉）',
        () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.pause();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(p.playing, isFalse);

      p.seekReportOverride = const Duration(milliseconds: 87999); // 漂移 2001ms
      p.reset();

      await n.seek(const Duration(seconds: 90));

      expect(p.count('load'), 0, reason: '仍是源内温和重试，不重拉');
      expect(p.count('seek'), 2,
          reason: '漂移 2001ms > 2000ms → 必须恰好补一次原地重试');
      expect(p.seeks, <Duration?>[
        const Duration(seconds: 90),
        const Duration(seconds: 90),
      ], reason: '重试下发的是同一目标（源内坐标）');
      expect(n.state.position, const Duration(seconds: 90),
          reason: '对外仍是用户拖到的目标，不能被引擎撒谎的位置带跑');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 二、稳定观察窗 220ms（_kSeekVerifyDelay）
  //
  // 上一组的「重试耗时」已间接钉住 220ms；这里再用**两次 seek 之间的间隔**独立确认
  // 一次：重试链里第二次 seek 必然发生在「220ms 观察窗 + 回读判漂移」之后，而非
  // 立即（≈0）或只有 120ms（那是重试后的收尾等待，位置完全不同）。
  // ═══════════════════════════════════════════════════════════════════════════
  group('二、稳定观察窗 220ms（_kSeekVerifyDelay）', () {
    test('漂移重试的第二次 seek 距第一次 ≈220ms（不是 0、不是 120ms）', () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.pause();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      p.seekReportOverride = const Duration(milliseconds: 87999); // 漂移 2001ms
      p.reset();

      await n.seek(const Duration(seconds: 90));

      expect(p.seekTimesMs.length, 2);
      final gapMs = p.seekTimesMs[1] - p.seekTimesMs[0];
      expect(gapMs, greaterThanOrEqualTo(200),
          reason: '两次 seek 之间必须是 ~220ms 观察窗；排除「立即重试(≈0)」与 120ms');
      expect(gapMs, lessThanOrEqualTo(800),
          reason: '间隔不该被放大到数百 ms 以上（防常量被改大）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 三、落位宽限窗 15s（_kSeekSettleWindow）
  //
  // MusicFlow（管道化服务端）的 seek 走 reload-stream（player_seek.dart 双 seek 分支
  // → `_reloadStreamForSeek`），落位时写 `_seekSettleUntil = now + 15s`（源码 294）。
  // 经宿主窄接口的公开 getter `seekSettleUntil` 断言；并验证「source 前进过 1500ms
  // 即提前解除」这条**不被破坏**（轮询驱动第 229-237 行）。
  // ═══════════════════════════════════════════════════════════════════════════
  group('三、落位宽限窗 15s（_kSeekSettleWindow）', () {
    test('reload-stream 落位后 _seekSettleUntil 被钉到 now+15s', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(n.seekSettleUntil, isNull, reason: '起播阶段不该有宽限（_clearStreamContext 已清）');

      await n.seek(const Duration(seconds: 90));
      expect(p.count('load'), greaterThanOrEqualTo(2),
          reason: 'MusicFlow 管道化 → seek 必须整源重拉（落位才会置宽限）');

      final until = n.seekSettleUntil;
      expect(until, isNotNull, reason: 'reload-stream 落位后必须写入宽限窗');

      // 置位时刻 ≈ seek 期间；读回时已过 ~220ms 观察窗 → 余量略小于 15s。
      // 用区间把「15s」钉死：改成 10s（余≈9.8s）或 20s（余≈19.8s）都会判失败。
      final remainMs = until!.difference(DateTime.now()).inMilliseconds;
      expect(remainMs, greaterThanOrEqualTo(13000), reason: '宽限窗被改小 → 提前解除');
      expect(remainMs, lessThanOrEqualTo(15500), reason: '宽限窗被改大 → 真卡死被拖住');
    });

    test('source 前进过 1500ms → 宽限窗提前解除（不被破坏）', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.seek(const Duration(seconds: 90));
      expect(n.seekSettleUntil, isNotNull, reason: '前置：落位已置宽限');

      // 让源位置前进到 5s（>1500ms）→ 下一次轮询 tick 内自动解除宽限。
      p.emit(position: const Duration(seconds: 5));
      var cleared = false;
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (n.seekSettleUntil == null) {
          cleared = true;
          break;
        }
      }

      expect(cleared, isTrue,
          reason: 'source 前进过 1500ms 必须提前解除宽限（否则真进度的 seek 被一直宽限）');
      expect(n.seekSettleUntil, isNull);
    });
  });
}

// ───────────────────────────── 未纳入项（避免硬凑） ─────────────────────────────
//
// * `_kSeekRetryDelay = 120ms`（重试链里 pause→seek→play 之后的收尾等待）：
//     它出现在**重试之后**，且不改变任何可观测的对外状态（只影响「重试后收尾」的
//     时长，无对外命令）。要在 `seek()` 全程耗时里把它与 220ms 拆开断言，需要引入
//     逐毫秒时序，属墙钟依赖、易抖；而重试链本身的**存在性**已由第一组
//     「2001ms → 补一次 seek」钉死（那就是 120ms 存在的意义所在）。故不再单独硬凑。
// * 「220ms 观察窗内 position getter 的**读取时刻**」：读的是 just_audio 的字段
//     （`AudioPlayer.position`），不经过平台替身，本 harness 无直接钩子；已用
//     「非重试路径全程耗时 ≥200ms」+「两次 seek 间隔 ≈220ms」两个代理判据替代。
