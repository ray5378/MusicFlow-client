// b34a：lib/providers/player/effective_playback_provider.dart
// （LF:99 / LH:69，30 miss）未覆盖分支攻坚：
//   * effectivePosition/Duration/IsPlaying 的三条链路取值（本机 / 链路 A cast / 链路 B DLNA）
//   * toggleEffectivePlayback / pauseEffectivePlayback（DLNA + cast 分支）
//   * cycleEffectivePlayMode：DLNA 分支 + cast 分支 + 本机 cyclePlaybackMode
//   * seekEffectivePlayback：DLNA 分支 + 本机/链路 A 分支
//   * next/previousEffectivePlayback：DLNA 分支 + cast 分支
//   * playEffectiveQueue：cast 主通道（content play）/ 失败回落整队推送 / 无 id 直接整队 / 本机
//   * playEffectiveSong：DLNA / cast 单曲点播（无队列上下文）/ cast 整队（有队列上下文）/ 本机
//   * currentPlayerName
//
// 这些入口拿 WidgetRef ⇒ 用 testWidgets + UncontrolledProviderScope 捕获 WidgetRef；
// playerProvider 仍是真实 notifier + just_audio 替身；cast/DLNA 两个控制器用
// extends 替身记录调用（对齐 b29a 系列「必须 extends 才能过类型检查」）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

// ───────────────────────────── just_audio 替身 ───────────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      const Stream<PlayerDataMessage>.empty();

  void emit() {
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: const Duration(seconds: 10),
        bufferedPosition: const Duration(seconds: 10),
        duration: const Duration(seconds: 200),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    scheduleMicrotask(emit);
    return LoadResponse(duration: const Duration(seconds: 200));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async =>
      PlayResponse.fromMap(const <dynamic, dynamic>{});

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
    final existing = last;
    if (existing != null) return existing;
    final player = _FakeAudioPlayerPlatform(request.id);
    last = player;
    return player;
  }
}

// ───────────────────────────── 其它桩 ─────────────────────────────────────

Song _song(String id) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'mp3',
      duration: 200,
      starred: false,
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
  }) =>
      'http://192.168.10.240:46400/rest/stream?id=$songId';
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

class _RecordingCastPeerController extends CastPeerController {
  _RecordingCastPeerController(super.ref, {required bool active}) {
    if (active) {
      state = CastPeerState(
        activePeer: PeerInfo(
          peerId: 'peer-9',
          name: '客厅设备',
          kind: 'windows',
          available: true,
        ),
        status: const PeerStatus(
          state: 'PLAYING',
          positionSeconds: 7,
          durationSeconds: 200,
          active: true,
        ),
        smoothPositionSeconds: 7.5,
      );
    }
  }

  final calls = <String>[];
  bool contentOk = true;

  @override
  Future<void> toggle() async {
    calls.add('toggle');
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
  }

  @override
  Future<void> next() async {
    calls.add('next');
  }

  @override
  Future<void> previous() async {
    calls.add('previous');
  }

  @override
  Future<void> cyclePlayMode() async {
    calls.add('cyclePlayMode');
  }

  @override
  Future<bool> playContentOnPeer({
    required String type,
    required String id,
    String? songId,
    int? startIndex,
    List<Map<String, dynamic>>? localItems,
    int? localStartIndex,
    double? positionSeconds,
  }) async {
    calls.add('content:$type:$id:$songId');
    return contentOk;
  }

  @override
  Future<bool> playQueueOnPeer(
    List<Song> songs, {
    int startIndex = 0,
  }) async {
    calls.add('queuePeer:${songs.length}:$startIndex');
    return true;
  }

  @override
  Future<bool> playSongOnPeer(
    Song song, {
    List<Song>? queue,
    int? index,
  }) async {
    calls.add('songPeer:${song.id}:$index');
    return true;
  }
}

class _FakeDlnaManager extends DlnaManager {}

class _RecordingDlnaCastNotifier extends DlnaCastNotifier {
  _RecordingDlnaCastNotifier(super.ref, {required bool casting}) {
    if (casting) {
      state = DlnaCastState(
        isCasting: true,
        smoothPositionSeconds: 12.5,
        status: const DlnaDeviceStatus(
          state: 'PLAYING',
          position: 12,
          duration: 300,
          volume: 40,
        ),
      );
    }
  }

  final calls = <String>[];

