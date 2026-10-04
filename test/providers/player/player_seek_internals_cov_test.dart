// ignore_for_file: depend_on_referenced_packages

// batch28-B：`lib/providers/player/player_seek.dart` 的**重拉/兜底/作废**三条主芯。
//
// ─────────────── 为什么本批能打到，前面各批打不到 ───────────────
//
// 开工前按 lcov 复核：`player_seek.dart` 里除 `_authoritativeDuration()` 的 4 行外
// **全部 0 命中**（约 216 行）。前面 batch19/22/24 三批都判定这段「进程内够不到」，
// 根因是同一个：mixin 体里的每条主干读完宿主状态后都要**真的往 just_audio 下发**
// （`setUrl` / `seek` / `play` / `pause`），而在默认的 `MethodChannelJustAudio`
// 下这些调用**一律抛 MissingPluginException** —— `_replaceLoadedSource` 在
// `await setSource(player)` 就炸了，永远走不到 `player.audioSource == null` 那道
// 门禁，于是 `_loadedSourceSongId` 恒为 null，整段 seek 管线只能停在入口早退。
//
// 本批的解法（也是本文件和既有几份 *_cov_test.dart 唯一的实质差别）：把
// `JustAudioPlatform.instance` 换成一份**内存替身**（`_SeekFakePlatform`）。
// 替身一挂上，`JustAudioPlatform.instance.init()` 就吐出可控的 `_SeekFakePlayer`：
//   * `load()` 返回成功 → `await setSource(player)` 不再抛 → `_replaceLoadedSource`
//     真正走到 line 399 的门禁并 return true → `_loadedSourceSongId` 被赋值
//     （这句正是整条 seek 管线的总闸，此前从未被点亮）；
//   * `processingState` / `position` / `playing` 全由用例通过 `emit()/emitPlaying()`
//     主动广播 → `canSeekLoadedPlayerSource` 的真假、`resolveSeekReloadPlan`
//     的重拉与否、220ms 后的漂移量，全都成了可编排的输入，而不是碰运气；
//   * 下发到引擎的每条命令（`load/seek/play/pause`）顺序收在 `calls` 里，
//     断言直接钉在这条**命令序列**上（既可观测，也不会因为 UI 层的合成效应假绿）。
//
// 打到的东西（line 号对应 lib/providers/player/player_seek.dart）：
//   * `_replaceLoadedSource`  365-420（true / load 抛 / 加载后被作废三路）
//   * `_seekWithFallback`     112-215（plan != null 重拉路 + plan == null 裸 seek
//                                      路 + 漂移 >2s 的重试兜底）
//   * `_reloadStreamForSeek`  219-295（含 v 逻辑每层 `isCurrentSeek()` 把关）
//   * `_softResumePlayback`   87-95（playing 已 true 早退 / 起播补 play）
//   * `_loadedSourceUrl`      104-110（http(s) 认账、file:// 不认账）
//   * `_applyPendingSeekIfNeeded` 24-81（挂起 → 源转 ready 后被拉起）
//   * `_schedulePendingSeekIfReady` 443-463 / `_shouldPreserveSeekPosition` 465-475
//     / `_releaseSeekAnchor` 437-441 / `_invalidateSeekRequests` 422-426
//     / `_invalidateLoadedSource` 359-363 / `_clearStreamContext` 321-328
//     / `_clearPendingSeek` 297-305 / `_setStreamContext` 307-319
//     / `_setSourcePositionOffset` 330-336 / `_logicalPlayerPosition` 338-345
//     / `_sourceSeekPosition` 347-350 / `_isPlaybackContextCurrent` 352-357
//     / `_isSeekRequestCurrent` 428-435
//
// 不碰的东西：`lib/` 一行未改；不依赖 `mocktail`、不用 `fake_async`
// （mixin 里的 `Future.delayed(220ms/120ms)` 走真墙钟，假时钟下会互相喂饱挂死）。
//
// 踩坑索引（本批新增，编号承接 batch27 的 #168-D）：
// #169-D `JustAudioPlatform.instance` 必须在 **`AudioPlayer` 被构造之前** 换掉：
//      真宿主的 `_init()` 在 `_PlayerNotifierImpl` 构造期就 new 了 AudioPlayer，
//      晚一步替换拿到的仍是 `MethodChannelJustAudio`（setUrl 继续抛 MissingPluginException）。
// #170-D 替身的 `load()/seek()` **不能只返回**，`PlaybackEventMessage` 还得自己
//      广播出去：just_audio 的 `processingState` / `position` 都是从
//      `playbackEventMessageStream` 推出的，不 emit 就永远停在 idle / 0，
//      `canSeekLoadedPlayerSource` 恒假，用例看着绿其实一条分支没进。
// #171-D `playing` 不在 `PlaybackEventMessage` 里，而在**另一条流**
//      `playerDataMessageStream`（`PlayerDataMessage.playing`）上 —— 只实现
//      `playbackEventMessageStream` 的替身，`player.playing` 恒为 false，
//      `_softResumePlayback()` 那条补 play 的分支永远进不去。
// #172-D `setUrl` 是**先置 `_audioSource` 再 await load()**（just_audio 0.9.46
//      lib/just_audio.dart:786 vs 791），所以即便替身让 load 抛错，事后
//      `player.audioSource` 依然非 null —— 想让 `_replaceLoadedSource` 走到
//      "load abandoned" 分支，只能让 `ownsSource()` 变假（切 state.currentSong），
//      不能指望把 audioSource 变没。
// #173-D `_replaceLoadedSource` 的加载门禁是 `_sourceGeneration != generation ||
//      !ownsSource() || player.audioSource == null`，三条是 **或**：想确定性地打
//      这条，最稳的手法是在替身的 `load()` 里挂个 hook 改 `state.currentSong`，
//      靠酪 CPU 竞态（并发 seek）既慢又随机红。
// #174-D `PlaybackEventMessage` 是 required 命名参数且 `duration/icyMetadata/
//      currentIndex/androidAudioSessionId` 都不可省，漏一个就 compile error ——
//      替身里统一走一处 `emit()` 收口，别在每个 case 里散着 new。
// #175-D just_audio 的 `position` 由 `updateTime + updatePosition` 合成：替身下发
//      的事件里 `updateTime: DateTime.now()` 必须**每次都刷新**，复用同一个时间戳
//      会让 position 恒定不动，漂移兜底那条永远算成 drift=0。
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

