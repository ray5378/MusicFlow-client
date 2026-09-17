// 「会话归零」的**残留清理**契约 —— 上一轮孤儿状态修复没做干净的那两块。
//
// 背景（用户实测，2026-09-17）：把本机播放器拖进回收站销毁后
//   ✅ 队列清了、迷你条歌名/进度/时长也没了（上一轮 6a79b23 修的）；
//   ❌ 但客户端仍留着两份孤儿状态：
//      ① 歌单/专辑列表页封面上的「正在播放」指示还亮着（queueOriginProvider
//         没人清 —— 它不在 PlayerState 里，clearQueue 照顾不到）；
//      ② 重启客户端，刚销毁的那首歌又回来了（磁盘上的 playback_session_v1
//         还留着清空前的旧会话：落盘有 5s 防抖，销毁后立刻退出就写不进去；
//         又或者落盘请求撞上「上一轮还在写」被静默丢弃）。
//
// 本文件把这几条契约钉死，全部**驱动真实 PlayerNotifier**（不复用
// test/features/player/test_player_notifier.dart 那个替身 —— 上一轮的教训就是
// 替身把「应该怎样」写对了，真实实现静默偏离）。
//
//   A. 来源残留：整份会话归零 → 来源必须一起清；「只清后续」的本地语义不能动。
//   B. 落盘残留：销毁后不等 5s 防抖就落地；撞上并发写不许丢；退出前要等掉
//      飞行中的那一轮。
//   C. 恢复残留：恢复途中被销毁 → 整段作废（销毁是终结语义，恢复无权复活它）；
//      没被销毁的恢复不能被守卫误伤。
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
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

Song _song(String id) => Song(
  id: id,
  title: '曲$id',
  artist: '歌手',
  albumId: 'al1',
  duration: 200,
);

/// 一个「正在播第 2 首」的完整会话（与队列清空测试同一形状）。
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

/// 磁盘上「上一次退出时留下的旧会话」。
Map<String, dynamic> _staleSession({int updatedAt = 1700000000000}) =>
    <String, dynamic>{
      'version': 1,
      'queue': <Map<String, dynamic>>[
        _song('s1').toJson(),
        _song('s2').toJson(),
      ],
      'currentIndex': 1,
      'currentSongId': 's2',
      'positionMs': 42000,
      'isPlaying': true,
      'updatedAt': updatedAt,
      'queueOrigin': const {'kind': 'playlist', 'id': 'pl-42'},
    };

/// C2 用的哨兵异常：让恢复在「起播前夜」就地收尾，不去跑 playSong 的深路径。
///
/// 会被 `_restorePlaybackSession` 自己的 catch 吞掉并记一条 warn 日志（属于它的
/// 容错路径），因此不会污染用例结果。
class _StopRestoreForTest implements Exception {
  const _StopRestoreForTest();

  @override
  String toString() => 'stop-restore-for-test';
}

/// 单个用例的 PlayerNotifier 承载器：**存储目录隔离 + 确定性拆卸**。
///
/// 为什么需要它（实测教训，2026-09-17）：`PlayerNotifier.dispose()` 末尾有一次
/// fire-and-forget 的「退出落盘」，而落盘解析目录读的是**全局**的
/// `JsonFileStore.debugDirectory`。若用例 A 的这次写飘到用例 B 运行期间，它就把
/// A 的状态写进了 B 的目录 —— 症状是 B1「清空后磁盘应为空」在 A 组之后必然失败，
/// 而单独跑 B1 却通过（探针里同一个前置条件稳定通过，就是这条污染）。
///
/// 拆卸顺序是刻意的三步：① 先把本用例的状态就地落盘（此刻目录还是本用例的），
/// ② 再摘掉目录注入，③ 最后才 dispose —— 于是 dispose 里那次退出落盘只能落到
/// 「无注入目录」的兜底临时目录，不可能飘进下一个用例。
class _Harness {
  _Harness._(this.dir, this.container, this.notifier);

  final Directory dir;
  final ProviderContainer container;
  final PlayerNotifier notifier;

