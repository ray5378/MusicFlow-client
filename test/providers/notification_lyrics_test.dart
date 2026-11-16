// 通知栏实时歌词：applyNotificationLyric / notificationTitleFor 纯函数语义钉子。
//
// 数据链路：currentLyricLineProvider（播放进度二分同步歌词得到的当前行）
// → MusicFlowAudioHandler.updateNotificationLyric → applyNotificationLyric
// → mediaItem.add → Android SystemUI 渲染。
//
// 布局约束（AOSP 取证）：Android 11+ 的媒体通知由 SystemUI 直接拿 MediaSession
// 元数据渲染，MediaDataManager 只读 DISPLAY_TITLE/TITLE 与 METADATA_KEY_ARTIST，
// MediaData 里没有 album/description 字段——audio_service 的 displayDescription
// / setSubText 在 Android 11+ 上没有任何消费方（v5.17.2 的静默失效根因）。
// 通知栏只有两行，所以：主标题合并成「歌名 - 歌手」保留歌手信息，
// 副标题整行让给歌词。任何把副标题改回专辑名、或把歌词写回 displayDescription
// 的“优化”都会让功能再次失效或被用户看见歌手名丢失。
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';

/// 切歌时 player_provider 构建的原始 MediaItem（title = 纯歌名）。
MediaItem _base() => const MediaItem(
      id: 'song-1',
      title: '歌名',
      artist: '歌手',
      album: '专辑',
    );

/// 通知栏上「已推送过的形态」：主标题已合并。
MediaItem _shown({String? lyric}) =>
    _base().copyWith(title: '歌名 - 歌手', artist: lyric ?? '歌手');

void main() {
  test('歌词行非空 → 副标题换成歌词，主标题合并为「歌名 - 歌手」', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '今夜的月光',
      current: _shown(),
    );
    expect(next, isNotNull);
    expect(next!.artist, '今夜的月光');
    expect(next.title, '歌名 - 歌手', reason: '歌手信息必须保留在主标题里');
    // 专辑/封面/时长等其余字段原样保留。
    expect(next.album, '专辑');
    expect(next.id, 'song-1');
  });

  test('歌词行首尾空白先 trim 再写入', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '  前后空白行  ',
      current: _shown(),
    );
    expect(next!.artist, '前后空白行');
  });

  test('同曲同主标题同副标题重复推送 → null（不重建通知、不重解析封面）', () {
    expect(
      applyNotificationLyric(
        base: _base(),
        lyric: '今夜的月光',
        current: _shown(lyric: '今夜的月光'),
      ),
      isNull,
    );
  });

  test('歌词为空 → 副标题还原真实歌手，主标题仍保留歌手信息', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: null,
      current: _shown(lyric: '今夜的月光'),
    );
    expect(next, isNotNull);
    expect(next!.artist, '歌手', reason: '无歌词时必须能回到歌手行');
    expect(next.title, '歌名 - 歌手');
  });

  test('歌词为空且当前已是通知栏形态 → 不推', () {
    expect(
      applyNotificationLyric(base: _base(), lyric: null, current: _shown()),
      isNull,
    );
  });

  test('空白歌词行等价于无歌词 → 还原歌手', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '   ',
      current: _shown(lyric: '今夜的月光'),
    );
    expect(next!.artist, '歌手');
  });

  test('切歌后（current 是上一首）必须重推，不能因 id/文本巧合而吞掉', () {
    final prev = const MediaItem(
      id: 'song-0',
      title: '上一首 - 歌手',
      artist: '歌手',
    );
    final next = applyNotificationLyric(
      base: _base(),
      lyric: null,
      current: prev,
    );
    expect(next, isNotNull, reason: 'id 不同的 current 不能作为去重依据');
    expect(next!.id, 'song-1');
    expect(next.title, '歌名 - 歌手');
  });

  test('连续多行歌词逐行推进（不叠加后缀、不残留）', () {
    var current = _shown();
    for (final line in ['第一行', '第二行', '第三行']) {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: line,
        current: current,
      );
      expect(next, isNotNull);
      expect(next!.artist, line);
      expect(next.title, '歌名 - 歌手', reason: '主标题不得逐行累加后缀');
      current = next;
    }
  });

  test('歌手是 Unknown Artist 占位符 → 主标题只用歌名，不拼噪声', () {
    const base = MediaItem(id: 'song-2', title: '歌名', artist: 'Unknown Artist');
    expect(notificationTitleFor(base), '歌名');
  });

  test('歌手缺失/null → 主标题只用歌名', () {
    const base = MediaItem(id: 'song-3', title: '歌名');
    expect(notificationTitleFor(base), '歌名');
    const blank = MediaItem(id: 'song-4', title: '歌名', artist: '   ');
    expect(notificationTitleFor(blank), '歌名');
  });

  test('主标题合并是幂等的：底稿已是「歌名 - 歌手」不再重复拼接', () {
    const merged = MediaItem(id: 'song-5', title: '歌名 - 歌手', artist: '歌手');
    expect(notificationTitleFor(merged), '歌名 - 歌手');
  });
}