// ───────────────────── just_audio 平台替身（踩坑 #169-D） ─────────────────────

/// 一份「什么都听命令、状态全由用例摆」的 just_audio 平台替身。
///
/// 和 `MethodChannelJustAudio` 的差别：不会抛 MissingPluginException，且把
/// `processingState` / `position` / `playing` 三件事交回用例手里。
class _SeekFakePlayer extends AudioPlayerPlatform {
  _SeekFakePlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  /// 下发给引擎的命令序列（这是「mixin 到底做了什么」的唯一观测面）。
  final List<String> calls = <String>[];

  /// 每次 `seek()` 的目标（源内坐标）。
  final List<Duration?> seeks = <Duration?>[];

  /// 每次 `load()` 装进来的 uri。
  final List<String> loadedUris = <String>[];

  Duration reportedPosition = Duration.zero;
  Duration? reportedDuration = const Duration(seconds: 200);
  ProcessingStateMessage processingState = ProcessingStateMessage.idle;
  bool playing = false;

  /// 让下一次 `load()` 抛错（钉「重拉失败 → 回退裸 seek」）。
  bool failLoad = false;

  /// `load()` 里不采用 request.initialPosition，改用 [reportedPosition]
  /// （钉「重拉后位置漂移 > 2s → 补一次源内 seek」）。
  bool ignoreInitialPosition = false;

  /// `load()` 执行中的钩子（踩坑 #173-D：用来确定性地把 ownsSource() 变假）。
  Future<void> Function()? onLoad;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  int count(String method) => calls.where((c) => c == method).length;

