// ADR-2 阶段 2b（[l17]）：`PlaybackSessionPersister` 协作者**独立构造**测试。
//
// 2b 把会话落盘/恢复从 `PlayerPlaybackSessionInternals` mixin 抽成协作者对象
// （player_session_persister.dart）。本文件证明两点：
//   1. 协作者可脱离 Riverpod / 播放器 / part 体系独立构造 —— 只需一个几十行
//      的 fake host（`PlaybackSessionPersisterHost` 窄接口，刻意不含 Ref）；
//   2. 行为契约与抽取前逐字一致：防抖 5s、immediate 取消防抖、并发写合并
//      （脏标记补写）、恢复竞速（本地/服务端）、代际守卫作废、恢复期落盘闸门。
//
// 写盘动作统一用 `debugBeforePersistWrite` 钩子**计数**观察（payload 构造
// 之后、真正写盘之前），磁盘内容用 `LocalStorage.getPlaybackSession` 回读。
//
// ⚠️ 存储环境（沿袭 session_teardown_test 的教训）：JsonFileStore 必须每用例
// 注入独立临时目录（debugDirectory），否则走 path_provider 通道在测试环境
// 挂死；拆卸时先摘注入再删目录。并发合并用例（B1）必须真异步 —— fakeAsync
// 里真实文件 IO 永不完成，`await write` 挂死会导致脏标记补写轮永不触发。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/player/playback_payload.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/player/player_session_persister.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

/// 窄接口假宿主：几十行，独立于 Riverpod / 播放器。
class _FakeHost implements PlaybackSessionPersisterHost {
  _FakeHost();

  @override
  PlayerState state = PlayerState();

  // ignore: annotate_overrides
  bool mounted = true;

  final PlaybackPayloadEncoder encoder = PlaybackPayloadEncoder();
  @override
  PlaybackPayloadEncoder get payloadEncoder => encoder;

  @override
  QueueOrigin? queueOrigin;

  Map<String, dynamic>? Function() onFetchServer = () => null;
  @override
  Future<Map<String, dynamic>?> fetchLocalQueueForRestore() async =>
      onFetchServer();

  int syncQueueCalls = 0;
  @override
  Future<void> syncLocalQueueNow() async => syncQueueCalls++;

  final List<String> playCalls = <String>[];
  final List<Duration?> playInitialPositions = <Duration?>[];
  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool autoPlay = true,
    Duration? initialPosition,
  }) async {
    playCalls.add(song.id);
    playInitialPositions.add(initialPosition);
  }

  final List<PlaybackMode> modeCalls = <PlaybackMode>[];
  @override
  Future<void> setPlaybackMode(PlaybackMode mode, {bool persist = true}) async {
    modeCalls.add(mode);
  }
}

/// 写盘观察：`debugBeforePersistWrite` 计数 + 可选首写门控。
class _WriteProbe {
  int count = 0;
  Completer<void>? gate;
  bool gateArmed = false;

  Future<void> Function() get hook => () async {
        count++;
        if (gateArmed) {
          gateArmed = false;
          gate ??= Completer<void>();
          await gate!.future;
        }
      };

  /// 放行被门控的那一轮写。
  void release() {
    gate?.complete();
    gate = null;
  }
}

Song song([String id = 's1']) => Song(
      id: id,
      title: '测试曲$id',
      artist: '歌手',
      albumId: 'al1',
      duration: 200,
    );

PlayerState stateWith({
  List<Song>? queue,
  int index = 0,
  bool isPlaying = false,
}) =>
    PlayerState(
      queue: queue ?? <Song>[song()],
      currentIndex: index,
      currentSong: (queue ?? <Song>[song()]).isNotEmpty
          ? (queue ?? <Song>[song()])[index]
          : null,
      isPlaying: isPlaying,
      position: const Duration(seconds: 3),
      duration: const Duration(seconds: 200),
      volume: 0.4,
      playbackMode: PlaybackMode.all,
    );

