// 通知栏歌词：applyNotificationLyric / resolvePreservedLyric 语义钉子。
//
// 数据链路：currentLyricLineProvider（播放进度二分同步歌词得到的当前行）
// → MusicFlowAudioHandler.updateNotificationLyric → applyNotificationLyric
// → mediaItem.add → Android SystemUI 渲染。
//
// 布局约束（AOSP 取证）：Android 11+ 的媒体通知由 SystemUI 直接拿 MediaSession
// 元数据渲染，MediaDataManager 只读 DISPLAY_TITLE/TITLE 与 METADATA_KEY_ARTIST，
// MediaData 里没有 album/description 字段——audio_service 的 displayDescription
// / setSubText 在 Android 11+ 上没有任何消费方（v5.17.2 静默失效根因）。
//
// 三条产品决定（用户 2026-11-17 明确要求）：
//  1. 主标题只能是纯歌名，通知栏不出现歌手；
//  2. 副标题整行只放歌词，无歌词时留空——**绝不回落歌手**，否则用户会把
//     「歌手占位」当成「歌词没加载」；
//  3. 同曲重推 mediaItem（交叉淡入/预加载/metadata 刷新）必须带回已显示的
//     歌词行，否则副标题会被反复打回空白、卡在「不加载」的样子。
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

/// 通知栏上「已推送过的形态」：副标题是歌词行（或留空）。
MediaItem _shown(String? lyric) =>
    _base().copyWith(artist: lyric ?? kNotificationEmptyLyric);

void main() {
  test('歌词行非空 → 副标题换成歌词，主标题保持纯歌名', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '今夜的月光',
      current: _shown(null),
    );
    expect(next, isNotNull);
    expect(next!.artist, '今夜的月光');
    expect(next.title, '歌名', reason: '通知栏不允许拼出「歌名 - 歌手」');
    expect(next.album, '专辑');
    expect(next.id, 'song-1');
  });

  test('歌词行首尾空白先 trim 再写入', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '  前后空白行  ',
      current: _shown(null),
    );
    expect(next!.artist, '前后空白行');
  });

  test('同曲同副标题重复推送 → null（不重建通知、不重解析封面）', () {
    expect(
      applyNotificationLyric(
        base: _base(),
        lyric: '今夜的月光',
        current: _shown('今夜的月光'),
      ),
      isNull,
    );
  });

  test('歌词为空 → 副标题留空，绝不回落歌手名', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: null,
      current: _shown('今夜的月光'),
    );
    expect(next, isNotNull);
    expect(next!.artist, kNotificationEmptyLyric);
    expect(next.artist, '', reason: '歌手占位会被误认为「歌词没加载」');
    expect(next.title, '歌名');
  });

  test('歌词为空且当前已留空 → 不推', () {
    expect(
      applyNotificationLyric(base: _base(), lyric: null, current: _shown(null)),
      isNull,
    );
  });

  test('空白歌词行等价于无歌词 → 留空', () {
    final next = applyNotificationLyric(
      base: _base(),
      lyric: '   ',
      current: _shown('今夜的月光'),
    );
    expect(next!.artist, '');
  });

  test('切歌后（current 是上一首）必须重推，不能因 id/文本巧合而吞掉', () {
    final prev = const MediaItem(
      id: 'song-0',
      title: '上一首',
      artist: '今夜的月光',
    );
    final next = applyNotificationLyric(
      base: _base(),
      lyric: null,
      current: prev,
    );
    expect(next, isNotNull, reason: 'id 不同的 current 不能作为去重依据');
    expect(next!.id, 'song-1');
    expect(next.title, '歌名');
    expect(next.artist, '');
  });

  test('连续多行歌词逐行推进（不叠加、不残留）', () {
    var current = _shown(null);
    for (final line in ['第一行', '第二行', '第三行']) {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: line,
        current: current,
      );
      expect(next, isNotNull);
      expect(next!.artist, line);
      expect(next.title, '歌名', reason: '主标题不得被歌词或歌手污染');
      current = next;
    }
  });

  group('resolvePreservedLyric（同曲重推保留歌词 / 换曲清空）', () {
    test('同曲重推 → 保留已显示的歌词行', () {
      expect(
        resolvePreservedLyric(
          previousSongId: 'song-1',
          nextSongId: 'song-1',
          lastLyric: '今夜的月光',
        ),
        '今夜的月光',
      );
    });

    test('换曲 → 清空，上一首的歌词不能跟着新歌上屏', () {
      expect(
        resolvePreservedLyric(
          previousSongId: 'song-0',
          nextSongId: 'song-1',
          lastLyric: '上一首的歌词',
        ),
        isNull,
      );
    });

    test('首次推送（没有上一首）→ 清空', () {
      expect(
        resolvePreservedLyric(
          previousSongId: null,
          nextSongId: 'song-1',
          lastLyric: '残留歌词',
        ),
        isNull,
      );
    });
  });
}