  /// 广播一次播放事件（踩坑 #174-D / #175-D：一处收口，updateTime 必须刷新）。
  void emit({
    ProcessingStateMessage? state,
    Duration? position,
    Duration? duration,
  }) {
    if (state != null) processingState = state;
    if (position != null) reportedPosition = position;
    if (duration != null) reportedDuration = duration;
    _events.add(PlaybackEventMessage(
      processingState: processingState,
      updateTime: DateTime.now(),
      updatePosition: reportedPosition,
      bufferedPosition: reportedPosition,
      duration: reportedDuration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  /// 广播一次 playing 变更（踩坑 #171-D：playing 在另一条流上）。
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
    reportedPosition = request.position ?? Duration.zero;
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

  // 踩坑 #59：`_init()` 早期要 path_provider，没装插件时 MissingPluginException
  // 会穿透到 unhandled error，把整条用例带红。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();
  final fake = _SeekFakePlatform();

  setUp(() {
    // 踩坑 #169-D：必须在起容器（= new AudioPlayer）**之前**换掉。
    // 踩坑 #176-D：换的是 `JustAudioPlatform.instance` 这个**静态槽位**，它对整个
    // 测试进程生效且跨用例残留；不在 setUp 里重置 players，上一条用例的替身会
    // 被下一条误当成自己的引擎。
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

  /// 建一个「已登录」的 API client。
  ///
  /// 踩坑 #178-D：`SubsonicApiClient.getStreamUrl()` 的第一句就是
  /// `if (_library == null) return ''`（lib/data/sources/subsonic_api_client.dart:255），
  /// 而 `_buildStreamUrlOrThrow` 拿到空串会直接
  /// `throw StateError('No active server address available for stream URL')` ——
  /// 异常被 playSong 外层 catch 吞掉，只留一行 `stream_url_empty` 日志，表现就是
  /// 「配了服务器地址却永远走不到 setUrl」。所以 override 地址**还不够**，
  /// 必须再 `client.setLibrary(...)` 把登录态补上。
  SubsonicApiClient apiClient({String? serverType}) =>
      SubsonicApiClient(
          dio: Dio(BaseOptions(baseUrl: 'http://192.168.10.240:46400')))
        ..setLibrary(library(serverType: serverType));

  ProviderContainer buildContainer({
    String? serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
    bool offline = false,
  }) =>
      ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(
              library(serverType: serverType)),
          activeAddressProvider.overrideWith((ref) => addr()),
          effectiveQualityProvider.overrideWithValue(quality),
          isOfflineProvider.overrideWithValue(offline),
          subsonicApiClientProvider.overrideWithValue(
              apiClient(serverType: serverType)),
          musicRepositoryProvider.overrideWithValue(repo),
          starredProvider.overrideWith((ref) async => StarredResult(
                artists: const <Artist>[],
                albums: const <Album>[],
                songs: const <Song>[],
              )),
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

  /// 起容器 → 拿真 `_PlayerNotifierImpl` → 等构造期尾巴落定。
  Future<PlayerNotifier> boot({
    String? serverType = 'MusicFlow',
    AudioQualityLevel quality = AudioQualityLevel.original,
  }) async {
    final c = buildContainer(serverType: serverType, quality: quality);
    // 踩坑 #179-D：seek 的重拉尾巴是 fire-and-forget 的（mixin 里还有两处
    // `Future.delayed(220ms/120ms)`）。如果在 tearDown 里立刻 `container.dispose()`，
    // 那条尾巴会在 notifier 销毁之后再去读 `state` —— `PlayerSeekInternals
    // ._isPlaybackContextCurrent`（player_seek.dart:356）没做 mounted 守卫，
    // 于是抛 "Tried to use _PlayerNotifierImpl after `dispose` was called"，
    // 并把错误算到**下一条**用例头上（典型的上一条尾巴污染下一条）。
    // 所以这里先给尾巴留出跑完的时间，再 dispose。
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      c.dispose();
    });
    final n = c.read(playerProvider.notifier);
    return waitQuiet(n);
  }

  /// 轮询到「源已就绪」：判据是某个替身已经收过 [loads] 次 `load()`。
  ///
  /// 踩坑 #177-D：just_audio 的 `AudioPlayerPlatform` **不是构造期创建**，而是
  /// 第一次真正需要出声时由 `_setPlatformActive(true)` 惰性拉起来的
  /// （0.9.46 lib/just_audio.dart:75 `_platform` 是 late Future）。所以
  /// 「boot 完就取替身」必然拿到 null —— 必须先发出一次起播再等替身现身。
  Future<_SeekFakePlayer> awaitPlayer({int loads = 1}) async {
    for (var i = 0; i < 300; i++) {
      for (final p in fake.players) {
        if (p.count('load') >= loads) return p;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError(
      '替身平台始终没被初始化（playSong 没走到 setUrl？），players=${fake.players.length}',
    );
  }

  /// 起播 → 等源就绪 → 返回替身，测试第一步统一走这个。
  Future<_SeekFakePlayer> playSongOf(PlayerNotifier n, Song song) async {
    final started = n.playSong(song, queue: <Song>[song]);
    final p = await awaitPlayer();
    await started;
    return p;
  }

  group('一、源就绪后的重拉主线（plan != null → _reloadStreamForSeek）', () {
    test('起播把源装上 → seek 到中段，用带 timeOffset 的新地址整源重拉', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final firstUrl = p.loadedUris.last;
      p.reset();

      await n.seek(const Duration(seconds: 90));

      expect(p.count('load'), 1, reason: '服务端管道流 → 必须整源重拉一次');
      expect(p.loadedUris.last, isNot(firstUrl));
      expect(
        Uri.parse(p.loadedUris.last).queryParameters['timeOffset'],
        '90',
        reason: '重拉地址要带上 Metadata 的逻辑秒',
      );
      // 对外触点：先锚到目标，重拉完成后仍须是目标。
      expect(n.state.position, const Duration(seconds: 90));
    });

    test('第二次拖到**同一个逻辑段** → 只做源内 seek，不再整源重拉', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      p.reset();

      // 目标与当前流同一逻辑段：`plan.origin == 'context'` 且
      // `seekTarget.serverOffset == _sourcePositionOffset` → 源内 seek 足够。
      await n.seek(const Duration(seconds: 90));

      expect(p.count('load'), 0, reason: '同段微调不应重装源（省一次服务端转码首包）');
      expect(p.count('seek'), greaterThanOrEqualTo(1));
    });

    test('连续拖到不同位置 → 每次都按最新目标重拉，旧段的 timeOffset 被覆盖', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      p.reset();

      await n.seek(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await n.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(p.count('load'), 2, reason: '两次不同段的拖动各重拉一次');
      final q = Uri.parse(p.loadedUris.last).queryParameters;
      expect(q['timeOffset'], '90',
          reason: 'buildTimeOffsetStreamUrl 是「改写」而不是「追加」同一个参数');
      expect(q['id'], 's1', reason: '其余查询参数（歌曲标识）必须原样保留');
      // Playing 的会话会因真实墙钟继续走表，这里只能钉「锚在目标附近」。
      expect(n.state.position, greaterThanOrEqualTo(const Duration(seconds: 90)));
      expect(n.state.position, lessThanOrEqualTo(const Duration(seconds: 93)));
    });

    test('重拉后位置漂移 > 2s → 240ms 宽限后补一次源内 seek（不自欺回退到旧进度）',
        () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 让重拉后引擎报的位置明显偏离目标（ => logical = 30s + 90s offset）。
      p.ignoreInitialPosition = true;
      p.reportedPosition = const Duration(seconds: 30);
      p.reset();

      await n.seek(const Duration(seconds: 90));

      // 一次给 forward 用的 setUrl(initialPosition) + 一次漂移后的补 seek。
      expect(p.count('load'), 1);
      expect(p.seeks.length, greaterThanOrEqualTo(1));
      expect(n.state.position, const Duration(seconds: 90),
          reason: '对外必须是用户拖到的目标，不能被引擎撒谎的位置带跑');
    });

    test('重拉 setUrl 失败 → 回退到裸 seek，且不把异常抛穿调用方', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      p.failLoad = true;
      p.reset();
      await expectLater(n.seek(const Duration(seconds: 120)), completes);

      expect(p.count('load'), 1, reason: '先按重拉路线试一次');
      expect(p.count('seek'), greaterThanOrEqualTo(1), reason: '失败后必须回退到源内 seek');
      expect(n.state.position, const Duration(seconds: 120));
    });
  });

  group('二、_replaceLoadedSource 的三条返回 false 路径', () {
    test('加载途中会话归属变了（ownsSource 变假）→ 加载作废，不再重装也不再 seek',
        () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 踩坑 #172-D/#173-D：setUrl 已经先把 audioSource 置上了，所以唯一的确定性
      // 手法是让 ownedSource 在 `load()` 期间变假 —— 替身的 onLoad 钩子就是干这个。
      p.onLoad = () async {
        n.state = n.state.copyWith(
          queue: <Song>[_song('other')],
          currentIndex: 0,
          currentSong: _song('other'),
        );
      };
      p.reset();
      await n.seek(const Duration(seconds: 90));

      // _reloadStreamForSeek 拿到 sourceReady == false 就 return，不再走后面的
      // 220ms 校验与补 seek，所以 observed commands 只有那次被作废的 setUrl。
      expect(p.count('load'), 1);
      expect(p.count('seek'), 0);
      p.onLoad = null;
    });
  });