  @override
  Future<void> toggle() async {
    calls.add('toggle');
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> seek(int seconds) async {
    calls.add('seek:$seconds');
  }

  @override
  Future<void> next() async {
    calls.add('next');
  }

  @override
  Future<void> previous() async {
    calls.add('previous');
  }

  @override
  Future<void> cyclePlayMode() async {
    calls.add('cyclePlayMode');
  }

  @override
  Future<bool> playQueueOnDevice(
    List<Song> songs, {
    int startIndex = 0,
  }) async {
    calls.add('playQueue:${songs.length}:$startIndex');
    return true;
  }

  @override
  Future<bool> playSongOnDevice(
    Song song, {
    List<Song>? queue,
    int? index,
  }) async {
    calls.add('playSong:${song.id}');
    return true;
  }
}

// ───────────────────────────────── 装配 ─────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );
  // just_audio play() 内部走 audio_session.setActive —— 测试环境无插件会抛错
  // 触发自动跳歌，mock 掉通道让 play() 正常走完。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (MethodCall call) async => null,
  );
  // cast/DLNA 控制器会监听 connectivity_plus 的事件流 —— testWidgets 下缺
  // 插件实现会把整个测试判定失败，mock 一个静默落点。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
    (MethodCall call) async => null,
  );
  SharedPreferences.setMockInitialValues(<String, Object>{});

  /// 每个用例收尾：FakeAsync 区推进 6s 冲掉 playerProvider 的 5s 落盘
  /// 防抖定时器（否则 flutter_test 判 pending timers 失败并级联挂起），
  /// 再显式销毁容器（避免 dispose 定时器互相踩）。
  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pump(const Duration(seconds: 6));
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> waitQuiet(PlayerNotifier notifier) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (i > 4 && !notifier.debugIsRestoringPlaybackSession) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!notifier.debugIsRestoringPlaybackSession) return;
      }
    }
  }

  /// 建容器（含真实 playerProvider）+ pump 出 WidgetRef；返回 (container, ref)。
  Future<(ProviderContainer, WidgetRef)> harness(
    WidgetTester tester, {
    bool castActive = false,
    bool dlnaCasting = false,
  }) async {
    final platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    final repo = _FakeMusicRepository();
    final spy = _SpySubsonicApiClient();
    late _RecordingCastPeerController cast;
    late _RecordingDlnaCastNotifier dlna;

    final container = ProviderContainer(
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
        effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
        isOfflineProvider.overrideWithValue(false),
        subsonicApiClientProvider.overrideWithValue(spy),
        musicRepositoryProvider.overrideWithValue(repo),
        offlineCacheDaemonProvider.overrideWith(
          (ref) => _NoopOfflineCacheDaemon(ref),
        ),
        castPeerControllerProvider.overrideWith((ref) {
          cast = _RecordingCastPeerController(ref, active: castActive);
          return cast;
        }),
        dlnaManagerProvider.overrideWith((ref) => _FakeDlnaManager()),
        dlnaCastProvider.overrideWith((ref) {
          dlna = _RecordingDlnaCastNotifier(ref, casting: dlnaCasting);
          return dlna;
        }),
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

    WidgetRef? captured;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    addTearDown(() {
      // 兜底：若用例提前失败，也要销毁容器。
      // 正常路径由 finish() 显式销毁（flush 5s 落盘定时器后）。
    });
    return (container, captured!);
  }

  group('纯本机链路（无 cast / 无 DLNA）', () {
    testWidgets('effective 三态取 playerProvider；控制命令路由 cast 控制器（本机兜底）',
        (tester) async {
      final (container, ref) = await harness(tester);
      final notifier = container.read(playerProvider.notifier);
      await tester.runAsync(() => waitQuiet(notifier));

      notifier.state = notifier.state.copyWith(
        position: const Duration(seconds: 33),
        duration: const Duration(seconds: 200),
        isPlaying: true,
      );
      await tester.pump();

      expect(container.read(effectivePositionProvider),
          const Duration(seconds: 33));
      expect(container.read(effectiveDurationProvider),
          const Duration(seconds: 200));
      expect(container.read(effectiveIsPlayingProvider), isTrue);

      // 控制命令统一走 castPeerController（无 activePeer 时内部兜底本机）。
      await tester.runAsync(() => toggleEffectivePlayback(ref));
      await tester.runAsync(() => pauseEffectivePlayback(ref));
      await tester
          .runAsync(() => seekEffectivePlayback(ref, const Duration(seconds: 9)));
      expect(await tester.runAsync(() => nextEffectivePlayback(ref)), isTrue);
      expect(await tester.runAsync(() => previousEffectivePlayback(ref)), isTrue);

      final cast =
          container.read(castPeerControllerProvider.notifier)
              as _RecordingCastPeerController;
      expect(cast.calls, containsAll(<String>['toggle', 'pause', 'next', 'previous']));
      expect(cast.calls.where((c) => c.startsWith('seek:')), isNotEmpty);
      await finish(tester, container);
    });

    testWidgets('cycleEffectivePlayMode 本机 → cyclePlaybackMode 生效',
        (tester) async {
      final (container, ref) = await harness(tester);
      final notifier = container.read(playerProvider.notifier);
      await tester.runAsync(() => waitQuiet(notifier));

      final before = container.read(playerProvider).playbackMode;
      await tester.runAsync(() => cycleEffectivePlayMode(ref));
      await tester.pump();
      expect(container.read(playerProvider).playbackMode, isNot(before));

      // currentPlayerName：本机态返回「本机」名（非空即可，不钉文案）。
      expect(
        currentPlayerName(container.read(castPeerControllerProvider)),
        isNotEmpty,
      );
      await finish(tester, container);
    });

    testWidgets('playEffectiveQueue / playEffectiveSong 本机 → 驱动 playerProvider',
        (tester) async {
      final (container, ref) = await harness(tester);
      // 本地链路会真跑 playSong：notifier 必须在真实 zone 里创建与 await
      // （FakeAsync 区创建的 notifier 挂起在真实异步管线上 → 永不完成）。
      bool ok = false;
      bool ok2 = false;
      await tester.runAsync(() async {
        final notifier = container.read(playerProvider.notifier);
        await waitQuiet(notifier);

        ok = await playEffectiveQueue(
          ref,
          <Song>[_song('q1'), _song('q2')],
          origin: const QueueOrigin(QueueOriginKind.album, 'al1'),
        );
        ok2 = await playEffectiveSong(ref, _song('one'));
      });
      expect(ok, isTrue);
      expect(container.read(playerProvider).currentSong?.id, 'one');
      expect(container.read(queueOriginProvider)?.isAlbum, isTrue);
      expect(ok2, isTrue);
      await finish(tester, container);
    });
  });

  group('链路 A：服务端投屏（cast active）', () {
    testWidgets('effective 三态取 cast 轮询值；命令全路由 cast 控制器',
        (tester) async {
      final (container, ref) = await harness(tester, castActive: true);
      final notifier = container.read(playerProvider.notifier);
      await tester.runAsync(() => waitQuiet(notifier));

      expect(container.read(effectivePositionProvider),
          const Duration(milliseconds: 7500));
      expect(container.read(effectiveDurationProvider),
          const Duration(seconds: 200));
      expect(container.read(effectiveIsPlayingProvider), isTrue);

      await tester.runAsync(() => toggleEffectivePlayback(ref));
      await tester.runAsync(() => pauseEffectivePlayback(ref));
      await tester.runAsync(
          () => cycleEffectivePlayMode(ref));
      await tester.runAsync(
          () => seekEffectivePlayback(ref, const Duration(seconds: 42)));
      await tester.runAsync(() => nextEffectivePlayback(ref));
      await tester.runAsync(() => previousEffectivePlayback(ref));

      final cast =
          container.read(castPeerControllerProvider.notifier)
              as _RecordingCastPeerController;
      expect(
        cast.calls,
        containsAll(<String>[
          'toggle',
          'pause',
          'cyclePlayMode',
          'seek:42000',
          'next',
          'previous',
        ]),
      );

      expect(
        currentPlayerName(container.read(castPeerControllerProvider)),
        '客厅设备',
      );
      await finish(tester, container);
    });

    testWidgets('playEffectiveQueue：主通道 content play 成功', (tester) async {
      final (container, ref) = await harness(tester, castActive: true);
      final ok = await tester.runAsync(
        () => playEffectiveQueue(
          ref,
          <Song>[_song('c1'), _song('c2')],
          startIndex: 1,
          origin: const QueueOrigin(QueueOriginKind.playlist, 'pl1'),
        ),
      );
      expect(ok, isTrue);
      final cast = ref.read(castPeerControllerProvider.notifier)
          as _RecordingCastPeerController;
      expect(cast.calls, contains('content:playlist:pl1:c2'));
      expect(cast.calls.any((c) => c.startsWith('queuePeer:')), isFalse);
      await finish(tester, container);
    });

    testWidgets('playEffectiveQueue：content 失败 → 回落整队推送', (tester) async {
      final (container, ref) = await harness(tester, castActive: true);
      final cast = container.read(castPeerControllerProvider.notifier)
          as _RecordingCastPeerController;
      cast.contentOk = false;

      final ok = await tester.runAsync(
        () => playEffectiveQueue(
          ref,
          <Song>[_song('c1'), _song('c2')],
          startIndex: 0,
          origin: const QueueOrigin(QueueOriginKind.playlist, 'pl1'),
        ),
      );
      expect(ok, isTrue);
      expect(cast.calls, contains('content:playlist:pl1:c1'));
      expect(cast.calls, contains('queuePeer:2:0'));
      await finish(tester, container);
    });

    testWidgets('playEffectiveQueue：来源无 id（other）→ 直接整队推送', (tester) async {
      final (container, ref) = await harness(tester, castActive: true);
      final ok = await tester.runAsync(
        () => playEffectiveQueue(
          ref,
          <Song>[_song('c1'), _song('c2'), _song('c3')],
          origin: const QueueOrigin(QueueOriginKind.other),
        ),
      );
      expect(ok, isTrue);
      final cast = container.read(castPeerControllerProvider.notifier)
          as _RecordingCastPeerController;
      expect(cast.calls, contains('queuePeer:3:0'));
      await finish(tester, container);
    });

    testWidgets('playEffectiveSong：无队列上下文 → 单曲点播；有队列 → 整队推送',
        (tester) async {
      final (container, ref) = await harness(tester, castActive: true);
      final cast = container.read(castPeerControllerProvider.notifier)
          as _RecordingCastPeerController;

      // 单曲点播主通道。
      final ok = await tester.runAsync(() => playEffectiveSong(ref, _song('solo')));
      expect(ok, isTrue);
      expect(cast.calls, contains('content:song:solo:solo'));

      // 手上有整条本地队列 → playSongOnPeer。
      final ok2 = await tester.runAsync(
        () => playEffectiveSong(
          ref,
          _song('row2'),
          queue: <Song>[_song('row1'), _song('row2')],
          index: 1,
        ),
      );
      expect(ok2, isTrue);
      expect(cast.calls, contains('songPeer:row2:1'));
      await finish(tester, container);
    });
  });

  group('链路 B：局域网 DLNA 直投', () {
    testWidgets('effective 三态取 DLNA 插值/状态；命令全路由 DLNA notifier',
        (tester) async {
      final (container, ref) = await harness(tester, dlnaCasting: true);
      final notifier = container.read(playerProvider.notifier);
      await tester.runAsync(() => waitQuiet(notifier));

      expect(container.read(effectivePositionProvider),
          const Duration(milliseconds: 12500));
      expect(
          container.read(effectiveDurationProvider), const Duration(seconds: 300));
      expect(container.read(effectiveIsPlayingProvider), isTrue);

      await tester.runAsync(() => toggleEffectivePlayback(ref));
      await tester.runAsync(() => pauseEffectivePlayback(ref));
      await tester.runAsync(() => cycleEffectivePlayMode(ref));
      await tester.runAsync(
          () => seekEffectivePlayback(ref, const Duration(seconds: 77)));
      await tester.runAsync(() => nextEffectivePlayback(ref));
      await tester.runAsync(() => previousEffectivePlayback(ref));

      final dlna = container.read(dlnaCastProvider.notifier)
          as _RecordingDlnaCastNotifier;
      expect(
        dlna.calls,
        containsAll(<String>[
          'toggle',
          'pause',
          'cyclePlayMode',
          'seek:77',
          'next',
          'previous',
        ]),
      );
      await finish(tester, container);
    });

    testWidgets('playEffectiveQueue / playEffectiveSong → DLNA 设备',
        (tester) async {
      final (container, ref) = await harness(tester, dlnaCasting: true);

      final ok = await tester.runAsync(
        () => playEffectiveQueue(
          ref,
          <Song>[_song('d1'), _song('d2')],
          startIndex: 1,
          origin: const QueueOrigin(QueueOriginKind.album, 'al1'),
        ),
      );
      expect(ok, isTrue);
      expect(container.read(queueOriginProvider)?.isAlbum, isTrue);

      final ok2 = await tester.runAsync(
        () => playEffectiveSong(
          ref,
          _song('d9'),
          queue: <Song>[_song('d8'), _song('d9')],
          index: 1,
        ),
      );
      expect(ok2, isTrue);

      final dlna = container.read(dlnaCastProvider.notifier)
          as _RecordingDlnaCastNotifier;
      expect(dlna.calls, contains('playQueue:2:1'));
      expect(dlna.calls, contains('playSong:d9'));
      await finish(tester, container);
    });
  });
}