/// 本地会话 payload（与磁盘上「上一次退出留下的旧会话」同一形状）。
Map<String, dynamic> localSession(
  PlaybackPayloadEncoder encoder, {
  required String songId,
  required Duration position,
  required int nowMs,
}) =>
    encoder.buildSession(
      queue: <Song>[song(songId)],
      currentIndex: 0,
      currentSongId: songId,
      position: position,
      duration: const Duration(seconds: 200),
      isPlaying: false,
      nowMs: nowMs,
      queueOrigin: null,
    )!;

void main() {
  Directory? dir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('b51a_persister');
    // 每用例独立存储目录：不注入时 JsonFileStore 走 path_provider 通道，
    // 测试环境直接挂死（session_teardown_test 实测教训）。
    JsonFileStore.instance.debugDirectory = dir;
  });

  tearDown(() async {
    // 先摘注入再删目录：残留的 fire-and-forget 写只能落到兜底临时目录，
    // 不会飘进下一个用例（session_teardown_test 同款拆卸顺序）。
    JsonFileStore.instance.debugDirectory = null;
    try {
      dir?.deleteSync(recursive: true);
    } catch (_) {}
    dir = null;
  });

  group('并发写合并（脏标记补写契约）', () {
    // 真异步：fakeAsync 里真实文件 IO（writeString/tmp.rename）永不完成，
    // `await write` 挂死会让「第一轮完成后自动补写」永不触发。
    test('B1 写进行中再请求 → 本轮完成后自动补写最新状态（落盘回读）', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('a')]);
      final persister = PlaybackSessionPersister(host);
      final probe = _WriteProbe()..gateArmed = true;
      persister.debugBeforePersistWrite = probe.hook;

      final first = persister.persistPlaybackSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probe.count, 1, reason: '第一轮已走到写盘点');

      // 第一轮还挂着，第二轮请求必须被 defer（不并发写）。
      final second = persister.persistPlaybackSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probe.count, 1, reason: '并发写被跳过并标记脏');

      // 第一轮放行后，自动补一轮「最新 state」的写。
      host.state = stateWith(queue: <Song>[song('a'), song('b')], index: 1);
      probe.release();
      await Future.wait(<Future<void>>[first, second]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(probe.count, 2, reason: '脏标记必须在第一轮完成后触发补写');

      // 补写落盘的必须是**最新**状态（index=1），不是第一轮飞在半空的旧状态。
      final session = await LocalStorage.getPlaybackSession();
      expect(session, isNotNull);
      expect(session!['currentIndex'], 1);
      expect((session['queue'] as List).length, 2);
    });
  });

  group('恢复（竞速 / 代际守卫 / 闸门）', () {
    test('C1 本地源恢复：起播 + 队列镜像 + 恢复后立即回写一轮', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      final probe = _WriteProbe();
      persister.debugBeforePersistWrite = probe.hook;

      // 预置本地会话（走同一套 save/get API，保证 roundtrip 兼容）。
      await LocalStorage.savePlaybackSession(
        localSession(host.encoder, songId: 'x', position: const Duration(seconds: 7), nowMs: 1000),
      );

      await persister.restorePlaybackSession();

      expect(host.playCalls, <String>['x'], reason: '本地源恢复必须起播预置歌曲');
      expect(
        host.playInitialPositions.single,
        const Duration(seconds: 7),
        reason: '本地源恢复必须带 initialPosition（走 pendingSeek 管线落位）',
      );
      expect(host.syncQueueCalls, 1, reason: '本地为准时必须把队列镜像给服务端');
      expect(host.modeCalls, isEmpty, reason: '本地源不改播放模式');
      expect(probe.count, 1, reason: '恢复完成后必须立即回写本地会话');
      expect(persister.isRestoringPlaybackSession, isFalse);
    });

    test('C2 服务端快照更新 → 采用服务端队列、不镜像、恢复播放模式', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      final probe = _WriteProbe();
      persister.debugBeforePersistWrite = probe.hook;

      host.onFetchServer = () => <String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{
                'songId': 'srv-1',
                'title': '服务端曲',
                'artist': '歌手',
                'albumId': 'al1',
                'duration': 180,
              },
            ],
            'currentIndex': 0,
            'total': 1,
            'playMode': 'shuffle',
            'updatedAt': 999999,
          };

      await persister.restorePlaybackSession();

      expect(host.playCalls, <String>['srv-1'], reason: '服务端快照更新时必须采用服务端队列');
      expect(
        host.playInitialPositions.single,
        isNull,
        reason: '服务端源不带 initialPosition（服务端 position 走既有同步链路）',
      );
      expect(host.modeCalls, <PlaybackMode>[PlaybackMode.shuffle],
          reason: '必须恢复服务端播放模式');
      expect(host.syncQueueCalls, 0, reason: '服务端为准时不回推（避免 MB 级冗余上行）');
      expect(probe.count, 1, reason: '服务端胜出也必须回写本地会话（两侧一致）');
    });

    test('C3 代际守卫：恢复途中会话归零 → 整段作废 + 补写会话', () async {
      final host = _FakeHost()..state = stateWith(queue: <Song>[song('x')]);
      final persister = PlaybackSessionPersister(host);
      final probe = _WriteProbe()..gateArmed = true;
      persister.debugBeforePersistWrite = probe.hook;

      await LocalStorage.savePlaybackSession(
        localSession(host.encoder, songId: 'x', position: Duration.zero, nowMs: 1000),
      );

      // 挂起在「即将起播」前，模拟恢复进行中本机被销毁。
      final resumeGate = Completer<void>();
      persister.debugBeforeRestoreResume = () => resumeGate.future;
      final restoring = persister.restorePlaybackSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 恢复期间落盘请求必须被闸门拦下。
      persister.schedulePersist();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probe.count, 0, reason: '恢复进行中 schedulePersist 必须被闸门跳过');

      persister.bumpSessionGeneration();
      resumeGate.complete();
      await restoring;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(persister.debugRestoreAbortCount, 1, reason: '代际守卫必须拦下恢复');
      expect(host.playCalls, isEmpty, reason: '被作废的恢复不得起播');
      expect(probe.count, 1, reason: '作废分支 finally 必须立即补写一次（会话已结束）');
      expect(persister.isRestoringPlaybackSession, isFalse);
    });
  });

  // ⚠️ 本 group 必须排在文件**最后**：fakeAsync 虚拟时钟内发起的真实文件写
  // 永不完成（IO 事件不由虚拟时钟推进），而 JsonFileStore.writeString 对同键
  // 写做了队列串行化 —— 遗留的挂死写会占住队列，卡死**后续所有**落盘用例
  // （本文件 B1/C1/C3 曾因此集体超时，实测 2026-10-14）。放在末尾后，遗留写
  // 在 fakeAsync zone 退出后由真实事件循环自然完成/落空，不再污染任何用例。
  group('调度防抖（与抽取前一致：5s 一次、immediate 取消防抖）', () {
    test('A1 防抖 5s：4.9s 不写、到点写一轮；重复调度不叠加 Timer', () {
      fakeAsync((async) {
        final host = _FakeHost()..state = stateWith();
        final persister = PlaybackSessionPersister(host);
        final probe = _WriteProbe();
        persister.debugBeforePersistWrite = probe.hook;

        persister.schedulePersist();
        persister.schedulePersist();
        persister.schedulePersist();
        async.elapse(const Duration(milliseconds: 4900));
        expect(probe.count, 0, reason: '防抖窗口内不得写盘');

        async.elapse(const Duration(milliseconds: 100));
        expect(probe.count, 1, reason: '5s 到点写一轮；三次调度合并为一次');
        async.elapse(const Duration(seconds: 10));
        expect(probe.count, 1, reason: '只应有一颗防抖 Timer');
      });
    });

    test('A2 immediate 立即写一轮，并取消挂起的防抖 Timer', () {
      fakeAsync((async) {
        final host = _FakeHost()..state = stateWith();
        final persister = PlaybackSessionPersister(host);
        final probe = _WriteProbe();
        persister.debugBeforePersistWrite = probe.hook;

        persister.schedulePersist();
        persister.schedulePersist(immediate: true);
        async.flushMicrotasks();
        expect(probe.count, 1, reason: 'immediate 必须立即写');

        async.elapse(const Duration(seconds: 10));
        expect(probe.count, 1, reason: '挂起的防抖 Timer 必须已被取消');
      });
    });
  });
}
