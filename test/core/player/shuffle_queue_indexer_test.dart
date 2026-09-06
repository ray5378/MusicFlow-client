import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/player/shuffle_queue_indexer.dart';

void main() {
  group('ShuffleQueueIndexer - 随机「一轮内不重复」', () {
    late ShuffleQueueIndexer q;
    setUp(() => q = ShuffleQueueIndexer(random: Random(42)));

    test('空队列返回 null', () {
      expect(q.randomIndexExcludingCurrent([], 0, null), isNull);
    });

    test('单曲返回 0（因无法切到别的曲）', () {
      expect(q.randomIndexExcludingCurrent(['a'], 0, 'a'), 0);
    });

    test('排除当前索引:结果绝不等于 currentIndex', () {
      final ids = ['a', 'b', 'c', 'd', 'e'];
      for (var i = 0; i < 200; i++) {
        final idx = q.randomIndexExcludingCurrent(ids, 2, 'c')!;
        expect(idx, isNot(2));
      }
    });

    test('排除当前曲 id:结果不指向该 id 对应曲', () {
      final ids = ['a', 'b', 'c', 'd', 'e'];
      for (var i = 0; i < 200; i++) {
        final idx = q.randomIndexExcludingCurrent(ids, 0, 'a')!;
        expect(ids[idx], isNot('a'));
      }
    });

    test('一轮内不重复:播放过的不再被抽中(直到无未播可抽)', () {
      final ids = ['a', 'b', 'c', 'd', 'e'];
      // 先「播过」b、c,则只能在 a/d/e/e 中轮流抽前,绝不可再抽中 b/c。
      q.markPlayed('b');
      q.markPlayed('c');
      for (var i = 0; i < 200; i++) {
        final idx = q.randomIndexExcludingCurrent(ids, 0, 'a')!;
        expect(ids[idx], isNot(contains('b')));
        expect(ids[idx], isNot(contains('c')));
      }
    });

    test('本轮播完 allowRoundReset=true 时清空重洗并避开当前曲', () {
      final ids = ['a', 'b', 'c'];
      // 除当前曲 b(index1)外的一轮已播完:本轮无未播候选。
      q.markPlayed('a');
      q.markPlayed('c');
      final idx = q.randomIndexExcludingCurrent(ids, 1, 'b')!;
      expect(idx, isNot(1)); // 避开当前曲。
      // 已清空本轮标记:重洗后 a/c 不再是「已播」。
      expect(q.hasPlayed('a'), isFalse);
      expect(q.hasPlayed('c'), isFalse);
    });

    test('对称「非变更」取样:allowRoundReset=false 播完也不清空本轮标记', () {
      final ids = ['a', 'b', 'c'];
      q.markPlayed('a');
      q.markPlayed('c');
      // 非变更取样(预缓存)在播完后不清空标记,返回一个避开当前曲的候选。
      final idx =
          q.randomIndexExcludingCurrent(ids, 1, 'b', allowRoundReset: false)!;
      expect(idx, isNot(1));
      // 本轮标记保留以供真实切歌自行决定重洗。
      expect(q.hasPlayed('a'), isTrue);
      expect(q.hasPlayed('c'), isTrue);
    });
  });

  group('ShuffleQueueIndexer - 预缓存与真实切歌一致性', () {
    late ShuffleQueueIndexer q;
    setUp(() => q = ShuffleQueueIndexer(random: Random(7)));

    test('resolveRandomUpcomingIndexForCache 写入 precomputed,consume 消费同一索引并清空', () {
      final ids = ['a', 'b', 'c', 'd'];
      final resolved = q.resolveRandomUpcomingIndexForCache(ids, 0, 'a');
      expect(resolved, isNotNull);
      expect(q.precomputedUpcomingIndex, resolved);
      // 真实切歌消费同一索引。
      final consumed = q.consumePrecomputedUpcomingIndex(ids, 0);
      expect(consumed, resolved);
      expect(q.precomputedUpcomingIndex, isNull);
    });

    test('强制优先:forcedIndex 直接作为预缓存候选与消费值', () {
      final ids = ['a', 'b', 'c', 'd'];
      final resolved =
          q.resolveRandomUpcomingIndexForCache(ids, 0, 'a', forcedIndex: 3);
      expect(resolved, 3);
      expect(q.precomputedUpcomingIndex, 3);
      expect(q.consumePrecomputedUpcomingIndex(ids, 0), 3);
    });

    test('consume 校验失效:索引越界返回 null(并清空)', () {
      q.precomputedUpcomingIndex = 9;
      expect(q.consumePrecomputedUpcomingIndex(['a', 'b'], 0), isNull);
      expect(q.precomputedUpcomingIndex, isNull);
    });

    test('consume 校验失效:指向当前曲返回 null', () {
      q.precomputedUpcomingIndex = 2;
      expect(q.consumePrecomputedUpcomingIndex(['a', 'b', 'c'], 2), isNull);
    });
  });

  group('ShuffleQueueIndexer - 顺序与强制纯函数', () {
    test('sequentialNextIndex:中间、队尾回绕、空队列', () {
      expect(
        ShuffleQueueIndexer.sequentialNextIndex(['a', 'b', 'c'], 1),
        2,
      );
      expect(ShuffleQueueIndexer.sequentialNextIndex(['a', 'b', 'c'], 2), 0);
      expect(ShuffleQueueIndexer.sequentialNextIndex(<String>[], 0), isNull);
    });

    test('resolveForcedNextIndex:preferred 命中/跳过当前曲/找不到', () {
      final ids = ['a', 'b', 'x', 'c'];
      expect(
        ShuffleQueueIndexer.resolveForcedNextIndex(
          forcedSongId: 'x',
          forcedIndex: 2,
          queueIds: ids,
          currentIndex: 0,
        ),
        2,
      );
      // preferred 指向当前曲时按索引判定为失效。
      expect(
        ShuffleQueueIndexer.resolveForcedNextIndex(
          forcedSongId: 'b',
          forcedIndex: 1,
          queueIds: ids,
          currentIndex: 1,
        ),
        isNull,
      );
      // 未命中。
      expect(
        ShuffleQueueIndexer.resolveForcedNextIndex(
          forcedSongId: 'zzz',
          forcedIndex: null,
          queueIds: ids,
          currentIndex: 0,
        ),
        isNull,
      );
      // forcedSongId 为空。
      expect(
        ShuffleQueueIndexer.resolveForcedNextIndex(
          forcedSongId: null,
          forcedIndex: null,
          queueIds: ids,
          currentIndex: 0,
        ),
        isNull,
      );
    });
  });
}