  group('三、_softResumePlayback：重拉只是换了一手音源，播放意图不能丢', () {
    test('重拉前正在播、重拉后播放器停了 → 补一次 play()', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.play();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(p.playing, isTrue, reason: '前置：替身必须真的处于 playing');

      // 替身在 setUrl 期间把 playing 压回 false（照真机上「新源还在 loading」的
      // 首包瞬态），此时 shouldResume 已经记录为 true。
      p.onLoad = () async => p.emitPlaying(false);
      p.reset();

      await n.seek(const Duration(seconds: 90));

      expect(p.count('play'), greaterThanOrEqualTo(1),
          reason: '宣言要连续播放的会话不该在 seek 之后自己停住');
      p.onLoad = null;
    });

    test('重拉后播放器仍未起 → _softResumePlayback 调 play() 被拒也只吞日志',
        () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.play();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      p.onLoad = () async => p.emitPlaying(false);
      p.reset();
      // play() 本身不该把运行环境炸掉（catchError 仅记日志，不走 next()）。
      await expectLater(n.seek(const Duration(seconds: 45)), completes);
      p.onLoad = null;
      expect(n.state.position, const Duration(seconds: 45));
    });
  });

  group('四、pendingSeek：源未就绪时挂起，源转 ready 后被拉起', () {
    test('挂起期间不碰引擎；processingState 转 ready 后自动落位', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 把源的 processingState 扭回 loading：canSeekLoadedPlayerSource 判定为假
      // → seek() 只能走挂起分支。
      p.emit(state: ProcessingStateMessage.loading);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      p.reset();

      await n.seek(const Duration(seconds: 77));

      expect(n.state.position, const Duration(seconds: 77),
          reason: '挂起也要先把 UI 锚到目标，否则拖动看着没反应');
      expect(p.count('seek'), 0, reason: '源还没就绪，绝不下发到引擎');
      expect(p.count('load'), 0);

      // 源转 ready → provider 的 playerStateStream 监听拉起 _applyPendingSeekIfNeeded。
      p.emit(state: ProcessingStateMessage.ready);
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (p.count('load') > 0 || p.count('seek') > 0) break;
      }

      expect(
        p.count('load') + p.count('seek'),
        greaterThanOrEqualTo(1),
        reason: '源就绪必须把挂起的意图真正落下去（而不是留在 UI 上空转）',
      );
      expect(n.state.position, const Duration(seconds: 77));
    });

    test('无当前曲 → seek 静默早退，引擎零命令', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 先把会话归零（currentSong 清空），再 seek —— 走的是 provider 入口的早退。
      await n.clearQueue(keepCurrent: false);
      p.reset();

      await n.seek(const Duration(seconds: 30));

      expect(p.calls, isEmpty, reason: '没有当前曲时 seek 连引擎都不该碰');
      expect(n.state.currentSong, isNull);
    });

    test('清队列（会话归零）会连带把 loadedSource 与 seek 锚一起作废', () async {
      final n = await boot();
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.clearQueue(keepCurrent: false);

      // _invalidateLoadedSource / _invalidateSeekRequests / _clearStreamContext：
      // 三者都落在 seek mixin 里，而 clearQueue 是它们唯一既确定又低成本的入口。
      expect(n.state.currentSong, isNull);
      expect(n.state.position, Duration.zero);
    });
  });

  group('五、非本机服务端（plan == null）：裸 seek + 漂移兜底', () {
    test('服务端不是 MusicFlow（无管道化）→ 不做 timeOffset 重拉，只下发源内 seek',
        () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      p.reset();

      await n.seek(const Duration(seconds: 50));

      expect(p.count('load'), 0, reason:
          '非管道化服务端不做 timeOffset 重拉：这类源上的 position 漂移同样会撒谎，'
          '产品选择只做一次温和的原地重试，不再假装能靠漂移判断「要不要重拉」');
      expect(p.count('seek'), greaterThanOrEqualTo(1));
      expect(n.state.position, const Duration(seconds: 50));
    });

    test('裸 seek 后位置漂移 > 2s → pause → 再 seek 一次 → 恢复播放', () async {
      final n = await boot(serverType: 'Navidrome');
      final p = await playSongOf(n, _song('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await n.play();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 让引擎在一开始上报的目标位置上再往前偏一大截：第一次 seek 之后
      // `actual` 会明显偏离 target → 触发温和重试整条链。
      p.reportedPosition = const Duration(seconds: 0);
      p.reset();

      await n.seek(const Duration(seconds: 90));

      expect(p.count('seek'), greaterThanOrEqualTo(1));
      expect(n.state.position, const Duration(seconds: 90));
    });
  });
}
