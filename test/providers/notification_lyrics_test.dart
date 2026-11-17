// 通知栏歌词：applyNotificationLyric / notificationTitleFor /
// resolveLyricPosition / 版本分叉 语义钉子。
//
// 数据链路：定时器按播放进度二分同步歌词得到的当前行
// → NotificationLyricsController → MusicFlowAudioHandler.updateNotificationLyric
// → applyNotificationLyric → mediaItem.add → 系统渲染。
//
// 布局按 Android 版本分叉（两套都必须在测试里钉住，否则改一边会悄悄弄坏另一边）：
//  - API >= 30（Android 11 起）：SystemUI 用 MediaSession 元数据渲染媒体卡片，
//    只读 DISPLAY_TITLE/TITLE 与 METADATA_KEY_ARTIST 两行，MediaData 里连
//    album/description 字段都没有 —— 写 displayDescription 是零消费方（v5.17.2
//    静默失效根因）。两行怎么分工由用户拍板：主标题「歌名 - 歌手」，副标题
//    整行让给歌词；无歌词留空（不回落歌手，否则会被误认为「歌词没加载」）。
//  - API < 30：audio_service 自建 MediaStyle 通知，标题/歌手/subText 三行都渲染。
//    此时歌手留在副标题，歌词写进第三行（displayDescription），无歌词回落专辑。
//
// 另有两条与版本无关的硬约束：
//  1. 同曲重推 mediaItem（交叉淡入/预加载/metadata 刷新）必须带回已显示的歌词，
//     否则副标题会被反复打回空白、卡在「不加载」的样子；
//  2. 后台 positionStream 可能停摆，进度必须能靠自持时钟外推
//     （resolveLyricPosition），否则「后台切歌后歌词不更新」。
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/android_platform_info.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';
import 'package:musicflow_client/providers/media/notification_lyrics_provider.dart';

/// 切歌时 player_provider 构建的原始 MediaItem（title = 纯歌名）。
MediaItem _base() => const MediaItem(
      id: 'song-1',
      title: '歌名',
      artist: '歌手',
      album: '专辑',
    );

/// 两行布局下「已推送过的形态」：主标题合并，副标题是歌词行（或留空）。
MediaItem _shown(String? lyric) => _base().copyWith(
      title: '歌名 - 歌手',
      artist: lyric ?? kNotificationEmptyLyric,
    );

