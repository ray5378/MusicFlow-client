import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/features/player/widgets/synced_lyrics_view.dart';

// Route C 补测：lib/features/player/widgets/synced_lyrics_view.dart
// 覆盖顶层纯函数 lyricLineParts / syncedLyricIndexFor 的各分支。
void main() {
  group('lyricLineParts', () {
    test('empty string', () {
      final r = lyricLineParts('');
      expect(r, ('', null));
    });

    test('pure latin keeps single part', () {
      final r = lyricLineParts('Hello world');
      expect(r, ('Hello world', null));
    });

    test('pure cjk keeps single part', () {
      final r = lyricLineParts('你好世界');
      expect(r, ('你好世界', null));
    });

    test('latin then cjk splits', () {
      final r = lyricLineParts('Hello 世界');
      expect(r, ('Hello', '世界'));
    });

    test('cjk then latin splits', () {
      final r = lyricLineParts('世界 Hello');
      expect(r, ('世界', 'Hello'));
    });

    test('no space boundary keeps single part', () {
      final r = lyricLineParts('Hello世界');
      expect(r, ('Hello世界', null));
    });
  });

  group('syncedLyricIndexFor', () {
    final lyrics = StructuredLyrics(
      synced: true,
      offsetMs: 0,
      lines: <LyricsLine>[
        LyricsLine(startMs: 0, value: 'a'),
        LyricsLine(startMs: 1000, value: 'b'),
        LyricsLine(startMs: 2000, value: 'c'),
      ],
    );

    test('unsynced returns 0', () {
      final unsynced = StructuredLyrics(
        synced: false,
        lines: lyrics.lines,
      );
      expect(syncedLyricIndexFor(unsynced, const Duration(seconds: 5)), 0);
    });

    test('empty returns 0', () {
      expect(
        syncedLyricIndexFor(
          StructuredLyrics(synced: true, lines: <LyricsLine>[]),
          const Duration(seconds: 5),
        ),
        0,
      );
    });

    test('picks active line by position', () {
      expect(syncedLyricIndexFor(lyrics, const Duration(milliseconds: 500)), 0);
      expect(
        syncedLyricIndexFor(lyrics, const Duration(milliseconds: 1500)), 1);
      expect(
        syncedLyricIndexFor(lyrics, const Duration(milliseconds: 99999)), 2);
    });
  });
}
