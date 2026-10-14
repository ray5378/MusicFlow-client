// b52a：ADR-2 阶段 2b-2 位置轮询驱动窄接线测试。
//
// 驱动已抽独立库（PlaybackPositionPollingDriver on PlaybackPositionPollingHost），
// 行为级全覆盖在 b29a / b50e（经真实 notifier 集成驱动）；本测试用一个最小
// fake host + fake just_audio platform 只盯**接线**是否与原 part 实现等价：
//   * 可见 tick：drift≥250 → 经 host.logicalPlayerPosition 换算后写回 host.state
//     （验证 state setter 与位置换算转发）；
//   * seek 落位宽限：host.seekSettleUntil 未到期 → tick 早退（不写回）；
//   * 停滞看门狗：就绪播放 + 位置钉住 10 tick → host.next() 出口被调
//     （验证 stall 信号经 host.state / next 转发）；
//   * 生命周期：stopPositionPolling 后 tick 静默、resetPositionTracking 重置基线。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/player_position_polling.dart';
import 'package:musicflow_client/providers/player/player_state.dart';

// ───────────────────────────── just_audio 替身 ───────────────────────────────

class _FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  _FakeAudioPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  Duration emitPos = Duration.zero;
  ProcessingStateMessage emitState = ProcessingStateMessage.ready;
  Timer? _autoEmit;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  bool get hasListener => _events.hasListener;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      const Stream<PlayerDataMessage>.empty();

  void emit() {
    _events.add(
      PlaybackEventMessage(
        processingState: emitState,
        updateTime: DateTime.now(),
        updatePosition: emitPos,
        bufferedPosition: emitPos,
        duration: const Duration(seconds: 200),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  /// playing 态下 just_audio 的 position 按真实时间外推；要「位置钉住」必须
  /// 反复刷新 updateTime（同 b50e 的 startAutoEmit 姿势）。
  void startAutoEmit() {
    _autoEmit ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      emit();
    });
  }

  void stopAutoEmit() {
    _autoEmit?.cancel();
    _autoEmit = null;
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    scheduleMicrotask(emit);
    return LoadResponse(duration: const Duration(seconds: 200));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    scheduleMicrotask(emit);
    return PlayResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async =>
      PauseResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    scheduleMicrotask(emit);
    return SeekResponse.fromMap(const <dynamic, dynamic>{});
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse.fromMap(
              const <dynamic, dynamic>{});

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async =>
      DisposeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
          ConcatenatingInsertAllRequest request) async =>
      ConcatenatingInsertAllResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
          ConcatenatingRemoveRangeRequest request) async =>
      ConcatenatingRemoveRangeResponse.fromMap(const <dynamic, dynamic>{});

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
          ConcatenatingMoveRequest request) async =>
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

// ───────────────────────────── fake host ─────────────────────────────────────

// on 约束经基类满足：with 先于 implements 应用，mixin on 类型必须由超类接口提供。
abstract class _FakeHostBase implements PlaybackPositionPollingHost {}

class _FakeHost extends _FakeHostBase
    with PlaybackPositionPollingDriver {
  _FakeHost(this._state);

  PlayerState _state;
  @override
  PlayerState get state => _state;
  @override
  set state(PlayerState value) {
    _stateWrites += 1;
    _lastWrittenPosition = value.position;
    _state = value;
  }

  int _stateWrites = 0;
  Duration? _lastWrittenPosition;
  int nextCalls = 0;
  int playSongCalls = 0;
  Duration? lastReloadInitialPosition;
  final List<String> playDbgLines = <String>[];
  final List<String> seekDbgLines = <String>[];
  int completionMarks = 0;

  bool renderingActive = true;
  bool preserveSeek = false;
  DateTime? settleUntil;

  @override
  bool get mounted => true;

  @override
  bool readIsRenderingActive() => renderingActive;

  @override
  Duration logicalPlayerPosition(Duration sourcePosition) => sourcePosition;

  @override
  bool shouldPreserveSeekPosition() => preserveSeek;

  @override
  DateTime? get seekSettleUntil => settleUntil;
  @override
  set seekSettleUntil(DateTime? value) => settleUntil = value;

  @override
  bool get expectingAutoplay => _state.currentSong != null;
  @override
  set expectingAutoplay(bool value) {}

  @override
  int? get streamLoadInFlightGeneration => null;
  @override
  set streamLoadInFlightGeneration(int? value) {}

  @override
  String? get streamLoadInFlightSongId => null;
  @override
  set streamLoadInFlightSongId(String? value) {}

  @override
  int? get streamLoadInFlightSinceMs => null;
  @override
  set streamLoadInFlightSinceMs(int? value) {}

  @override
  Duration get sourcePositionOffset => Duration.zero;

  @override
  void markCompletionHandling(String songId) {
    completionMarks += 1;
  }

  @override
  int get debugStreamLoadLoadingCeilingMs => 30 * 60 * 1000;
  @override
  int get debugStreamLoadIdleStuckCeilingMs => 10 * 1000;
  @override
  int get debugStreamLoadNoProgressCeilingMs => 30 * 1000;

  @override
  void playDbg(String message) {
    playDbgLines.add(message);
  }

  @override
  void seekDbg(String message) {
    seekDbgLines.add(message);
  }

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    Duration? initialPosition,
  }) async {
    playSongCalls += 1;
    lastReloadInitialPosition = initialPosition;
  }

  @override
  Future<void> next() async {
    nextCalls += 1;
  }

  @override
  Future<void> onSongCompleted(String completedSongId) async {}

  @override
  void handlePlaybackError(String? songId) {}
}