void main() {
  group('Android 11+（两行布局）：主标题「歌名 - 歌手」+ 副标题歌词', () {
    test('歌词行非空 → 主标题合并歌手，副标题换成歌词', () {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: '今夜的月光',
        current: _shown(null),
      );
      expect(next, isNotNull);
      expect(next!.title, '歌名 - 歌手', reason: '用户要求主标题显示「歌名 - 歌手」');
      expect(next.artist, '今夜的月光', reason: '副标题整行让给歌词');
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

    test('同曲同标题同副标题重复推送 → null（不重建通知、不重解析封面）', () {
      expect(
        applyNotificationLyric(
          base: _base(),
          lyric: '今夜的月光',
          current: _shown('今夜的月光'),
        ),
        isNull,
      );
    });

    test('歌词为空 → 副标题留空，绝不回落歌手名，主标题仍带歌手', () {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: null,
        current: _shown('今夜的月光'),
      );
      expect(next, isNotNull);
      expect(next!.artist, kNotificationEmptyLyric);
      expect(next.artist, '', reason: '歌手占位会被误认为「歌词没加载」');
      expect(next.title, '歌名 - 歌手');
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
        title: '上一首 - 上一位歌手',
        artist: '今夜的月光',
      );
      final next = applyNotificationLyric(
        base: _base(),
        lyric: null,
        current: prev,
      );
      expect(next, isNotNull, reason: 'id 不同的 current 不能作为去重依据');
      expect(next!.id, 'song-1');
      expect(next.title, '歌名 - 歌手');
      expect(next.artist, '');
    });

    test('连续多行歌词逐行推进：副标题替换而非拼接，标题不变长', () {
      var current = _shown(null);
      for (final line in ['第一行', '第二行', '第三行']) {
        final next = applyNotificationLyric(
          base: _base(),
          lyric: line,
          current: current,
        );
        expect(next, isNotNull);
        expect(next!.artist, line);
        expect(next.title, '歌名 - 歌手', reason: '标题不得被歌词或重复拼接污染');
        current = next;
      }
    });
  });

  group('notificationTitleFor（主标题合并规则）', () {
    test('歌名 + 歌手 → 「歌名 - 歌手」', () {
      expect(notificationTitleFor(_base()), '歌名 - 歌手');
    });

    test('Unknown Artist 占位符不参与拼接', () {
      const item = MediaItem(id: 'x', title: '歌名', artist: 'Unknown Artist');
      expect(notificationTitleFor(item), '歌名');
    });

    test('歌手缺失 / 空串 → 只用歌名', () {
      expect(
        notificationTitleFor(const MediaItem(id: 'x', title: '歌名')),
        '歌名',
      );
      expect(
        notificationTitleFor(
          const MediaItem(id: 'x', title: '歌名', artist: '   '),
        ),
        '歌名',
      );
    });

    test('已是合并形态 → 原样返回（幂等，不会越接越长）', () {
      const merged = MediaItem(id: 'x', title: '歌名 - 歌手', artist: '歌手');
      expect(notificationTitleFor(merged), '歌名 - 歌手');
    });

    test('空歌名 → 不拼出「 - 歌手」', () {
      expect(
        notificationTitleFor(const MediaItem(id: 'x', title: '', artist: '歌手')),
        '',
      );
    });
  });

  group('resolveLyricPosition（后台进度外推）', () {
    final anchorAt = DateTime(2026, 11, 17, 8, 0, 0);

    test('暂停 → 停在真实进度，不随时间前进', () {
      expect(
        resolveLyricPosition(
          reported: const Duration(seconds: 42),
          playing: false,
          anchorPosition: const Duration(seconds: 42),
          anchorAt: anchorAt,
          now: anchorAt.add(const Duration(seconds: 10)),
          advanced: false,
        ),
        const Duration(seconds: 42),
      );
    });

    test('进度流仍在推进 → 完全信任真实值（零漂移）', () {
      expect(
        resolveLyricPosition(
          reported: const Duration(seconds: 43),
          playing: true,
          anchorPosition: const Duration(seconds: 42),
          anchorAt: anchorAt,
          now: anchorAt.add(const Duration(milliseconds: 300)),
          advanced: true,
        ),
        const Duration(seconds: 43),
      );
    });

    test('进度流停摆（后台）→ 按经过时间外推', () {
      expect(
        resolveLyricPosition(
          reported: const Duration(seconds: 42),
          playing: true,
          anchorPosition: const Duration(seconds: 42),
          anchorAt: anchorAt,
          now: anchorAt.add(const Duration(seconds: 30)),
          advanced: false,
        ),
        const Duration(seconds: 72),
        reason: '后台 positionStream 不推进时，歌词必须靠外推继续走',
      );
    });

    test('时钟回拨（elapsed 为负）→ 退回锚点，不倒退到负数', () {
      expect(
        resolveLyricPosition(
          reported: const Duration(seconds: 42),
          playing: true,
          anchorPosition: const Duration(seconds: 42),
          anchorAt: anchorAt,
          now: anchorAt.subtract(const Duration(seconds: 5)),
          advanced: false,
        ),
        const Duration(seconds: 42),
      );
    });
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

  group('Android 10 及以下（API < 30）：MediaStyle 三行布局', () {
    test('歌词写进第三行 subText，副标题仍是歌手', () {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: '今夜的月光',
        current: _base().copyWith(displayDescription: '专辑'),
        threeLineLayout: true,
      );
      expect(next, isNotNull);
      expect(next!.title, '歌名');
      expect(next.artist, '歌手', reason: '老版本三行布局要保留歌手');
      expect(next.displayDescription, '今夜的月光');
    });

    test('无歌词 → 第三行回落专辑，副标题仍是歌手', () {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: null,
        current: _base().copyWith(displayDescription: '今夜的月光'),
        threeLineLayout: true,
      );
      expect(next, isNotNull);
      expect(next!.artist, '歌手');
      expect(next.displayDescription, '专辑');
    });

    test('逐行推进不叠加、歌手不丢', () {
      var current = _base().copyWith(displayDescription: '专辑');
      for (final line in ['第一行', '第二行', '第三行']) {
        final next = applyNotificationLyric(
          base: _base(),
          lyric: line,
          current: current,
          threeLineLayout: true,
        );
        expect(next!.displayDescription, line);
        expect(next.artist, '歌手');
        expect(next.title, '歌名');
        current = next;
      }
    });

    test('同曲同歌词重复推送 → null（去重键含第三行）', () {
      expect(
        applyNotificationLyric(
          base: _base(),
          lyric: '今夜的月光',
          current: _base().copyWith(displayDescription: '今夜的月光'),
          threeLineLayout: true,
        ),
        isNull,
      );
    });

    test('三行布局不合并标题（歌手已在副标题）', () {
      final next = applyNotificationLyric(
        base: _base(),
        lyric: null,
        current: _base(),
        threeLineLayout: true,
      );
      expect(next!.title, '歌名', reason: '三行布局下歌手独立成行，标题不该重复拼接');
    });
  });

  group('版本分叉判据（AndroidPlatformInfo）', () {
    tearDown(() => AndroidPlatformInfo.debugSetSdkInt(0));

    test('API 29（Android 10）→ 三行布局', () {
      AndroidPlatformInfo.debugSetSdkInt(29);
      expect(AndroidPlatformInfo.useLegacyThreeLineNotification, isTrue);
    });

    test('API 30（Android 11）→ 两行布局（分界线本身不算老布局）', () {
      AndroidPlatformInfo.debugSetSdkInt(30);
      expect(AndroidPlatformInfo.useLegacyThreeLineNotification, isFalse);
    });

    test('API 34 → 两行布局', () {
      AndroidPlatformInfo.debugSetSdkInt(34);
      expect(AndroidPlatformInfo.useLegacyThreeLineNotification, isFalse);
    });

    test('未知（0 / 桌面 / 读取失败）→ 降级为新布局', () {
      AndroidPlatformInfo.debugSetSdkInt(0);
      expect(AndroidPlatformInfo.useLegacyThreeLineNotification, isFalse);
    });
  });
}
