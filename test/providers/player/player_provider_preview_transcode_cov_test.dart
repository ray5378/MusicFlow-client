// batch28-A2：lib/providers/player/player_provider.dart 的**试听起播链路**与
// **转码降级重试链路**（源码 1285-1423 `_playWithTranscoding`、
// 1604-1760 `_playPreviewSongInternal` / `_resolvePreviewSongForPlayback`，
// 外加 part 文件 `player_platform_helpers.dart` 的 `resolvePreviewPlaybackQueue`）。
//
// 选段依据：对现有 5 个 player_provider 测试文件（cov / playback / queue /
// cast_session / completion，共 166 例全绿）跑了一次合并覆盖率
// （`flutter test --coverage --coverage-path=/tmp/b28a2_lcov.info`，不写仓库
// coverage/），按「连续未覆盖段 >= 6 行」排序，最大的两块就是：
//   ① player_provider.dart:1256-1423（65 行）—— 转码降级重试
//   ② player_provider.dart:1643-1768（61 行）—— 试听起播
// 这两块正好分别是「播放失败之后的第二条命」和「试听这条完全独立的起播链路」，
// 之前各批都只从外部擦到边、没有真正走进去过。
//
// 难点与解法：
//   * 两条链路都卡在 `_refreshRoutesAndCheckAvailability()`（源码 2306）这个
//     「有没有可用线路」的判定上。它读 `addressPoolProvider`，真身会去真探测。
//     本批用 `_FakeAddressPool extends AddressPool` 把 `probeAll()` 换成可控返回，
//     于是「有线路 → 自动跳下一首」和「无线路 → 只排重连重试」两侧都能钉。
//   * 试听链路的 URL 解析（`_resolvePreviewSongForPlayback`）默认要打
//     `gdMusicApiClientProvider`；但只要 `song.previewStreamUrl` 非空且不在会话
//     恢复中，它就**直接复用原 song、一个网络请求都不发** —— 这是最干净的入口。
//   * 转码链路由「直连失败」触发：`_needsTranscoding('flac') == null`（flac 不在
//      universallyUnsupported / androidUnsupported 两张表里），所以 flac 曲在直连
//      失败后一定会走 `_playWithTranscoding(format: 'mp3', maxBitRate: 320)`。
//      把替身客户端的 `getStreamUrl` 做成「按次返回」的脚本，第一次吐非法 URL
//      （Uri.parse 抛 FormatException ⇒ setUrl 失败），第二次吐合法 URL，
//      就能把整条转码重试链路走通。
//
// 姿势沿用 batch28-A 的「真 notifier + 替身 just_audio 平台」（见
// player_provider_completion_cov_test.dart 的 #169-D ~ #178-D），这里只写本批新踩的。
//
// 踩坑索引（接 #178-D）：
// #179-D 试听曲的起播**完全不经过** `getStreamUrl`：`playSong` 在 918 行就
//      `if (song.isPreview) → _playPreviewSongInternal → return`。所以「试听链路」
//      与「正式链路」可以用 `spy.streamUrlCalls` 是否为空来**干净地分开**断言。
// #180-D `_resolvePreviewSongForPlayback` 在 `previewStreamUrl` 非空且
//      `_isRestoringPlaybackSession == false` 时直接返回原 song（不发网络）。
//      所以 boot 之后必须等 `debugIsRestoringPlaybackSession` 落 false 再打，
//      否则会走「强制重解析」那条路，需要 override `gdMusicApiClientProvider`。
// #181-D 试听解析失败（1621-1637）时 `state` **还没被写成试听队列**（state.copyWith
//      在 1681 行、解析之后），所以注释里强调的「不能走 _handlePlaybackError、
//      只能在本队列内就地跳转」是对的 —— 断言别去钉 `state.currentSong`，
//      要钉「跳到了下一首 / 一个 load 都没发」。
// #182-D `_refreshRoutesAndCheckAvailability` 读 `addressPoolProvider`，而
//      `_syncImmediateActiveAddress`（player_stream_source.dart:104）也读它：
//      `pool.activeAddress ?? _ref.read(activeAddressProvider)`。替身池必须把
//      `activeAddress` 也 override 成 null，否则起播地址会被池子顶掉。
// #183-D 转码重试里 `_handlePlaybackError` → `next()` 在**单曲队列 + all 模式**
//      下会 `skipToQueueItem(0)` 再起播一次 → 无限连跳。要让它停住，必须先把
//      `playbackMode` 摆成 `order`（next() 尾部的「到末尾即停」，源码 2096）。
// #185-D 桌面端 `AudioPlayer` 默认 `useProxyForRequestHeaders: true`：试听那种
//      「带自定义 headers 的远程流」会被 rewrite 成 `http://127.0.0.1:<随机端口>/<原 path>`
//      再交给平台。**不要**拿完整 URL 做断言，只能钉 path（或前缀 127.0.0.1）。
//      正式链路（不带 headers 的 `setUrl`）不受影响，仍是原样 URL。
// #184-D 直连失败时 `_needsTranscoding(song.suffix) == null` 才进转码重试；
//      'flac' 满足（不在两张不支持表内），'ape' 不满足（在 universallyUnsupported
//      里，直连时就已经转过码了）。选后缀要注意，别选错档。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
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
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/player_state.dart';

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
    // 踩坑 #170-D：不吐 ready，`setUrl()` 会永久挂在等 processingState 离开 loading。
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
  int initCount = 0;
  _FakeAudioPlayerPlatform? last;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    initCount += 1;
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

