import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/player/playback_payload.dart';
import 'package:musicflow_client/data/models/song.dart';

Song _song(String id) => Song(id: id, title: id);

void main() {
  group('normalizeSeekPosition', () {
    test('负进度归零', () {
      expect(
        normalizeSeekPosition(const Duration(milliseconds: -5),
            const Duration(seconds: 60)),
        Duration.zero,
      );
    });

    test('超过时长裁到时长', () {
      expect(
        normalizeSeekPosition(const Duration(seconds: 90),
            const Duration(seconds: 60)),
        const Duration(seconds: 60),
      );
    });

    test('时长未知(duration=0)时不上限裁剪', () {
      expect(
        normalizeSeekPosition(const Duration(seconds: 500), Duration.zero),
        const Duration(seconds: 500),
      );
    });

    test('正常范围内保持不变', () {
      expect(
        normalizeSeekPosition(const Duration(seconds: 30),
            const Duration(seconds: 60)),
        const Duration(seconds: 30),
      );
    });
  });

  group('PlaybackPayloadEncoder.buildQueue', () {
    test('队列未变时复用同一序列化结果(对象 identical)', () {
      final e = PlaybackPayloadEncoder();
      final queue = [_song('a'), _song('b')];
      final first = e.buildQueue(queue);
      final second = e.buildQueue(queue);
      expect(identical(first, second), isTrue);
    });

    test('队列歌曲 id 变化时重建', () {
      final e = PlaybackPayloadEncoder();
      final first = e.buildQueue([_song('a'), _song('b')]);
      final second = e.buildQueue([_song('a'), _song('c')]);
      expect(identical(first, second), isFalse);
    });
  });

  group('PlaybackPayloadEncoder.buildSession', () {
    test('空队列返回 null', () {
      final e = PlaybackPayloadEncoder();
      expect(
        e.buildSession(
          queue: [],
          currentIndex: 0,
          currentSongId: null,
          position: Duration.zero,
          duration: Duration.zero,
          isPlaying: true,
          nowMs: 1,
        ),
        isNull,
      );
    });

    test('当前索引失配时按当前曲 id 重定位', () {
      final e = PlaybackPayloadEncoder();
      final queue = [_song('a'), _song('b'), _song('c')];
      // currentIndex=0 但 currentSongId=b → 应定位到索引 1。
      final p = e.buildSession(
        queue: queue,
        currentIndex: 0,
        currentSongId: 'b',
        position: const Duration(seconds: 5),
        duration: const Duration(seconds: 60),
        isPlaying: false,
        nowMs: 123,
      )!;
      expect(p['currentIndex'], 1);
      expect(p['currentSongId'], 'b');
    });

    test('无法定位当前曲返回 null', () {
      final e = PlaybackPayloadEncoder();
      final p = e.buildSession(
        queue: [_song('a')],
        currentIndex: 5, // 越界
        currentSongId: 'zzz',
        position: Duration.zero,
        duration: Duration.zero,
        isPlaying: true,
        nowMs: 1,
      );
      expect(p, isNull);
    });

    test('payload 字段完整且位置被归一化', () {
      final e = PlaybackPayloadEncoder();
      final queue = [_song('a')];
      final p = e.buildSession(
        queue: queue,
        currentIndex: 0,
        currentSongId: 'a',
        position: const Duration(seconds: 999),
        duration: const Duration(seconds: 10),
        isPlaying: true,
        nowMs: 42,
      )!;
      expect(p['version'], 1);
      expect(p['queue'], isList);
      expect(p['currentIndex'], 0);
      expect(p['currentSongId'], 'a');
      expect(p['positionMs'], 10000); // 裁到 duration
      expect(p['isPlaying'], isTrue);
      expect(p['updatedAt'], 42);
    });
  });
}