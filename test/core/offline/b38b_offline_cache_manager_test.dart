import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';

void main() {
  test('CachedSongInfo.toJson covers album/duration/cover branches (38-44)', () {
    final info = CachedSongInfo(
      songId: 's',
      title: 't',
      artist: 'a',
      album: 'al',
      durationSeconds: 3,
      coverArt: 'c',
      size: 9,
    );
    final json = info.toJson();
    expect(json['album'], 'al');
    expect(json['duration'], 3);
    expect(json['coverArt'], 'c');

    final info2 = CachedSongInfo(songId: 's', title: 't', artist: 'a', size: 1);
    final json2 = info2.toJson();
    expect(json2.containsKey('album'), isFalse);
    expect(json2.containsKey('duration'), isFalse);
  });

  test('overwriting same key adjusts totalBytes (line 331)', () async {
    final dir = await Directory.systemTemp.createTemp('ocm');
    try {
      final m = OfflineCacheManager(rootForTest: dir);
      await m.init();
      await m.putSong('s1', [1, 2, 3]);
      await m.putSong('s1', [4, 5]); // overwrite -> existing != null -> subtract
      expect(m.hasSong('s1'), isTrue);
      expect(m.totalBytes, 2);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