// ───────────────────────────── 测试 ──────────────────────────────────────────

Song _song(String id) => Song(
      id: id,
      title: '曲$id',
      artist: '歌手',
      albumId: 'al1',
      suffix: 'mp3',
      duration: 200,
      starred: false,
    );

Future<bool> _waitUntil(bool Function() cond, {int ticks = 400}) async {
  for (var i = 0; i < ticks; i++) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
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

  late _FakeJustAudioPlatform platform;
  late _FakeAudioPlayerPlatform fake;
  late AudioPlayer player;

  setUp(() async {
    platform = _FakeJustAudioPlatform();
    JustAudioPlatform.instance = platform;
    fake = await platform.init(InitRequest(id: 'b52a-pre'))
        as _FakeAudioPlayerPlatform;
    player = AudioPlayer();
  });

  tearDown(() {
    fake.stopAutoEmit();
    player.dispose();
  });

  _FakeHost buildHost({required Duration statePosition}) => _FakeHost(
        PlayerState(
          currentSong: _song('s1'),
          queue: <Song>[_song('s1')],
          currentIndex: 0,
          isPlaying: true,
          processingState: ProcessingState.ready,
          position: statePosition,
          duration: const Duration(seconds: 200),
        ),
      );

  /// 让替身进入「就绪播放」态：load(ready) + play(playing=true)。
  Future<void> readyPlaying() async {
    await player.setUrl('https://music.example.test/s1.mp3');
    await player.play();
  }

  test('可见 tick：drift≥250 经 logicalPlayerPosition 换算后写回 host.state',
      () async {
    final host = buildHost(statePosition: Duration.zero);
    // just_audio 的事件流订阅发生在首次 setUrl（_setPlatformActive），构造不订阅
    // —— 未激活前 position 恒 0，必须先就绪播放打通事件链路。
    await readyPlaying();
    fake.emitPos = const Duration(seconds: 10);
    fake.startAutoEmit();
    host.startPositionPolling(player);

    final written = await _waitUntil(() => host._stateWrites > 0);
    expect(written, isTrue, reason: 'drift=10s≥250 应写回 host.state');
    // playing 态 just_audio 按真实时间外推 position（autoEmit 100ms 周期内
    // 有 ~0~100ms 偏移），断言写回值 ≈ 10s（150ms 容差）即验证转发语义。
    expect(host._lastWrittenPosition!.inMilliseconds, inInclusiveRange(10000, 10150),
        reason: '写回值应是 logicalPlayerPosition 转发结果');

    host.stopPositionPolling();
  });

  test('pendingSeek 保护期：shouldPreserveSeekPosition=true → tick 整体早退',
      () async {
    final host = buildHost(statePosition: Duration.zero);
    host.preserveSeek = true;
    await readyPlaying();
    fake.emitPos = const Duration(seconds: 10);
    fake.startAutoEmit();
    host.startPositionPolling(player);

    await Future<void>.delayed(const Duration(milliseconds: 1700));
    expect(host._stateWrites, 0, reason: '保护期内 tick 应在头部早退');
    expect(host.nextCalls, 0);
    expect(host.playSongCalls, 0);

    host.stopPositionPolling();
  });

  test('seek 落位宽限：settle 窗内 0 秒卡死被豁免（不 reload）', () async {
    final host = buildHost(statePosition: Duration.zero);
    host.settleUntil = DateTime.now().add(const Duration(seconds: 15));
    fake.emitPos = Duration.zero;
    await readyPlaying();
    fake.startAutoEmit();
    host.startPositionPolling(player);

    // settle 豁免只作用于 0 秒卡死与近末尾两条看门狗（不豁免停滞）；
    // 12 tick(6s) 无豁免即会触发 reload，这里等 7.5s 断言全程静默。
    await Future<void>.delayed(const Duration(milliseconds: 7500));
    expect(host.playSongCalls, 0,
        reason: 'settle 窗内 0 秒卡死看门狗不得触发保位重载');
    expect(host.nextCalls, 0, reason: 'atStart 停滞计数清零，不得跳歌');

    host.stopPositionPolling();
  });

  test('停滞看门狗：就绪播放 + 位置钉住 10 tick → host.next() 出口被调',
      () async {
    final host = buildHost(statePosition: const Duration(minutes: 1));
    fake.emitPos = const Duration(minutes: 1);
    await readyPlaying();
    fake.startAutoEmit();
    host.resetPositionTracking(const Duration(minutes: 1));
    host.startPositionPolling(player);

    final skipped = await _waitUntil(
      () => host.nextCalls > 0,
      ticks: 1200,
    );
    expect(skipped, isTrue, reason: '10 tick(5s) 停滞应触发 next 自愈出口');
    expect(
      host.playDbgLines.any((l) => l.contains('stall_watchdog skip_to_next')),
      isTrue,
    );

    host.stopPositionPolling();
  });

  test('生命周期：stopPositionPolling 后 tick 静默', () async {
    final host = buildHost(statePosition: Duration.zero);
    await readyPlaying();
    fake.emitPos = const Duration(seconds: 10);
    fake.startAutoEmit();
    host.startPositionPolling(player);
    final warmed = await _waitUntil(() => host._stateWrites > 0);
    expect(warmed, isTrue, reason: 'stop 前应先确认轮询写回已发生');
    host.stopPositionPolling();

    final writesAtStop = host._stateWrites;
    fake.stopAutoEmit();
    fake.emitPos = const Duration(seconds: 30);
    fake.emit();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(host._stateWrites, writesAtStop,
        reason: 'stop 后不得再有轮询写回');
    expect(host.nextCalls, 0);
  });
}