/// 默认占位：Dart 的默认参数值不能引用同函数的其他参数，所以「按 id 拼一个
/// 预览地址」只能在函数体里做，用一个哨兵串区分「不传」和「显式传 null」。
const String _autoPreviewUrl = '__auto_preview_url__';

/// 造一首**试听曲**。
///
/// [streamUrl] 非空时 `_resolvePreviewSongForPlayback` 直接复用、不走网络
/// （踩坑 #180-D）；为 null 且 source/trackId 也为空时会抛 StateError。
Song _preview(
  String id, {
  String? streamUrl = _autoPreviewUrl,
  String? source,
  String? trackId,
  Map<String, String> headers = const <String, String>{},
  int? bitRate = 128,
  int duration = 30,
}) =>
    Song(
      id: id,
      title: '试听$id',
      artist: '试听歌手',
      albumId: 'al1',
      suffix: 'm4a',
      bitRate: bitRate,
      duration: duration,
      isPreview: true,
      previewStreamUrl:
          streamUrl == _autoPreviewUrl ? 'https://cdn.example.test/track/$id.m4a' : streamUrl,
      previewSource: source,
      previewTrackId: trackId,
      previewRequestHeaders: headers,
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

/// 按次脚本化的 Subsonic 客户端替身。
///
/// [streamUrls] 里的值按顺序返回，用尽后一直返回最后一个 —— 这样「第一次直连
/// 失败、第二次转码重试成功」这类时序可以被精确编排。
class _ScriptedSubsonicApiClient extends SubsonicApiClient {
  _ScriptedSubsonicApiClient()
      : super(dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')));

  final List<String> getPaths = <String>[];
  final List<String> streamUrlCalls = <String>[];
  List<String> streamUrls = <String>[
    'http://192.168.10.240:46400/rest/stream?id=s1',
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    getPaths.add(path);
    return <String, dynamic>{};
  }

  @override
  String getStreamUrl(
    String songId, {
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) {
    streamUrlCalls.add('$songId|format=$format|maxBitRate=$maxBitRate');
    if (streamUrls.isEmpty) return '';
    if (streamUrls.length == 1) return streamUrls.first;
    return streamUrls.removeAt(0);
  }
}

/// 地址池替身（踩坑 #182-D）：把「有没有可用线路」变成可控开关。
class _FakeAddressPool extends AddressPool {
  _FakeAddressPool()
      : super(Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')));

  bool routeAvailable = true;

  /// 非空时按序弹出，用来编排「第一次探测有线路、第二次没有」这种时序
  /// （转码重试的失败兜底要在**第二次**判定时才断线）。
  List<bool> probeResults = const <bool>[];

  @override
  ServerAddress? get activeAddress => null;

  bool get _nextOk {
    if (probeResults.isEmpty) return routeAvailable;
    return probeResults.removeAt(0);
  }

  @override
  Future<ServerAddress?> probeAll() async => _nextOk
      ? ServerAddress(
          id: 'a1',
          libraryId: 'lib1',
          label: '主库',
          url: 'http://192.168.10.240:46400',
          priority: 0,
          status: ServerAddressStatus.ok,
        )
      : null;
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
  final spy = _ScriptedSubsonicApiClient();
  final pool = _FakeAddressPool();
  late _FakeJustAudioPlatform platform;

  ServerAddress _addr() => ServerAddress(
        id: 'a1',
        libraryId: 'lib1',
        label: '主库',
        url: 'http://192.168.10.240:46400',
        priority: 0,
      );

  MusicLibrary _library() => MusicLibrary(
        id: 'lib1',
        name: '主库',
        serverType: 'MusicFlow',
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  ProviderContainer buildContainer() => ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
          isOfflineProvider.overrideWithValue(false),
          subsonicApiClientProvider.overrideWithValue(spy),
          musicRepositoryProvider.overrideWithValue(repo),
          offlineCacheDaemonProvider.overrideWith(
            (ref) => _NoopOfflineCacheDaemon(ref),
          ),
          addressPoolProvider.overrideWithValue(pool),
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

  Future<void> waitUntil(bool Function() cond, {int ticks = 250}) async {
    for (var i = 0; i < ticks; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  late ProviderContainer container;
  late PlayerNotifier notifier;

  Future<PlayerNotifier> boot({bool routeAvailable = true}) async {
    pool.routeAvailable = routeAvailable;
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    container = buildContainer();
    final n = container.read(playerProvider.notifier);
    await waitQuiet(n);
    return n;
  }

  /// 等替身平台被激活（踩坑 #172-D：没加载过音源时 `init()` 不会被调）。
  Future<void> waitLoaded([int count = 1]) =>
      waitUntil(() => (platform.last?.loadCount ?? 0) >= count);

  List<String> ids(List<Song> q) => q.map((s) => s.id).toList();

  setUp(() {
    spy.getPaths.clear();
    spy.streamUrlCalls.clear();
    spy.streamUrls = <String>[
      'http://192.168.10.240:46400/rest/stream?id=s1',
    ];
    pool.routeAvailable = true;
    pool.probeResults = const <bool>[];
  });

  tearDown(() => container.dispose());

  // ─────────────────── 一、试听起播主链路（源码 1604-1730） ───────────────────
  group('_playPreviewSongInternal · 试听起播主链路', () {
    test('带 previewStreamUrl 的试听曲：复用既有 URL、不走 getStreamUrl', () async {
      // 踩坑 #179-D：试听链路和正式链路在 918 行就分叉了，
      // `spy.streamUrlCalls` 为空是「确实走的试听分支」的强断言。
      notifier = await boot();
      final song = _preview(
        'p1',
        headers: const <String, String>{'Referer': 'https://x.example.test'},
      );

      await notifier.playSong(song, queue: <Song>[song], index: 0);
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(spy.streamUrlCalls, isEmpty,
          reason: '试听 URL 由 previewStreamUrl 直接给出，不该再走一次 getStreamUrl');
      // 踩坑 #185-D：桌面端 just_audio 默认 `useProxyForRequestHeaders: true`，
      // 试听流会被改写成本机临时代理地址（端口随机），只有 path 原样保留。
      expect(platform.last!.loadedUris.single, startsWith('http://127.0.0.1:'));
      expect(platform.last!.loadedUris.single, endsWith('/track/p1.m4a'));
      expect(notifier.state.currentSong?.id, 'p1');
      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
      // autoPlay 默认 true ⇒ _syncPlaybackAfterSourceReady 会真的 play()。
      expect(platform.last!.playCount, greaterThanOrEqualTo(1));
    });

    test('autoPlay=false：只 pause，不起播（试听也要能被「预加载」）', () async {
      notifier = await boot();
      final song = _preview('p2');

      await notifier.playSong(
        song,
        queue: <Song>[song],
        index: 0,
        autoPlay: false,
      );
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(platform.last!.loadCount, 1);
      expect(platform.last!.playCount, 0);
      expect(notifier.state.currentSong?.id, 'p2');
      expect(notifier.state.playbackSource, PlaybackSource.stream);
    });

    test('空队列：resolvePreviewPlaybackQueue 兜底成 [解析后这首歌]', () async {
      // player_platform_helpers.dart:27-29 那条 `nextQueue.isEmpty` 分支。
      notifier = await boot();
      final song = _preview('p3');

      await notifier.playSong(song, queue: <Song>[]);
      await waitLoaded();

      expect(ids(notifier.state.queue), <String>['p3']);
      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 'p3');
    });

    test('preferredIndex 指向的不是本歌：按 id 重新定位（不插队）', () async {
      notifier = await boot();
      final a = _preview('pa');
      final b = _preview('pb');

      await notifier.playSong(b, queue: <Song>[a, b], index: 1);
      await waitLoaded();

      expect(ids(notifier.state.queue), <String>['pa', 'pb']);
      expect(notifier.state.currentIndex, 1);
    });
  });

  // ─────────────────── 二、试听解析失败（源码 1621-1637） ───────────────────
  group('_resolvePreviewSongForPlayback · 解析失败后的就地跳转', () {
    test('解析失败 → 在本试听队列内跳下一首（不回退到旧队列）', () async {
      // 踩坑 #181-D：这条路上 state 还没被写成试听队列，注释明确说「不能走
      // _handlePlaybackError（它的 next() 会推进旧队列）」。所以断言只能钉
      // 「确实跳到了本队列的下一首」，不能钉 currentSong 的旧值。
      notifier = await boot();
      final bad = _preview('bad1', streamUrl: null);
      final good = _preview('good2');

      await notifier.playSong(bad, queue: <Song>[bad, good], index: 0);
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(notifier.state.currentIndex, 1);
      expect(notifier.state.currentSong?.id, 'good2');
      expect(platform.last!.loadCount, 1);
      // 同 #185-D：试听流走本机代理，只钉 path。
      expect(platform.last!.loadedUris.single, endsWith('/track/good2.m4a'));
    });

    test('解析失败且已在队尾 → 不起播也不留半截状态', () async {
      notifier = await boot();
      final bad = _preview('bad1', streamUrl: null);

      await notifier.playSong(bad, queue: <Song>[bad], index: 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(platform.last?.loadCount ?? 0, 0,
          reason: '解析都失败了，不该有任何一次真实加载');
      expect(notifier.state.currentSong, isNull);
    });
  });

  // ─────────────────── 三、试听 setUrl 失败后的两条出路 ───────────────────
  group('_playPreviewSongInternal · setUrl 失败', () {
    test('无可用线路 → 只排重连重试，不自动跳歌', () async {
      notifier = await boot(routeAvailable: false);
      final song = _preview('badp', streamUrl: 'http://[::1/track.m4a');
      expect(() => Uri.parse(song.previewStreamUrl!), throwsFormatException);

      await notifier.playSong(song, queue: <Song>[song], index: 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(platform.last?.loadCount ?? 0, 0);
      // 无线路时 return，不会 _handlePlaybackError ⇒ 不会有第二次 load。
      expect(notifier.state.currentIndex, 0);
    });

    test('有可用线路 → 自动跳到下一首（试听也不该卡在死链上）', () async {
      notifier = await boot(routeAvailable: true);
      final bad = _preview('badp', streamUrl: 'http://[::1/track.m4a');
      final good = _preview('goodp');

      await notifier.playSong(bad, queue: <Song>[bad, good], index: 0);
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(notifier.state.currentIndex, 1);
      expect(notifier.state.currentSong?.id, 'goodp');
    });
  });

  // ─────────────────── 四、直连失败 → 转码降级重试（源码 1285-1400） ───────────────────
  group('_playWithTranscoding · 直连失败后的 MP3 降档重试', () {
    test('flac 直连失败 → 转码 mp3/320 重试并成功', () async {
      // 踩坑 #184-D：'flac' 的 _needsTranscoding 是 null，所以直连失败后一定进
      // 转码重试；第一次 getStreamUrl 吐非法 URL（Uri.parse 抛 ⇒ setUrl 失败），
      // 第二次吐合法 URL ⇒ 转码链路走通。
      notifier = await boot();
      spy.streamUrls = <String>[
        'http://[::1/rest/stream?id=s1',
        'http://192.168.10.240:46400/rest/stream?id=s1&format=mp3&maxBitRate=320',
      ];

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        index: 0,
        autoPlay: false,
      );
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // 两次取流：第一次直连（无 format）、第二次转码（mp3 / 320）。
      expect(spy.streamUrlCalls, <String>[
        's1|format=null|maxBitRate=null',
        's1|format=mp3|maxBitRate=320',
      ]);
      // 只有转码那一次真的加载了（直连那次 Uri.parse 就炸了，到不了平台）。
      expect(platform.last!.loadedUris, <String>[
        'http://192.168.10.240:46400/rest/stream?id=s1&format=mp3&maxBitRate=320',
      ]);
      expect(notifier.state.playbackSource, PlaybackSource.stream);
      expect(notifier.state.currentSong?.id, 's1');
    });

    test('转码成功后按 autoPlay 决定要不要上报 scrobble', () async {
      notifier = await boot();
      spy.streamUrls = <String>[
        'http://[::1/rest/stream?id=s1',
        'http://192.168.10.240:46400/rest/stream?id=s1&format=mp3',
      ];
      spy.getPaths.clear();

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        index: 0,
        autoPlay: true,
      );
      await waitLoaded();
      await waitUntil(() => spy.getPaths.contains(ApiConstants.scrobble));

      expect(spy.getPaths, contains(ApiConstants.scrobble));
      expect(platform.last!.playCount, greaterThanOrEqualTo(1));
    });

    test('autoPlay=false 的转码重试不 play、也不上报', () async {
      notifier = await boot();
      spy.streamUrls = <String>[
        'http://[::1/rest/stream?id=s1',
        'http://192.168.10.240:46400/rest/stream?id=s1&format=mp3',
      ];
      spy.getPaths.clear();

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        index: 0,
        autoPlay: false,
      );
      await waitLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(platform.last!.playCount, 0);
      expect(spy.getPaths, isNot(contains(ApiConstants.scrobble)));
    });
  });

  // ─────────────────── 五、转码也失败之后的两条出路（源码 1401-1423） ───────────────────
  group('_playWithTranscoding · 转码也失败', () {
    test('有可用线路 → 自动跳下一首', () async {
      notifier = await boot(routeAvailable: true);
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
      );
      spy.streamUrls = <String>['http://[::1/rest/stream?id=s1'];

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        index: 0,
        autoPlay: false,
      );
      await waitUntil(() => (platform.last?.loadCount ?? 0) > 0);
      await waitUntil(() => notifier.state.currentIndex == 1, ticks: 300);

      expect(notifier.state.currentIndex, 1);
      expect(notifier.state.currentSong?.id, 's2');
    });

    test('无可用线路 → 只排重连重试，不跳歌', () async {
      notifier = await boot(routeAvailable: false);
      spy.streamUrls = <String>['http://[::1/rest/stream?id=s1'];

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        index: 0,
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 's1');
      expect(platform.last?.loadCount ?? 0, 0);
    });

    test('转码失败 + 第二次探测已无线路 → 只排重连重试，不跳歌', () async {
      // 路由判定在**两处**（1244 直连失败后、1403 转码失败后）。要打到 1411-1418
      // 必须让第一次为 true、第二次为 false —— 靠 `_FakeAddressPool.probeResults`
      // 按序编排。
      notifier = await boot(routeAvailable: true);
      pool.probeResults = <bool>[true, false];
      // 'flac' 的 _needsTranscoding 是 null ⇒ 一定进转码重试。
      spy.streamUrls = <String>['http://[::1/rest/stream?id=s1'];

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1'), _song('s2')],
        index: 0,
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(notifier.state.currentIndex, 0);
      expect(notifier.state.currentSong?.id, 's1');
      expect(platform.last?.loadCount ?? 0, 0);
    });

    test('后缀本就要转码（ape）→ 不再走转码重试，直接跳下一首', () async {
      // 踩坑 #184-D 的另一侧：'ape' 在 universallyUnsupported 里，
      // `_needsTranscoding('ape') == 'mp3'`（非 null）⇒ 1265 判定为假 ⇒
      // 走 1281 的 `_handlePlaybackError`，不进 `_playWithTranscoding`。
      notifier = await boot(routeAvailable: true);
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
      );
      spy.streamUrls = <String>['http://[::1/rest/stream?id=s1'];

      await notifier.playSong(
        _song('a1', suffix: 'ape'),
        queue: <Song>[_song('a1', suffix: 'ape'), _song('a2', suffix: 'ape')],
        index: 0,
        autoPlay: false,
      );
      await waitUntil(() => notifier.state.currentIndex == 1, ticks: 300);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifier.state.currentIndex, 1);
      // 关键在于**没有**出现过 `maxBitRate=320` 的取流 —— 那才是转码重试的签名。
      expect(
        spy.streamUrlCalls.where((c) => c.endsWith('maxBitRate=320')),
        isEmpty,
      );
    });

    test('单曲队列 + order：转码失败后 next() 在队尾停住，不会连跳', () async {
      // 踩坑 #183-D：all 模式下 next() 会 skipToQueueItem(0) 再起播一次 → 无限连跳。
      // order 的「到末尾即停」是这条路的保命符。
      notifier = await boot(routeAvailable: true);
      notifier.state = notifier.state.copyWith(
        playbackMode: PlaybackMode.order,
      );
      spy.streamUrls = <String>['http://[::1/rest/stream?id=s1'];
      final loadsBefore = 0;

      await notifier.playSong(
        _song('s1'),
        queue: <Song>[_song('s1')],
        index: 0,
        autoPlay: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(platform.last?.loadCount ?? 0, loadsBefore);
      expect(notifier.state.currentSong?.id, 's1');
      expect(notifier.state.currentIndex, 0);
    });
  });

  // ─────────────────── 六、resolvePreviewPlaybackQueue 直测 ───────────────────
  group('resolvePreviewPlaybackQueue · 纯函数', () {
    test('空队列 → 直接变成 [解析后这首歌]', () {
      final resolved = _preview('p9');
      final r = resolvePreviewPlaybackQueue(
        queue: const <Song>[],
        preferredIndex: 3,
        unresolvedSong: _preview('p9', streamUrl: null),
        resolvedSong: resolved,
      );
      expect(ids(r.queue), <String>['p9']);
      expect(r.index, 0);
    });

    test('preferredIndex 命中 → 原地替换（队列长度不变）', () {
      final a = _preview('pa');
      final b = _preview('pb');
      final resolved = _preview('pb', streamUrl: 'https://cdn/other.m4a');
      final r = resolvePreviewPlaybackQueue(
        queue: <Song>[a, b],
        preferredIndex: 1,
        unresolvedSong: b,
        resolvedSong: resolved,
      );
      expect(ids(r.queue), <String>['pa', 'pb']);
      expect(r.index, 1);
      expect(r.queue[1].previewStreamUrl, 'https://cdn/other.m4a');
    });

    test('preferredIndex 不命中但 id 能在队列里找到 → 重新定位后再替换', () {
      final a = _preview('pa');
      final b = _preview('pb');
      final resolved = _preview('pb', streamUrl: 'https://cdn/other.m4a');
      final r = resolvePreviewPlaybackQueue(
        queue: <Song>[a, b],
        preferredIndex: 0,
        unresolvedSong: b,
        resolvedSong: resolved,
      );
      expect(ids(r.queue), <String>['pa', 'pb']);
      expect(r.index, 1);
    });

    test('id 不在队列里 → 就地插入（clamp 后的下标）', () {
      final a = _preview('pa');
      final b = _preview('pb');
      final resolved = _preview('pz', streamUrl: 'https://cdn/new.m4a');
      final r = resolvePreviewPlaybackQueue(
        queue: <Song>[a, b],
        preferredIndex: 9,
        unresolvedSong: _preview('pz', streamUrl: null),
        resolvedSong: resolved,
      );
      expect(ids(r.queue), <String>['pa', 'pb', 'pz']);
      expect(r.index, 2);
    });
  });
}
