// 通知栏实时歌词：applyNotificationLyric 纯函数语义钉子。
//
// 数据链路：currentLyricLineProvider（播放进度二分同步歌词得到的当前行）
// → MusicFlowAudioHandler.updateNotificationLyric → applyNotificationLyric
// → mediaItem.add → Android SystemUI 用 METADATA_KEY_ARTIST 渲染副标题行。
//
// 为什么钉 artist：Android 11+ 的媒体通知由 SystemUI 直接拿 MediaSession
// 元数据渲染（AOSP MediaDataManager 只读 DISPLAY_TITLE/TITLE 与
// METADATA_KEY_ARTIST，MediaData 里没有 album/description 字段），
// audio_service 的 displayDescription / setSubText 在 Android 11+ 上
// 没有任何消费方——这一条是 v5.17.2「通知栏不显示歌词」的真根因，
// 任何把它改回 displayDescription 的“优化”都会让功能再次静默失效。
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';

MediaItem _base() => const MediaItem(
      id: 'song-1',
      title: '歌名',
      artist: '歌手',
      album: '专辑',
    );

void main() {
  test('歌词行非空 → 占用 artist 副标题行（通知栏第二行 = 底部可见行）', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '今夜的月光',
      current: _base(),
    );
    expect(next, isNotNull);
    expect(next!.artist, '今夜的月光');
    // 标题/专辑/封面等其余字段必须原样保留。
    expect(next.title, '歌名');
    expect(next.album, '专辑');
    expect(next.id, 'song-1');
  });

  test('歌词行首尾空白先 trim 再写入', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '  前后空白行  ',
      current: _base(),
    );
    expect(next!.artist, '前后空白行');
  });

  test('同一行重复推送 → null（不推，避免原生侧重解析封面+重建通知）', () {
    final shown = _base().copyWith(artist: '今夜的月光');
    expect(
      applyNotificationLyric(base: _base(), lyric: '今夜的月光', current: shown),
      isNull,
    );
  });

  test('歌词为空 → 还原真实歌手（从 base 派生，不是从已改写的项派生）', () {
    final shown = _base().copyWith(artist: '今夜的月光');
    final next = applyNotificationLyric(
      base: _base(),
      lyric: null,
      current: shown,
    );
    expect(next, isNotNull);
    expect(next!.artist, '歌手', reason: '无歌词时必须能回到歌手行');
  });

  test('歌词为空且当前已经显示歌手 → 不推', () {
    expect(
      applyNotificationLyric(base: _base(), lyric: null, current: _base()),
      isNull,
    );
  });

  test('空白歌词行等价于无歌词 → 还原歌手', () {
    final shown = _base().copyWith(artist: '今夜的月光');
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '   ',
      current: shown,
    );
    expect(next!.artist, '歌手');
  });

  test('切歌后（current 是上一首）必须重推，不能因 artist 巧合相同而吞掉', () {
    final prev = const MediaItem(id: 'song-0', title: '上一首', artist: '歌手');
    final next = applyNotificationLyric(
      base: _base(),
      lyric: null,
      current: prev,
    );
    expect(next, isNotNull, reason: 'id 不同的 current 不能作为去重依据');
    expect(next!.id, 'song-1');
  });

  test('连续多行歌词逐行推进（不叠加、不残留）', () {
    var current = _base();
    for (final line in ['第一行', '第二行', '第三行']) {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: line,
        current: current,
      );
      expect(next, isNotNull);
      expect(next!.artist, line);
      expect(next.title, '歌名', reason: '标题行不得被歌词污染');
      current = next;
    }
  });
}
