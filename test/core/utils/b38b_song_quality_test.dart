import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/utils/song_quality.dart';
import 'package:musicflow_client/data/models/song.dart';

void main() {
  group('songFileSizeLabel', () {
    test('null/zero/negative returns null', () {
      expect(songFileSizeLabel(Song(id: '1', title: 't')), isNull);
      expect(songFileSizeLabel(Song(id: '1', title: 't', size: 0)), isNull);
      expect(songFileSizeLabel(Song(id: '1', title: 't', size: -5)), isNull);
    });
    test('gigabytes', () {
      final s = Song(id: '1', title: 't', size: 2 * 1024 * 1024 * 1024);
      expect(songFileSizeLabel(s), '2.00G');
    });
    test('megabytes', () {
      final s = Song(id: '1', title: 't', size: 5 * 1024 * 1024);
      expect(songFileSizeLabel(s), '5.00M');
    });
    test('kilobytes', () {
      final s = Song(id: '1', title: 't', size: 2048);
      expect(songFileSizeLabel(s), '2K');
    });
    test('bytes', () {
      final s = Song(id: '1', title: 't', size: 512);
      expect(songFileSizeLabel(s), '512 B');
    });
  });

  group('songMetadataParts', () {
    test('includes quality, bitrate, suffix, size', () {
      final s = Song(
        id: '1',
        title: 't',
        bitDepth: 24,
        bitRate: 320,
        suffix: 'flac',
        size: 5 * 1024 * 1024,
        duration: 120,
      );
      final parts = songMetadataParts(s);
      expect(parts, contains('Hi-Res'));
      expect(parts, contains('320kbps'));
      expect(parts, contains('FLAC'));
      expect(parts, contains('5.00M'));
      expect(parts.last, '02:00');
    });
    test('omits empty fields (duration only)', () {
      final s = Song(id: '1', title: 't');
      expect(songMetadataParts(s), ['--:--']);
    });
  });
}
