// 通知栏 handler 层行为锁（**阻塞**）。
//
// 分工：
//   - notification_favorite_action_test.dart → 纯函数与资源：按钮集合/顺序/图标契约/drawable
//   - notification_lyrics_test.dart          → 纯函数：标题合并 / 歌词写入 / 进度外推
//   - 本文件                                  → **接线**：更新 MediaItem 之后真正进 PlaybackState
//     的是什么。纯函数再正确，接错地方通知栏一样不对——v5.17.10 之前就在这里翻过车
//     （只发 custom action，Android 12 及以下一个心形都看不到）。
//
// 为什么必须 `TestWidgetsFlutterBinding.ensureInitialized()`：
//   `AudioPlayer()` 内部会实例化 AudioSession，后者要 `MethodChannel.setMethodCallHandler`，
//   没有 binding 会抛「Binding has not yet been initialized」的断言，测试在 setUp 就挂。

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musicflow_client/core/services/android_platform_info.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';

MediaItem _item({
  String id = 'song-1',
  String title = '歌名',
  String artist = '歌手',
  bool starred = false,
}) =>
    MediaItem(
      id: id,
      title: title,
      artist: artist,
      extras: {'starred': starred ? '1' : '0'},
    );

List<MediaAction> _actions(MusicFlowAudioHandler h) =>
    h.playbackState.value.controls.map((c) => c.action).toList();

/// 两条通道各自的那颗心形。
MediaControl _customHeart(MusicFlowAudioHandler h) => h
    .playbackState.value.controls
    .firstWhere((c) => c.customAction?.name == kNotificationFavoriteAction);

