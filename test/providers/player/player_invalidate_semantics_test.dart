// `ref.invalidate(playerProvider)` 的**逐 run 语义**回归 —— ADR-2 阶段 3c
// （`playerProvider` 由 `同步通知 Provider` 迁到 `NotifierProvider`）的核心取证。
//
// 背景（为什么单独钉这个文件）：这次迁移上一轮**完整实施后又被整体回滚**，
// 根因是 riverpod 2.6.1 两者的 `invalidate` 语义不同：
//   · 旧 `同步通知 Provider`：invalidate 会**整体重建 notifier 实例** ——
//     挂在构造函数里的播放器 / AudioHandler / SMTC / 定时器 / 订阅随旧实例
//     一起被丢掉，天然不会有「旧资源残留」。
//   · `NotifierProvider`：invalidate **复用同一 notifier 实例、只重跑 `build()`**。
//     构造期建立的资源不会自动释放；更阴的是旧 run 的在途异步回调（起流 / 会话
//     恢复 / 元数据补齐）醒来后照旧 `state = ...` —— 而 state 现在指向**新 run**，
//     于是旧会话被悄悄「复活」到新 run 上。
//
// 本文件把三条契约钉死（三条都直接驱动**真实 PlayerNotifier**，不用替身）：
//   ① 旧 run 资源被释放；
//   ② 新 run 从干净起点开始；
//   ③ 上一轮在途的异步回调不再写新 run 的 state。
//
// 若把 player_provider.dart 里 `_teardownRun()` 的 `sessionPersister.dispose()`
// （或恢复流程里的 `_disposed` 守卫）删掉，D2 必然变红 —— 这正是「上次回滚那个坑」。
//
// 另有一个只在 `NotifierProvider` 下才存在、比上面更先炸的坑（本轮实测踩到）：
// `ref.invalidate` 走 `invalidateSelf()` —— **先把** `_mustRecomputeState` 置真、
// **再** `runOnDispose()` 遍历 onDispose 监听表。而 `Notifier.state` 的读值是
// `_element.flush()`，此时读它会**就地重跑 build()**，新 build 注册的 onDispose
// 回调插进正被 forEach 的监听表 → `Concurrent modification during iteration`，
// invalidate 自己就抛了（连 D1 都活不到断言）。所以拆卸回调里的读值必须走
// `PlayerNotifier` 自持的 `_stateMirror`（见 build() 里 `_tearingDown` 的注释）；
// 若把那段 `_tearingDown` 短路改成直接 `super.state`，D1/D2 会以并发修改异常爆红。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

Song _song(String id) => Song(
  id: id,
  title: '曲$id',
  artist: '歌手',
  albumId: 'al1',
  duration: 200,
);

/// 一个「正在播第 2 首」的完整会话（与 session_teardown_test 同一形状）。
PlayerState _playingSession() => PlayerState(
  currentSong: _song('s2'),
  queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
  currentIndex: 1,
  isPlaying: true,
  processingState: ProcessingState.ready,
  position: const Duration(seconds: 42),
  duration: const Duration(seconds: 200),
  bufferedPosition: const Duration(seconds: 60),
  loopMode: LoopMode.all,
  shuffleEnabled: true,
  playbackMode: PlaybackMode.shuffle,
  shuffleHistoryCount: 3,
  currentQuality: AudioQualityLevel.original,
  playbackSource: PlaybackSource.stream,
  currentBitRateKbps: 1411,
  volume: 0.35,
);

/// 磁盘上「上次退出留下的旧会话」—— D2 用它把旧 run 的恢复引到「即将起播」窗口。
Map<String, dynamic> _staleSession() => <String, dynamic>{
  'version': 1,
  'queue': <Map<String, dynamic>>[_song('s1').toJson(), _song('s2').toJson()],
  'currentIndex': 1,
  'currentSongId': 's2',
  'positionMs': 42000,
  'isPlaying': true,
  'updatedAt': 1700000000000,
  'queueOrigin': const {'kind': 'playlist', 'id': 'pl-42'},
};

