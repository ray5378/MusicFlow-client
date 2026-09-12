import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/player/server_shuffle_sequence.dart';

void main() {
  group('ServerShuffleSequence.advance - 沿服务端权威洗牌序列推进', () {
    // 队列下标序列:order[i] 是队列中的歌曲下标。
    const order = <int>[3, 1, 0, 2];

    test('正常推进:取 startPos 后第一个可播下标', () {
      // 当前曲在序列位置 0(队列下标 3),下一首应为序列位置 1(队列下标 1)。
      expect(
        ServerShuffleSequence.advance(order, 0, (_) => false),
        1,
      );
    });

    test('跳过已知死链:连续死歌被越过,停在第一首可播', () {
      // 队列下标 1、2 是死链,从序列位置 0 推进应越过它们取到队列下标 0。
      final dead = {1, 2};
      expect(
        ServerShuffleSequence.advance(
          order,
          0,
          (q) => dead.contains(q),
        ),
        0,
      );
    });

    test('越过序列尾(剩余全死)返回 null:调用方应触发重洗', () {
      // 当前曲在序列位置 2(队列下标 0),其后只有序列位置 3(队列下标 2)且为死链。
      final dead = {2};
      expect(
        ServerShuffleSequence.advance(
          order,
          2,
          (q) => dead.contains(q),
        ),
        isNull,
      );
    });

    test('startPos=-1 从序列头找第一首非死链(重洗后接龙)', () {
      // 重洗后从新序列头开始:队列下标 1 是死链,应取到队列下标 3。
      final dead = {1};
      expect(
        ServerShuffleSequence.advance(
          order,
          -1,
          (q) => dead.contains(q),
        ),
        3,
      );
    });

    test('纯死序列:从头起全部死链返回 null(不越界不回绕)', () {
      final dead = {0, 1, 2, 3};
      expect(
        ServerShuffleSequence.advance(
          order,
          -1,
          (q) => dead.contains(q),
        ),
        isNull,
      );
    });

    test('空序列返回 null', () {
      expect(
        ServerShuffleSequence.advance(<int>[], 0, (_) => false),
        isNull,
      );
    });

    test('startPos 越界(< -1)返回 null', () {
      expect(
        ServerShuffleSequence.advance(order, -2, (_) => false),
        isNull,
      );
    });

    test('只跳 unplayable:未知/transient 不被误杀(与顺序模式四态同源)', () {
      // 这里用「下标奇偶性」模拟「是否已知不可播」:只跳偶数下标,奇数照常播。
      // 序列 [3,1,0,2] 从位置 0 推进:序列位置 1→队列下标 1(奇数,可播)即命中。
      expect(
        ServerShuffleSequence.advance(
          order,
          0,
          (q) => q.isEven, // 偶数=死
        ),
        1,
      );
    });
  });

  group('ServerShuffleSequence.advance - 与 _pickServerShuffleNext 契约对齐', () {
    // 把 advance 的「返回 null=需重洗」语义钉死:_pickServerShuffleNext 在
    // 拿到 null 时必须触发 reshuffle 而非回退本地随机前就丢歌。
    test('非 null 返回值必在序列内且不等于起始下标', () {
      const order = <int>[5, 2, 8, 1, 9];
      final dead = <int>{};
      final result = ServerShuffleSequence.advance(order, 1, dead.contains);
      expect(result, isNotNull);
      expect(order.contains(result), isTrue);
      expect(result, isNot(order[1]));
    });

    test('尾位置(序列最后一项)推进返回 null', () {
      const order = <int>[5, 2, 8, 1, 9];
      final result = ServerShuffleSequence.advance(order, 4, (_) => false);
      expect(result, isNull);
    });
  });
}
