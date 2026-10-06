// b38a4 —— Route A 播放核心补测（小体积 provider 缺口）。
//
// 针对「player 目录联合覆盖率」仍 0 命中的可达分支：
//   * queue_origin_provider 85/86 : markQueueOrigin(WidgetRef) 写入
//   * sleep_timer_provider  55    : 链路 A 服务器计时失败 → 回退本地(55)
//   * sleep_timer_provider  70    : 本机倒计时每秒刷新剩余时长(70)
//   * sleep_timer_provider  91    : 到点且链路 B(DLNA 直投) → 命令设备暂停(91)
//   * effective_volume      79/80 : setEffectiveVolume 投屏 peer 分支
//
// 姿势：`_FakeCastPeer` / `_FakeDlnaManager` 桩掉外部链路；走 dlnaCastProvider
// 的用例必须装假 just_audio 平台（DlnaCastNotifier 构造体读 playerProvider.notifier）。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
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
import 'package:musicflow_client/providers/player/effective_volume.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';

// ─────────────────────────── 替身 just_audio 平台 ───────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async =>
      LoadResponse(duration: const Duration(seconds: 200));

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
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      _FakeAudioPlayerPlatform(request.id);

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

const _peer = PeerInfo(
  peerId: 'peer1',
  name: 'p',
  kind: 'phone',
  available: true,
);

/// CastPeerController 替身：可控投屏态 + 记录 setSleepTimer/setVolume。
class _FakeCastPeer extends CastPeerController {
  _FakeCastPeer(
    super.ref, {
    this.active = true,
    this.throwOnSetSleepTimer = false,
  }) {
    state = active
        ? const CastPeerState(activePeer: _peer, status: PeerStatus())
        : const CastPeerState();
  }

  final bool active;
  final bool throwOnSetSleepTimer;
  int setVolumeCalls = 0;
  int setSleepTimerCalls = 0;
  int pauseCalls = 0;
  int lastVolume = -1;

  @override
  Future<void> setVolume(int volume) async {
    setVolumeCalls++;
    lastVolume = volume;
  }

  @override
  Future<void> setSleepTimer(Duration? duration) async {
    setSleepTimerCalls++;
    if (throwOnSetSleepTimer) throw StateError('sleep timer boom');
  }

  @override
  Future<void> pause() async => pauseCalls++;
}

/// DlnaManager 替身：只记录调用，不碰网络/设备。
class _FakeDlnaManager extends DlnaManager {
  int pauseCalls = 0;

  @override
  Future<void> pause() async => pauseCalls++;
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
  _FakeCacheManager() : super();

  @override
  Future<void> init() async {}

  @override
  File? songFile(String songId) => null;
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
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final repo = _FakeMusicRepository();
  final spy = _SpySubsonicApiClient();
  late _FakeDlnaManager dlnaManager;

  List<Override> baseOverrides({
    CastPeerController Function(Ref)? castPeer,
  }) =>
      <Override>[
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
        offlineCacheManagerProvider.overrideWithValue(_FakeCacheManager()),
        offlineCacheReadyProvider.overrideWith((ref) async {}),
        dlnaManagerProvider.overrideWithValue(dlnaManager),
        castPeerControllerProvider.overrideWith(
          (ref) => (castPeer ?? (r) => _FakeCastPeer(r))(ref),
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
      ];

  setUp(() {
    JustAudioPlatform.instance = _FakeJustAudioPlatform();
    dlnaManager = _FakeDlnaManager();
  });

  // ───────────── queue_origin: markQueueOrigin(85/86) ─────────────
  testWidgets('markQueueOrigin 经 WidgetRef 写入 queueOriginProvider(85/86)',
      (tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    markQueueOrigin(
      captured,
      const QueueOrigin(QueueOriginKind.album, 'a1'),
    );
    final container =
        ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
    expect(container.read(queueOriginProvider)?.kind, QueueOriginKind.album);
    expect(container.read(queueOriginProvider)?.id, 'a1');
  });

  // ───────────── sleep_timer: 55 / 70 / 91 ─────────────
  group('SleepTimerNotifier', () {
    test('链路 A 服务器计时失败 → 回退本地(55)', () async {
      final c = ProviderContainer(
        overrides: baseOverrides(
          castPeer: (r) =>
              _FakeCastPeer(r, active: true, throwOnSetSleepTimer: true),
        ),
      );
      final n = c.read(sleepTimerProvider.notifier);
      await n.start(const Duration(seconds: 60));
      expect(n.serverTracked, isFalse,
          reason: 'setSleepTimer 抛错 → 55 行回退本地计时');
      await n.cancel();
      c.dispose();
    });

    test('本机倒计时每秒回填剩余时长(70)', () async {
      final c = ProviderContainer(
        overrides: baseOverrides(castPeer: (r) => _FakeCastPeer(r, active: false)),
      );
      final n = c.read(sleepTimerProvider.notifier);
      await n.start(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(n.state, isNotNull, reason: '1s tick 应回填剩余时长(70)');
      expect(n.state!.inMilliseconds, lessThan(3000));
      await n.cancel();
      c.dispose();
    });

    test('到点且 DLNA 直投 → 命令设备暂停(91)', () async {
      final c = ProviderContainer(
        overrides: baseOverrides(castPeer: (r) => _FakeCastPeer(r, active: false)),
      );
      // 置为 DLNA 直投态：_pauseLocal 走 90-91 的 dlna 分支。
      final dlna = c.read(dlnaCastProvider.notifier);
      dlna.state = dlna.state.copyWith(isCasting: true);
      expect(c.read(dlnaCastProvider).isCasting, isTrue);

      final n = c.read(sleepTimerProvider.notifier);
      await n.start(const Duration(milliseconds: 10));
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(dlnaManager.pauseCalls, 1,
          reason: '到点应指挥 DLNA 设备暂停(91)');
      await n.cancel();
      c.dispose();
    });
  });

  // ───────────── effective_volume: setEffectiveVolume peer 分支(79/80) ─────────────
  testWidgets('setEffectiveVolume 投屏 peer 激活 → 走 peer setVolume(79/80)',
      (tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(
          castPeer: (r) => _FakeCastPeer(r, active: true),
        ),
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    final container =
        ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
    final peer =
        container.read(castPeerControllerProvider.notifier) as _FakeCastPeer;

    await setEffectiveVolume(captured, 0.5);
    expect(peer.setVolumeCalls, 1,
        reason: '激活 peer → 79-80 行把音量下发到 peer 控制器');
    expect(peer.lastVolume, 50);
  });
}