  /// 注入独立存储目录 → （可选）铺磁盘前置 → 起容器（构造期即开始会话恢复）。
  ///
  /// [seed] 运行在「目录已注入、容器未构造」之间：C 组要在容器构造**之前**把旧
  /// 会话铺好，构造期的恢复才看得见它。
  static Future<_Harness> boot(
    String prefix, {
    Future<void> Function()? seed,
  }) async {
    final dir = Directory.systemTemp.createTempSync(prefix);
    JsonFileStore.instance.debugDirectory = dir;
    if (seed != null) await seed();

    final container = ProviderContainer();
    final notifier = container.read(playerProvider.notifier);

    addTearDown(() async {
      // 挂起钩子先摘掉：用例中途失败时，残留的 gate 会让下面的落地等到超时。
      notifier.debugBeforePersistWrite = null;
      notifier.debugBeforeRestoreResume = null;
      try {
        await notifier
            .persistPlaybackStateNow()
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // 用例失败路径上超时是允许的：目的是别把写留到下一个用例。
      }
      JsonFileStore.instance.debugDirectory = null;
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    return _Harness._(dir, container, notifier);
  }

  /// 磁盘上的会话文件（断言「有没有残留」用它，比解析 JSON 更直接）。
  File get sessionFile =>
      File('${dir.path}${Platform.pathSeparator}playback_session_v1.json');
}

/// 轮询等待（真实定时器；plain `test` 不走 fakeAsync，安全）。
Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration budget = const Duration(seconds: 3),
  String reason = 'condition not met in time',
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason);
}

