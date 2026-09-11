import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';

void main() {
  group('mimeToSuffix / queueItemToSong(服务端队列快照 → 本机可播 Song)', () {
    test('常见 mime 全部还原为 suffix', () {
      expect(mimeToSuffix('audio/flac'), 'flac');
      expect(mimeToSuffix('audio/wav'), 'wav');
      expect(mimeToSuffix('audio/aac'), 'aac');
      expect(mimeToSuffix('audio/ogg'), 'ogg');
      expect(mimeToSuffix('audio/mp4'), 'm4a');
      expect(mimeToSuffix('audio/opus'), 'opus');
      expect(mimeToSuffix('audio/ape'), 'ape');
      expect(mimeToSuffix('audio/x-ms-wma'), 'wma');
    });

    test('未知/空 mime 兜底 mp3(与 songToQueueItem 的默认 mime 成对)', () {
      expect(mimeToSuffix(''), 'mp3');
      expect(mimeToSuffix('audio/mpeg'), 'mp3');
      expect(mimeToSuffix('application/octet-stream'), 'mp3');
    });

    test('songToQueueItem ↔ queueItemToSong 往返:suffix 不丢', () {
      final song = Song(
        id: 'song-1',
        title: '素颜',
        artist: '许嵩',
        album: '寻雾启示',
        albumId: 'uuid-1',
        suffix: 'flac',
        duration: 253,
      );
      final item = songToQueueItem(song);
      expect(item['mime'], 'audio/flac');
      final back = queueItemToSong(item);
      expect(back.id, 'song-1');
      expect(back.suffix, 'flac');
      expect(back.duration, 253);
      expect(back.coverArt, 'al-uuid-1');
    });

    test('mp3 兜底 mime 往返', () {
      final song = Song(id: 's2', title: 't', suffix: 'mp3');
      final item = songToQueueItem(song);
      expect(item['mime'], 'audio/mpeg');
      expect(queueItemToSong(item).suffix, 'mp3');
    });

    test('快照条目缺 mime 时回退 mp3 而非 null(空 suffix 会让播放器找不到格式)', () {
      final back = queueItemToSong({'songId': 's3', 'title': 'x'});
      expect(back.suffix, 'mp3');
    });
  });
}
