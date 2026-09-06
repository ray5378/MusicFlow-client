import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/shuffle_history.dart';

Song _song(String id) => Song(id: id, title: id);

void main() {
  late ShuffleHistory h;
  setUp(() => h = ShuffleHistory());

  test('初始 backCount=0', () {
    expect(h.backCount, 0);
  });

  test('pushBack 连续相同条目去重', () {
    h.pushBack(ShuffleHistoryEntry(songId: 'a', preferredIndex: 0));
    h.pushBack(ShuffleHistoryEntry(songId: 'a', preferredIndex: 0));
    expect(h.backCount, 1);
  });

  test('pushBack 不同条目递增', () {
    h.pushBack(ShuffleHistoryEntry(songId: 'a', preferredIndex: 0));
    h.pushBack(ShuffleHistoryEntry(songId: 'b', preferredIndex: 1));
    expect(h.backCount, 2);
  });

  test('takeLastValidBack 正常返回并按后进先出', () {
    final queue = [_song('a'), _song('b'), _song('c')];
    h.pushBack(ShuffleHistoryEntry(songId: 'a', preferredIndex: 0));
    h.pushBack(ShuffleHistoryEntry(songId: 'c', preferredIndex: 2));
    expect(h.takeLastValidBack(queue), 2);
    expect(h.takeLastValidBack(queue), 0);
    expect(h.takeLastValidBack(queue), isNull);
  });

  test('队列有变时失效条目被跳过丢弃并推进', () {
    // 预存两个条目,先按次序回退:最后一个有效的是 b(preferredIndex=2,但队列已换)。
    h.pushBack(ShuffleHistoryEntry(songId: 'a', preferredIndex: 0));
    h.pushBack(ShuffleHistoryEntry(songId: 'b', preferredIndex: 2));
    // 新队列中 b 不在 → 该条目失效,应被跳过;返回 a(index 需在队列中)。
    final queue = [_song('x'), _song('a'), _song('y')];
    expect(h.takeLastValidBack(queue), 1); // a 在 index 1
    expect(h.backCount, 0); // b 已被 pop 丢弃
  });

  test('pushForward/clearForward/takeLastValidForward', () {
    h.pushForward(ShuffleHistoryEntry(songId: 'c', preferredIndex: 2));
    expect(h.takeLastValidForward([_song('a'), _song('b'), _song('c')]), 2);
    expect(h.takeLastValidForward([_song('a'), _song('b'), _song('c')]), isNull);

    h.pushForward(ShuffleHistoryEntry(songId: 'b', preferredIndex: 1));
    h.clearForward();
    expect(h.takeLastValidForward([_song('a'), _song('b')]), isNull);
  });

  test('takeLastValid 优先使用 preferredIndex 命中', () {
    h.pushBack(ShuffleHistoryEntry(songId: 'b', preferredIndex: 1));
    final queue = [_song('a'), _song('b'), _song('c')];
    expect(h.takeLastValidBack(queue), 1);
  });

  test('reset 清空 back 与 forward', () {
    h.pushBack(ShuffleHistoryEntry(songId: 'a', preferredIndex: 0));
    h.pushForward(ShuffleHistoryEntry(songId: 'a', preferredIndex: 0));
    h.reset();
    expect(h.backCount, 0);
    expect(h.takeLastValidBack([_song('a')]), isNull);
    expect(h.takeLastValidForward([_song('a')]), isNull);
  });
}