/// 等一个 PlayerNotifier「安静下来」：会话恢复不再进行，且连续 [quiet] 时长
/// 内都没有再进入恢复。
///
/// 为什么不直接用「`!debugIsRestoringPlaybackSession`」当信号：构造期恢复起步
/// 在 `_init()` 的若干 await 之后，容器刚建好的那一瞬它是 **false**（恢复还没
/// 开始）—— 拿它当「已结束」会误判，恢复随后才启动，正好在测试体里把队列
/// 恢复上屏。所以要求「false 且持续安静」。
Future<void> _quiet(
  PlayerNotifier notifier, {
  Duration quiet = const Duration(milliseconds: 500),
  Duration budget = const Duration(seconds: 25),
}) async {
  final deadline = DateTime.now().add(budget);
  var quietSince = DateTime.now();
  while (DateTime.now().isBefore(deadline)) {
    if (notifier.debugIsRestoringPlaybackSession) {
      quietSince = DateTime.now();
    } else if (DateTime.now().difference(quietSince) >= quiet) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('PlayerNotifier 在预算内没有安静下来（构造期恢复疑似挂住）');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 平台隔离：伪装 linux，让 _init() 走「桌面 = 不起 AudioService」分支
    // （android 分支的 AudioService.init 会在测试里抛出脱离 try/catch 的
    // 异步异常，与被测逻辑无关）。同 queue_clear_test 的姿势。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  // ──────────────────────────────────────────────────────────────────
  // A. 队列来源残留（列表页封面「正在播放」指示）
  // ──────────────────────────────────────────────────────────────────
  group('A. 整份会话归零时队列来源一起清', () {
    late _Harness h;

    setUp(() async {
      // A 组不验磁盘，但**仍要走隔离目录 + 确定性拆卸**：它留下的「退出落盘」
      // 带着 queue=[s2] 这类非空状态，飘进 B 组就会把 B 的目录写脏（见 _Harness
      // 的注释 —— B1 曾因此在 A 组之后必失败）。
      h = await _Harness.boot('mf_session_origin_');
      await Future<void>.delayed(Duration.zero);
      h.notifier.state = _playingSession();
      h.container.read(queueOriginProvider.notifier).state = const QueueOrigin(
        QueueOriginKind.playlist,
        'pl-42',
      );
      expect(
        h.container.read(queueOriginProvider)?.id,
        'pl-42',
        reason: '测试前置：来源已注入',
      );
    });

    test('A1. clearQueue(keepCurrent: false) 清掉来源（销毁本机不再留「正在播放」指示）', () async {
      await h.notifier.clearQueue(keepCurrent: false);

      expect(
        h.container.read(queueOriginProvider),
        isNull,
        reason: '队列都空了，来源还挂着 → 歌单/专辑列表封面那首已停的歌继续亮着',
      );
    });

    test('A2. clearQueue(keepCurrent: true) 保留来源（本地清空按钮的既有语义不能动）', () async {
      await h.notifier.clearQueue(keepCurrent: true);

      expect(h.container.read(playerProvider).currentSong?.id, 's2');
      expect(
        h.container.read(queueOriginProvider)?.id,
        'pl-42',
        reason: '还在放这首歌，来源仍有意义 —— 这条语义本轮不改',
      );
    });

    test('A3. removeFromQueue(当前项) 同样清掉来源（当前曲被移除 = 本会话无曲）', () {
      h.notifier.removeFromQueue(1); // s2 就是当前曲

      expect(h.container.read(playerProvider).currentSong, isNull);
      expect(h.container.read(queueOriginProvider), isNull);
    });

    test('A4. removeFromQueue(非当前项) 不动来源', () {
      h.notifier.removeFromQueue(0); // 移除 s1，当前曲仍是 s2

      expect(h.container.read(playerProvider).currentSong?.id, 's2');
      expect(h.container.read(queueOriginProvider)?.id, 'pl-42');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // B. 磁盘上的旧会话残留
  // ──────────────────────────────────────────────────────────────────
  group('B. 会话归零必须真的落到磁盘上', () {
    late _Harness h;

    setUp(() async {
      h = await _Harness.boot('mf_session_teardown_');

      // ① 先让构造期的会话恢复跑完。此刻磁盘为空 → 恢复空手而归，不会跟测试体
      //    抢状态。（这一步刻意不铺旧会话：恢复的收尾回写、服务端快照探测都是
      //    异步长流程，铺了旧会话就得跟它对时序 —— 那正是上一版用例卡死/flaky
      //    的来源。）
      await _quiet(h.notifier);
      await LocalStorage.clearPlaybackSession();

      // ② 干净起点之后，再铺一份「上次退出留下的旧会话」。它此刻只是磁盘上的
      //    一个文件，构造完的 notifier 已经不会再碰它；B 组要验的正是「会话归零
      //    能不能把这份残留清掉」。
      await LocalStorage.savePlaybackSession(_staleSession(updatedAt: 1000));

      h.notifier.state = _playingSession();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('B1. 销毁后立刻落盘 —— 不等 5s 防抖（销毁后马上退出也不复活）', () async {
      expect(
        h.sessionFile.existsSync(),
        isTrue,
        reason: '测试前置：磁盘上必须有一份待清掉的旧会话',
      );

      await h.notifier.clearQueue(keepCurrent: false);

      // 预算 3s < 落盘防抖的 5s：能在窗口内见到文件被清掉，就证明走的是
      // 「立即落盘」而不是等防抖定时器。
      await _waitUntil(
        () async => !h.sessionFile.existsSync(),
        budget: const Duration(seconds: 3),
        reason: '销毁后磁盘上仍留着旧会话 → 下次启动把这局已结束的播放搬回来',
      );
    });

    test('B2. 落盘进行中又清空 → 补写，不清不丢', () async {
      expect(h.sessionFile.existsSync(), isTrue);

      final reached = Completer<void>();
      final gate = Completer<void>();
      h.notifier.debugBeforePersistWrite = () {
        if (!reached.isCompleted) reached.complete();
        return gate.future;
      };

      // 起一轮写：写的是「清空前」的状态，卡在 gate 里。
      final firstWrite = h.notifier.persistPlaybackStateNow();
      await reached.future;

      // 这轮写还在飞行中时，用户把本机销毁了 —— 旧实现会把这次落盘直接丢弃，
      // 磁盘上永远停着清空前的旧会话。
      await h.notifier.clearQueue(keepCurrent: false);

      gate.complete();
      await firstWrite;

      await _waitUntil(
        () async => !h.sessionFile.existsSync(),
        reason: '飞行中的写把状态又写回去了：清空这次落盘被静默丢弃',
      );
    });

    test('B3. 退出落盘要等掉飞行中的那一轮（返回时磁盘已是最终状态）', () async {
      expect(h.sessionFile.existsSync(), isTrue);

      final reached = Completer<void>();
      final gate = Completer<void>();
      h.notifier.debugBeforePersistWrite = () {
        if (!reached.isCompleted) reached.complete();
        return gate.future;
      };

      final firstWrite = h.notifier.persistPlaybackStateNow();
      await reached.future;

      await h.notifier.clearQueue(keepCurrent: false);

      // 退出落盘：gate 还没放行，所以此刻它**必须**仍在等第一轮。
      var quitDone = false;
      final quitting = h.notifier
          .persistPlaybackStateNow()
          .then((_) => quitDone = true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        quitDone,
        isFalse,
        reason: '退出落盘没等飞行中的写就返回了 —— 进程随后结束，这次写永远补不回来',
      );

      gate.complete();
      await quitting;
      await firstWrite;

      expect(
        h.sessionFile.existsSync(),
        isFalse,
        reason: '退出落盘返回时，磁盘应当已经是「会话已结束」',
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // C. 恢复流程的代际守卫
  // ──────────────────────────────────────────────────────────────────
  group('C. 恢复途中被销毁 → 恢复整段作废', () {
    late Completer<void> reached;
    late Completer<void> gate;

    setUp(() {
      reached = Completer<void>();
      gate = Completer<void>();
    });

    /// 起容器（构造期即开始恢复），并把「即将起播」的挂起钩子**同步**注入 ——
    /// 注入点必须赶在恢复流程走到那里之前：_init() 在第一个 await 处让出，
    /// 我们在这之后同步执行，时序稳定。
    Future<_Harness> bootWithGate() async {
      final h = await _Harness.boot(
        'mf_session_restore_race_',
        // 旧会话必须在容器构造**之前**铺好，构造期的恢复才看得见它。
        seed: () => LocalStorage.savePlaybackSession(_staleSession()),
      );
      h.notifier.debugBeforeRestoreResume = () {
        if (!reached.isCompleted) reached.complete();
        return gate.future;
      };
      return h;
    }

    test('C1. 卡在「即将起播」时销毁 → 恢复作废，当前曲不被复活', () async {
      final h = await bootWithGate();

      await reached.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('恢复流程没走到「即将起播」的窗口（前置不成立）'),
      ); // 恢复已卡在竞态窗口内

      await h.notifier.clearQueue(keepCurrent: false); // 此刻把本机销毁

      gate.complete(); // 放行恢复：它必须自己作废
      await _waitUntil(
        () async => !h.notifier.debugIsRestoringPlaybackSession,
        budget: const Duration(seconds: 10),
        reason: '恢复流程没结束',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final after = h.container.read(playerProvider);
      expect(
        h.notifier.debugRestoreAbortCount,
        1,
        reason: '恢复没被代际守卫拦下 —— 那它要么照旧执行、要么是别的原因失败的',
      );
      expect(
        after.currentSong,
        isNull,
        reason: '恢复把一个已经销毁的会话又挂回了当前曲 —— 用户看到「销毁没生效」',
      );
      expect(after.queue, isEmpty);
      expect(after.isPlaying, isFalse);
      await _waitUntil(
        () async => !h.sessionFile.existsSync(),
        reason: '磁盘上那份旧会话没被清掉 → 下次启动还会复活',
      );
    });

    test('C2. 正常启动的恢复不会被代际守卫拦下（守卫不误伤）', () async {
      final h = await _Harness.boot(
        'mf_session_restore_race_',
        seed: () => LocalStorage.savePlaybackSession(_staleSession()),
      );

      var reachedResume = false;
      h.notifier.debugBeforeRestoreResume = () async {
        reachedResume = true;
        // 钩子就挂在守卫**之前**：先记「恢复一路走到了起播前夜」，再抛哨兵让
        // 恢复就地收尾（异常被恢复自己的 catch 吞掉）。
        //
        // 为什么要在守卫处停下：守卫放行之后是 `playSong(...)`，要碰离线缓存 →
        // path_provider → 音源加载 → 网络。这条路在单测里既不收敛也不稳 ——
        // 实测把用例拖到数分钟「did not complete」（补 path_provider 桩只会
        // 让它真的走进更深的死路）。而本用例要钉的只是「守卫有没有误杀」。
        throw const _StopRestoreForTest();
      };

      await _waitUntil(
        () async => reachedResume,
        budget: const Duration(seconds: 15),
        reason: '恢复没走到起播前夜（读盘 / 定索引这段就不通了）',
      );
      await _waitUntil(
        () async => !h.notifier.debugIsRestoringPlaybackSession,
        budget: const Duration(seconds: 10),
        reason: '恢复被中途打断后没收尾（恢复租约会一直挂着，压住后续所有落盘）',
      );

      expect(
        h.notifier.debugRestoreAbortCount,
        0,
        reason: '没被销毁的恢复被代际守卫拦下了 —— 正常启动会丢掉上次的播放会话',
      );
    });
  });
}