MediaControl _bridgeHeart(MusicFlowAudioHandler h) => h
    .playbackState.value.controls
    .firstWhere((c) => c.action == MediaAction.fastForward);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MusicFlowAudioHandler handler;

  setUp(() {
    handler = MusicFlowAudioHandler(AudioPlayer());
  });

  tearDown(() async {
    AndroidPlatformInfo.debugSetSdkInt(0);
    await handler.dispose();
  });

  group('按钮下发：两条通路各按系统的取法排布', () {
    test('API 33+：心形靠 custom 填 A 槽，上一首彻底不发', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item());

      expect(_actions(handler), [
        MediaAction.fastForward, // 旧系统的备用通道，13+ 不渲染
        MediaAction.custom, // 心形，填「上一首」让出的 A 槽
        MediaAction.pause, // updateMediaItem 一律按「正在播放」起播
        MediaAction.skipToNext,
      ]);
      expect(
        _actions(handler),
        isNot(contains(MediaAction.skipToPrevious)),
        reason: '上一首一旦出现在 13+ 的通路里就会占掉 A 槽，心形退到展开态',
      );
      expect(handler.playbackState.value.androidCompactActionIndices, [0, 1, 2]);
    });

    test('API 32：上一首留在列表末尾，折叠索引 1~3 把它挤到展开态', () async {
      AndroidPlatformInfo.debugSetSdkInt(32);
      await handler.updateMediaItem(_item());

      expect(_actions(handler), [
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.fastForward, // 老系统唯一的收藏通道
      ]);
      expect(
        handler.playbackState.value.androidCompactActionIndices,
        [1, 2, 3],
        reason: '折叠态取 1~3 = 播放 / 下一首 / 心形，与参考 App 一致',
      );
    });

    test('折叠索引只来自 notificationCompactIndices，不再有硬编码常量', () async {
      for (final sdk in [29, 32, 33, 34]) {
        AndroidPlatformInfo.debugSetSdkInt(sdk);
        await handler.updateMediaItem(_item(id: 'song-$sdk'));

        expect(
          handler.playbackState.value.androidCompactActionIndices,
          notificationCompactIndices(
            legacySlotOrder: AndroidPlatformInfo.usesNotificationActionSlots,
          ),
          reason: 'API $sdk 的折叠索引与纯函数不一致',
        );
      }
    });
  });

  group('收藏：状态来源与两条落点', () {
    test('extras.starred 决定首帧心形（不能沿用上一首的状态）', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item(starred: true));
      expect(_customHeart(handler).androidIcon, kNotificationFavoriteIconOn);

      await handler.updateMediaItem(_item(id: 'song-2', starred: false));
      expect(_customHeart(handler).androidIcon, kNotificationFavoriteIconOff);
    });

    test('setFavoriteState 变值时图标跟着变，同值不重推', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item(starred: false));

      final before = handler.playbackState.value;
      handler.setFavoriteState(false);
      expect(
        identical(handler.playbackState.value, before),
        isTrue,
        reason: '同值早退：每 300ms 一次的歌词推送不该顺带重建通知',
      );

      handler.setFavoriteState(true);
      expect(_customHeart(handler).androidIcon, kNotificationFavoriteIconOn);
      expect(_bridgeHeart(handler).androidIcon, kNotificationFavoriteIconOn);
    });

    test('customAction(toggleFavorite) 走 onToggleFavorite，返回值立即上屏', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item(starred: false));

      var calls = 0;
      handler.onToggleFavorite = () async {
        calls++;
        return true;
      };

      await handler.customAction(kNotificationFavoriteAction);
      expect(calls, 1);
      expect(_customHeart(handler).androidIcon, kNotificationFavoriteIconOn);
    });

    test('fastForward 与 customAction 落同一个 toggle（老系统只有这条路）', () async {
      AndroidPlatformInfo.debugSetSdkInt(32);
      await handler.updateMediaItem(_item(starred: false));

      var calls = 0;
      handler.onToggleFavorite = () async {
        calls++;
        return true;
      };

      await handler.fastForward();
      expect(calls, 1, reason: '耳机/车机的快进键整条通道让给收藏');
      expect(_bridgeHeart(handler).androidIcon, kNotificationFavoriteIconOn);
    });

    test('未注册 onToggleFavorite 时点按钮不崩、不改状态', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item(starred: false));
      handler.onToggleFavorite = null;

      await handler.customAction(kNotificationFavoriteAction);
      await handler.fastForward();

      expect(_customHeart(handler).androidIcon, kNotificationFavoriteIconOff);
    });

    test('未知 custom action 走 super，不误触收藏', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item(starred: false));

      var calls = 0;
      handler.onToggleFavorite = () async {
        calls++;
        return true;
      };

      await handler.customAction('somethingElse');
      expect(calls, 0);
      expect(_customHeart(handler).androidIcon, kNotificationFavoriteIconOff);
    });
  });

  group('歌词写入 MediaItem（通知栏副标题）', () {
    test('两行布局：歌词进副标题，主标题仍是「歌名 - 歌手」', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item());

      handler.updateNotificationLyric('第一句歌词');
      final item = handler.mediaItem.valueOrNull!;
      expect(item.title, '歌名 - 歌手');
      expect(item.artist, '第一句歌词');
    });

    test('无歌词写空串，绝不回落歌手名', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item());
      handler.updateNotificationLyric('第一句歌词');

      handler.updateNotificationLyric(null);
      final item = handler.mediaItem.valueOrNull!;
      expect(item.artist, kNotificationEmptyLyric);
      expect(item.title, '歌名 - 歌手', reason: '主标题不该因为没歌词而变化');
    });

    test('没有底稿时早退（不崩、不产生空 MediaItem）', () async {
      expect(handler.mediaItem.valueOrNull, isNull);
      handler.updateNotificationLyric('随便一句');
      expect(handler.mediaItem.valueOrNull, isNull);
    });

    test('三行布局 API<30：歌手留在副标题，歌词进第三行', () async {
      AndroidPlatformInfo.debugSetSdkInt(29);
      await handler.updateMediaItem(_item());

      expect(handler.mediaItem.valueOrNull!.artist, '歌手');
      expect(handler.mediaItem.valueOrNull!.title, '歌名');

      handler.updateNotificationLyric('第一句歌词');
      final item = handler.mediaItem.valueOrNull!;
      expect(item.artist, '歌手', reason: '三行布局副标题仍归歌手');
      expect(item.displayDescription, '第一句歌词');
    });

    test('同曲重推保留歌词，换曲清空', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item());
      handler.updateNotificationLyric('第一句歌词');

      // 同曲重推（交叉淡入 / metadata 刷新）
      await handler.updateMediaItem(_item(title: '歌名'));
      expect(
        handler.mediaItem.valueOrNull!.artist,
        '第一句歌词',
        reason: '同曲重推把歌词打回空 → 通知栏在下一句之前一直空着',
      );

      // 换曲
      await handler.updateMediaItem(_item(id: 'song-2', title: '新歌'));
      expect(handler.mediaItem.valueOrNull!.artist, kNotificationEmptyLyric);
    });
  });

  group('投屏态：进度由投屏驱动', () {
    test('setCastProgress 把投屏进度与播放态写进通知栏', () async {
      AndroidPlatformInfo.debugSetSdkInt(33);
      await handler.updateMediaItem(_item());

      handler.setCastProgress(
        active: true,
        playing: false,
        position: const Duration(seconds: 42),
      );

      final state = handler.playbackState.value;
      expect(state.playing, isFalse);
      expect(state.updatePosition, const Duration(seconds: 42));
      expect(state.speed, 0.0, reason: '暂停的投屏不该在通知栏继续外推');
    });
  });
}
