// batch50-G：ADR-2「阶段 1：策略/协作者外提」的**纯策略**单测。
//
// 覆盖范围（零成本可测，不需要宿主 provider / fake 平台）：
//   · lib/providers/player/player_watchdog_policy.dart
//       classifyStreamLoadStuck / streamLoadStuckCeilingMs /
//       isInNearEndWindow / isNearEndCompletionEngaged /
//       nextStartupStuckTicks / nextStagnantTicks / nextNearEndStuckTicks /
//       hasLeftStartup
//   · lib/providers/player/player_queue_policy.dart
//       resolveRestoredQueueIndex / isSameQueueBySongId
//
// 为什么这些能纯测：ADR-2 阶段 1 把原先内联在 `part` mixin（库私有、单测不可达）
// 里的**判定**逐字搬运为顶层纯函数，宿主只负责读写字段。故这里对判定做确定性
// 覆盖；宿主侧行为等价性仍由既有 provider 回归（test/providers/player/*）兜底。
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/player_queue_policy.dart';
import 'package:musicflow_client/providers/player/player_watchdog_policy.dart';

Song _song(String id) => Song(id: id, title: '曲$id');

void main() {
  group('一、classifyStreamLoadStuck：流加载卡死三档归一', () {
    test('idle + 播放意图 + 位置≈0 + duration 零/空 → idleNeverTookSource', () {
      for (final duration in <Duration?>[null, Duration.zero]) {
        expect(
          classifyStreamLoadStuck(
            processing: ProcessingState.idle,
            wantsPlaying: true,
            sourcePlayerPos: Duration.zero,
            playerDuration: duration,
          ),
          StreamLoadStuckLevel.idleNeverTookSource,
        );
      }
    });

    test('idle 但 duration 非零 → none（idle 档要求 duration 零，避免误判）', () {
      expect(
        classifyStreamLoadStuck(
          processing: ProcessingState.idle,
          wantsPlaying: true,
          sourcePlayerPos: Duration.zero,
          playerDuration: const Duration(seconds: 200),
        ),
        StreamLoadStuckLevel.none,
      );
    });

    test('idle 但无播放意图 → none（卡死前提是「期望在播」）', () {
      expect(
        classifyStreamLoadStuck(
          processing: ProcessingState.idle,
          wantsPlaying: false,
          sourcePlayerPos: Duration.zero,
          playerDuration: Duration.zero,
        ),
        StreamLoadStuckLevel.none,
      );
    });

    test('loading + 播放意图 + 位置零前进 → loadingNoProgress（刻意不看 duration）', () {
      // 即便已带非零 duration（libmpv 一打开就有时长）也必须落 loading 档。
      expect(
        classifyStreamLoadStuck(
          processing: ProcessingState.loading,
          wantsPlaying: true,
          sourcePlayerPos: const Duration(milliseconds: 400),
          playerDuration: const Duration(seconds: 200),
        ),
        StreamLoadStuckLevel.loadingNoProgress,
      );
    });

    test('loading 但位置已越过 1.5s → none（已有进展，非零前进）', () {
      expect(
        classifyStreamLoadStuck(
          processing: ProcessingState.loading,
          wantsPlaying: true,
          sourcePlayerPos: const Duration(milliseconds: 1600),
          playerDuration: null,
        ),
        StreamLoadStuckLevel.none,
      );
    });

    test('ready / 其它正常态 → none', () {
      expect(
        classifyStreamLoadStuck(
          processing: ProcessingState.ready,
          wantsPlaying: true,
          sourcePlayerPos: Duration.zero,
          playerDuration: Duration.zero,
        ),
        StreamLoadStuckLevel.none,
      );
    });

    test('起点门限边界：正好 1.5s 仍算「起点」，越过即 not-at-start', () {
      expect(
        classifyStreamLoadStuck(
          processing: ProcessingState.loading,
          wantsPlaying: true,
          sourcePlayerPos: const Duration(milliseconds: 1500),
          playerDuration: null,
        ),
        StreamLoadStuckLevel.loadingNoProgress,
      );
      expect(
        classifyStreamLoadStuck(
          processing: ProcessingState.loading,
          wantsPlaying: true,
          sourcePlayerPos: const Duration(milliseconds: 1501),
          playerDuration: null,
        ),
        StreamLoadStuckLevel.none,
      );
    });
  });

  group('二、streamLoadStuckCeilingMs：三档上界优先级', () {
    test('idle 档取 idle 上界、loading 档取 noProgress 上界、none 取兜底', () {
      expect(
        streamLoadStuckCeilingMs(
          level: StreamLoadStuckLevel.idleNeverTookSource,
          idleNeverTookSourceMs: 10000,
          loadingNoProgressMs: 30000,
          fallbackMs: 1800000,
        ),
        10000,
      );
      expect(
        streamLoadStuckCeilingMs(
          level: StreamLoadStuckLevel.loadingNoProgress,
          idleNeverTookSourceMs: 10000,
          loadingNoProgressMs: 30000,
          fallbackMs: 1800000,
        ),
        30000,
      );
      expect(
        streamLoadStuckCeilingMs(
          level: StreamLoadStuckLevel.none,
          idleNeverTookSourceMs: 10000,
          loadingNoProgressMs: 30000,
          fallbackMs: 1800000,
        ),
        1800000,
      );
    });
  });

  group('三、近末尾窗口 / 结束判定', () {
    test('isInNearEndWindow：总时长须 > 3s 且剩余 ≤ 2.5s', () {
      // 剩余正好 2.5s → true
      expect(
        isInNearEndWindow(
          duration: const Duration(seconds: 200),
          position: const Duration(seconds: 197, milliseconds: 500),
        ),
        isTrue,
      );
      // 剩余 2.501s → false
      expect(
        isInNearEndWindow(
          duration: const Duration(seconds: 200),
          position: const Duration(milliseconds: 197499),
        ),
        isFalse,
      );
      // 总时长正好 3s（不 > 3s）→ false
      expect(
        isInNearEndWindow(
          duration: const Duration(seconds: 3),
          position: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('isNearEndCompletionEngaged：在窗内且（在播 或 位置已达末尾）', () {
      const dur = Duration(seconds: 200);
      const nearEnd = Duration(seconds: 199);
      // 在播 → true
      expect(
        isNearEndCompletionEngaged(
          duration: dur,
          position: nearEnd,
          playing: true,
        ),
        isTrue,
      );
      // 不在播但位置已到声明末尾 → 仍算结束（Windows EOF 场景）。
      expect(
        isNearEndCompletionEngaged(
          duration: dur,
          position: dur,
          playing: false,
        ),
        isTrue,
      );
      // 不在播且位置未到末尾 → false
      expect(
        isNearEndCompletionEngaged(
          duration: dur,
          position: nearEnd,
          playing: false,
        ),
        isFalse,
      );
    });

    test('isNearEndCompletionEngaged：窗口外一律 false', () {
      expect(
        isNearEndCompletionEngaged(
          duration: const Duration(seconds: 200),
          position: const Duration(seconds: 100),
          playing: true,
        ),
        isFalse,
      );
    });
  });

  group('四、计数转移（含 tickWeight 加权）', () {
    test('nextStartupStuckTicks：全条件命中才加权累加，否则清零', () {
      expect(
        nextStartupStuckTicks(
          current: 3,
          tickWeight: 4,
          wantsPlaying: true,
          atStart: true,
          hasNoProgress: true,
          inSeekSettle: false,
          preserveSeekPosition: false,
        ),
        7,
      );
      // 逐项否定 → 0
      for (final broken in <int>[0, 1, 2, 3, 4]) {
        expect(
          nextStartupStuckTicks(
            current: 3,
            tickWeight: 4,
            wantsPlaying: broken != 0,
            atStart: broken != 1,
            hasNoProgress: broken != 2,
            inSeekSettle: broken == 3,
            preserveSeekPosition: broken == 4,
          ),
          0,
        );
      }
    });

    test('nextStagnantTicks：起点清零；未前进且确实在播才加权累加', () {
      // atStart → 0
      expect(
        nextStagnantTicks(
          current: 9,
          tickWeight: 1,
          atStart: true,
          stallSignal: true,
          deltaMs: 0,
        ),
        0,
      );
      // 无 in-play 信号 → 0
      expect(
        nextStagnantTicks(
          current: 9,
          tickWeight: 1,
          atStart: false,
          stallSignal: false,
          deltaMs: 0,
        ),
        0,
      );
      // 位置前进 > 150ms → 0
      expect(
        nextStagnantTicks(
          current: 9,
          tickWeight: 1,
          atStart: false,
          stallSignal: true,
          deltaMs: 151,
        ),
        0,
      );
      // 恰好 150ms 容差内 → 累加（并加权）
      expect(
        nextStagnantTicks(
          current: 9,
          tickWeight: 4,
          atStart: false,
          stallSignal: true,
          deltaMs: 150,
        ),
        13,
      );
    });

    test('nextNearEndStuckTicks：末段已结束 + 未前进 + 非 seek 宽限才累加', () {
      expect(
        nextNearEndStuckTicks(
          current: 1,
          tickWeight: 1,
          endEngaged: true,
          deltaMs: 100,
          inSeekSettle: false,
        ),
        2,
      );
      // seek 宽限内 → 0
      expect(
        nextNearEndStuckTicks(
          current: 1,
          tickWeight: 1,
          endEngaged: true,
          deltaMs: 100,
          inSeekSettle: true,
        ),
        0,
      );
      // 位置前进 → 0
      expect(
        nextNearEndStuckTicks(
          current: 1,
          tickWeight: 1,
          endEngaged: true,
          deltaMs: 151,
          inSeekSettle: false,
        ),
        0,
      );
      // 未 engaged → 0
      expect(
        nextNearEndStuckTicks(
          current: 4,
          tickWeight: 4,
          endEngaged: false,
          deltaMs: 0,
          inSeekSettle: false,
        ),
        0,
      );
    });

    test('hasLeftStartup：越过 1.5s 门限才为真', () {
      expect(hasLeftStartup(const Duration(milliseconds: 1500)), isFalse);
      expect(hasLeftStartup(const Duration(milliseconds: 1501)), isTrue);
    });
  });

  group('五、队列策略：恢复落点索引', () {
    test('空队列 → 0', () {
      expect(
        resolveRestoredQueueIndex(
          queue: <Song>[],
          preferredIndex: 5,
          currentSongId: 'a',
        ),
        0,
      );
    });

    test('preferredIndex 合法且命中 currentSongId → 直接用 preferredIndex', () {
      final queue = <Song>[_song('a'), _song('b'), _song('c')];
      expect(
        resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: 1,
          currentSongId: 'b',
        ),
        1,
      );
    });

    test('preferredIndex 未命中 → 按 id 在队列中首次匹配', () {
      final queue = <Song>[_song('a'), _song('b'), _song('c')];
      expect(
        resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: 0,
          currentSongId: 'c',
        ),
        2,
      );
    });

    test('id 未命中：preferredIndex 越界按下/上界夹取', () {
      final queue = <Song>[_song('a'), _song('b'), _song('c')];
      expect(
        resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: -3,
          currentSongId: 'zzz',
        ),
        0,
      );
      expect(
        resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: 99,
          currentSongId: 'zzz',
        ),
        2,
      );
      expect(
        resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: 1,
          currentSongId: 'zzz',
        ),
        1,
      );
    });

    test('无 currentSongId：直接夹取 preferredIndex', () {
      final queue = <Song>[_song('a'), _song('b')];
      expect(
        resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: 1,
          currentSongId: null,
        ),
        1,
      );
      expect(
        resolveRestoredQueueIndex(
          queue: queue,
          preferredIndex: -1,
          currentSongId: '',
        ),
        0,
      );
    });
  });

  group('六、队列策略：同一性判定', () {
    test('identical → true（快捷路径）', () {
      final queue = <Song>[_song('a'), _song('b')];
      expect(isSameQueueBySongId(queue, queue), isTrue);
    });

    test('同 id 序列（不同实例）→ true', () {
      expect(
        isSameQueueBySongId(
          <Song>[_song('a'), _song('b')],
          <Song>[_song('a'), _song('b')],
        ),
        isTrue,
      );
    });

    test('长度不同 → false', () {
      expect(
        isSameQueueBySongId(
          <Song>[_song('a')],
          <Song>[_song('a'), _song('b')],
        ),
        isFalse,
      );
    });

    test('同位 id 不同 → false', () {
      expect(
        isSameQueueBySongId(
          <Song>[_song('a'), _song('b')],
          <Song>[_song('a'), _song('c')],
        ),
        isFalse,
      );
    });
  });

  // §4.2 P2「头等待窗口 ↔ 客户端看门狗阈值对齐」的契约守卫（j1）。
  //
  // 服务端冷启动整曲缓冲时最多挂起 `STREAM_BUFFER_HEAD_WAIT_MS`（默认 6s）再回退直通；
  // 客户端「平台未接管音源(idle)」一档的判死上界必须**严格大于**它并留足余量，
  // 否则服务端仍在合法缓冲窗口内、客户端已抢先判死 → 无谓 reload/跳歌。
  // 本组把该不变式钉死：任一侧调常量导致余量不足都会让此用例失败（变异验证）。
  group('六、跨仓契约：首字节等待 vs idle 判死上界（j1）', () {
    test('idle 判死上界 - 服务端首字节等待 ≥ 契约余量下界', () {
      expect(
        kStreamLoadIdleCeilingMs - kServerStreamBufferHeadWaitMs,
        greaterThanOrEqualTo(kStreamLoadHeadWaitAlignmentMarginMs),
      );
    });

    test('idle 判死上界严格大于服务端首字节等待（零余量即回归）', () {
      expect(kStreamLoadIdleCeilingMs, greaterThan(kServerStreamBufferHeadWaitMs));
    });

    test('loading 档上界须容纳「首字节等待 + ffmpeg 起播」，远大于 idle 档', () {
      expect(
        kStreamLoadNoProgressCeilingMs,
        greaterThan(kStreamLoadIdleCeilingMs),
      );
      // 冷启动合法最坏 ≈ 首字节等待 + 起播；30s 需明显高于 6s 头等待。
      expect(
        kStreamLoadNoProgressCeilingMs,
        greaterThan(kServerStreamBufferHeadWaitMs * 2),
      );
    });

    test('兜底上界 > loading 档（安全网必须最宽）', () {
      expect(
        kStreamLoadFallbackCeilingMs,
        greaterThan(kStreamLoadNoProgressCeilingMs),
      );
    });

    test('三档选择函数返回对应常量（默认值注入自洽）', () {
      expect(
        streamLoadStuckCeilingMs(
          level: StreamLoadStuckLevel.idleNeverTookSource,
          idleNeverTookSourceMs: kStreamLoadIdleCeilingMs,
          loadingNoProgressMs: kStreamLoadNoProgressCeilingMs,
          fallbackMs: kStreamLoadFallbackCeilingMs,
        ),
        kStreamLoadIdleCeilingMs,
      );
      expect(
        streamLoadStuckCeilingMs(
          level: StreamLoadStuckLevel.loadingNoProgress,
          idleNeverTookSourceMs: kStreamLoadIdleCeilingMs,
          loadingNoProgressMs: kStreamLoadNoProgressCeilingMs,
          fallbackMs: kStreamLoadFallbackCeilingMs,
        ),
        kStreamLoadNoProgressCeilingMs,
      );
      expect(
        streamLoadStuckCeilingMs(
          level: StreamLoadStuckLevel.none,
          idleNeverTookSourceMs: kStreamLoadIdleCeilingMs,
          loadingNoProgressMs: kStreamLoadNoProgressCeilingMs,
          fallbackMs: kStreamLoadFallbackCeilingMs,
        ),
        kStreamLoadFallbackCeilingMs,
      );
    });
  });
}