/// 轮询等待（真实定时器；plain `test` 不走 fakeAsync，安全）。
Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration budget = const Duration(seconds: 10),
  String reason = 'condition not met in time',
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 同 session_teardown_test：伪装 linux，让 _init() 走「桌面 = 不起 AudioService」
    // 分支（android 分支的 AudioService.init 会在测试里抛脱离 try/catch 的异步异常）。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('D. ref.invalidate(playerProvider) 的逐 run 语义（Notifier 迁移）', () {
    late Directory dir;
    late ProviderContainer container;
    late PlayerNotifier notifier;

    /// 起容器 + 存储目录隔离 + 确定性拆卸（照搬 session_teardown_test 的 _Harness，
    /// 但要直接持有 container 以便调用 invalidate）。
    Future<void> boot({Future<void> Function()? seed}) async {
      dir = Directory.systemTemp.createTempSync('mf_player_invalidate_');
      JsonFileStore.instance.debugDirectory = dir;
      if (seed != null) await seed();

      container = ProviderContainer();
      notifier = container.read(playerProvider.notifier);

      addTearDown(() async {
        notifier.debugBeforePersistWrite = null;
        notifier.debugBeforeRestoreResume = null;
        try {
          await notifier
              .persistPlaybackStateNow()
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          // 失败路径上超时允许：目的是别把写飘到下一个用例。
        }
        JsonFileStore.instance.debugDirectory = null;
        container.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
    }

    test('D1. invalidate 释放旧 run 资源，新 run 从干净起点重建', () async {
      await boot();
      // 让首轮 _init 的同步段跑完（桌面分支下 AudioPlayer 是同步建出来的）。
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final runOnePlayer = notifier.debugAudioPlayer;
      final runOnePersister = notifier.sessionPersister;
      expect(runOnePlayer, isNotNull, reason: '测试前置：首轮应已建出播放器');
      expect(notifier.debugRunTeardownCount, 0, reason: '测试前置：还没拆卸过');

      notifier.state = _playingSession();
      expect(
        container.read(playerProvider).currentSong?.id,
        's2',
        reason: '测试前置：旧 run 上有一份非空会话',
      );

      container.invalidate(playerProvider);
      // invalidate 只标脏，重建发生在下一次 read —— 这里同步 read 触发重建。
      final fresh = container.read(playerProvider);

      // ① 旧 run 资源被释放。
      expect(
        notifier.debugRunTeardownCount,
        1,
        reason: 'invalidate 没有触发逐 run 拆卸 → 旧播放器/订阅/定时器残留',
      );
      expect(
        runOnePersister.debugDisposed,
        isTrue,
        reason: '旧协作者没被标死 → 它的在途恢复醒来仍会写回新 run',
      );
      expect(
        notifier.sessionPersister,
        isNot(same(runOnePersister)),
        reason: '协作者没换新实例 → 上一轮的在途写与新一轮共用状态',
      );
      expect(
        notifier.debugAudioPlayer,
        isNot(same(runOnePlayer)),
        reason: '播放器没重建 → 旧 run 的 AudioPlayer 被原地续用（资源没释放）',
      );
      expect(notifier.debugAudioPlayer, isNotNull, reason: '新 run 必须建好自己的播放器');

      // ② 新 run 干净起点：不能把旧 run 的会话带过来。
      expect(fresh.currentSong, isNull, reason: '新 run 起点带着旧 run 的当前曲');
      expect(fresh.queue, isEmpty, reason: '新 run 起点带着旧 run 的队列');
      expect(fresh.isPlaying, isFalse);
      expect(fresh.position, Duration.zero);
    });

    test('D2. invalidate 后，上一轮在途的恢复不再写新 run 的 state', () async {
      // 磁盘上先铺一份旧会话：首轮 _init 尾部的恢复会读到它，并被下面的 gate
      // 卡在「即将起播」窗口 —— 制造一个「旧 run 的在途异步回调」。
      await boot(seed: () => LocalStorage.savePlaybackSession(_staleSession()));

      final reached = Completer<void>();
      final gate = Completer<void>();
      notifier.debugBeforeRestoreResume = () {
        if (!reached.isCompleted) reached.complete();
        return gate.future;
      };

      await reached.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('旧 run 的恢复没走到「即将起播」窗口（前置不成立）'),
      );

      final runOnePersister = notifier.sessionPersister;

      // 趁旧 run 卡住，把磁盘上的旧会话抹掉：新 run 的恢复会看见「无会话」直接
      // 返回，不会走进 playSong 的深路径（读盘→音源→网络，在单测里既不收敛也
      // 不稳）。这样本用例只考验「旧 run 的恢复该不该复活会话」这一件事。
      await LocalStorage.clearPlaybackSession();

      container.invalidate(playerProvider);
      container.read(playerProvider); // 同步重建新 run

      // 拆卸必须已经发生，且旧协作者已被标死 —— 否则下面的放行会让它 playSong。
      expect(notifier.debugRunTeardownCount, 1);
      expect(
        runOnePersister.debugDisposed,
        isTrue,
        reason: '旧协作者没被标死：放行后它会 playSong 把那局已拆掉的会话重挂到新 run',
      );

      gate.complete(); // 放行旧 run 的恢复，它必须自己发现「已过期」并整段作废

      await _waitUntil(
        () async => !runOnePersister.isRestoringPlaybackSession,
        reason: '旧 run 的恢复没结束（放行后被挂住）',
      );

      expect(
        runOnePersister.debugRestoreAbortCount,
        1,
        reason:
            '旧 run 的恢复没被逐 run 拆卸标记拦下 —— 那它要么照旧执行、要么是别的原因失败的',
      );
      expect(
        notifier.debugRestoreAbortCount,
        0,
        reason: '新 run 的恢复被守卫误伤了（正常启动会丢掉上次的播放会话）',
      );

      // ③ 上一轮异步回调不再写新 run 的 state。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final after = container.read(playerProvider);
      expect(
        after.currentSong,
        isNull,
        reason: '上一轮的在途恢复把已作废的会话写回了新 run —— 用户看到「invalidate 没生效」',
      );
      expect(after.queue, isEmpty);
      expect(after.isPlaying, isFalse);
    });
  });
}
