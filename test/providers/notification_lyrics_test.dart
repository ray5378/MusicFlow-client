// 通知栏实时歌词：applyNotificationLyric 纯函数语义钉子。
//
// 数据链路：currentLyricLineProvider（播放进度二分同步歌词得到的当前行）
// → MusicFlowAudioHandler.updateNotificationLyric → applyNotificationLyric
// → mediaItem.add → audio_service 原生 setSubText（MediaStyle 展开态第三行）。
// 本文件钉住「推 / 不推 / 回落」三类判据，防止后续改动引入逐帧空推
// （每帧 metadata 更新都会触发原生侧封面位图重解码 + 通知重建）。
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';

MediaItem _item({String? displayDescription}) => MediaItem(
      id: 'song-1',
      title: '歌名',
      artist: '歌手',
      album: '专辑',
      displayDescription: displayDescription,
    );

void main() {
  test('歌词行非空 → displayDescription 写入该行', () {
    final next = applyNotificationLyric(item: _item(), lyric: '今夜的月光');
    expect(next, isNotNull);
    expect(next!.displayDescription, '今夜的月光');
    // 其余字段原样保留。
    expect(next.id, 'song-1');
    expect(next.title, '歌名');
    expect(next.album, '专辑');
  });

  test('歌词行首尾空白先 trim 再写入', () {
    final next = applyNotificationLyric(item: _item(), lyric: '  前后空白行  ');
    expect(next!.displayDescription, '前后空白行');
  });

  test('同一行重复推送 → null（不推，避免无谓通知重建）', () {
    final item = _item(displayDescription: '今夜的月光');
    expect(applyNotificationLyric(item: item, lyric: '今夜的月光'), isNull);
  });

  test('歌词为 null 且当前没在展示歌词（displayDescription=null）→ 不推', () {
    // 每首歌开场（新 MediaItem 无 displayDescription）时歌词源还在拉取，
    // 此时推「专辑名回落」是纯冗余的一帧 metadata 更新。
    expect(applyNotificationLyric(item: _item(), lyric: null), isNull);
  });

  test('歌词为 null 且当前已是专辑名 → 不推', () {
    final item = _item(displayDescription: '专辑');
    expect(applyNotificationLyric(item: item, lyric: null), isNull);
  });

  test('歌词清空但上一次还展示着歌词行 → 回落专辑名（清掉残留歌词）', () {
    final item = _item(displayDescription: '今夜的月光');
    final next = applyNotificationLyric(item: item, lyric: null);
    expect(next, isNotNull);
    expect(next!.displayDescription, '专辑');
  });

  test('空白歌词行等价于无歌词（不推）', () {
    expect(applyNotificationLyric(item: _item(), lyric: '   '), isNull);
    final item = _item(displayDescription: '今夜的月光');
    final next = applyNotificationLyric(item: item, lyric: '   ');
    expect(next!.displayDescription, '专辑');
  });
}
