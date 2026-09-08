import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/media/desktop_lyric_popup.dart';

void main() {
  group('desktopLyricSongRow', () {
    test('有歌手拼「歌名 — 歌手」,无歌手只有歌名', () {
      expect(desktopLyricSongRow(Song(id: 'a', title: '晴天', artist: '周杰伦')),
          '晴天 — 周杰伦');
      expect(desktopLyricSongRow(Song(id: 'b', title: '未知曲目')), '未知曲目');
      expect(desktopLyricSongRow(Song(id: 'c', title: '空白', artist: '  ')),
          '空白');
    });
  });

  group('composeDesktopLyricQueue', () {
    final localQueue = <Song>[
      Song(id: 'a', title: '晴天', artist: '周杰伦'),
      Song(id: 'b', title: '夜曲', artist: '周杰伦'),
      Song(id: 'c', title: '稻香'),
    ];

    test('本机:playerProvider 队列 + localIndex', () {
      final data = composeDesktopLyricQueue(
        castActive: false,
        castQueue: const [],
        castIndex: -1,
        localQueue: localQueue,
        localIndex: 1,
        dlnaCasting: false,
        dlnaIndex: -1,
      );
      expect(data.items, ['晴天 — 周杰伦', '夜曲 — 周杰伦', '稻香']);
      expect(data.index, 1);
    });

    test('DLNA 直投:playerProvider 队列 + dlnaIndex', () {
      final data = composeDesktopLyricQueue(
        castActive: false,
        castQueue: const [],
        castIndex: -1,
        localQueue: localQueue,
        localIndex: 0,
        dlnaCasting: true,
        dlnaIndex: 2,
      );
      expect(data.items.length, 3);
      expect(data.index, 2);
    });

    test('后端投屏:castQueue/castIndex 权威,忽略本机队列', () {
      final data = composeDesktopLyricQueue(
        castActive: true,
        castQueue: const [
          <String, dynamic>{'songId': 'x', 'title': '远端歌', 'artist': '某人'},
          <String, dynamic>{'songId': 'y'},
        ],
        castIndex: 1,
        localQueue: localQueue,
        localIndex: 0,
        dlnaCasting: false,
        dlnaIndex: -1,
      );
      expect(data.items.first, '远端歌 — 某人');
      // 无 title 的条目走 l10nNowCurrent().peer_unknown 兜底文案。
      expect(data.items.last, isNotEmpty);
      expect(data.index, 1);
    });
  });
}
