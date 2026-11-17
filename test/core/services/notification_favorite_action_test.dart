// 通知栏收藏按钮：图标/名称/文案契约钉子。
//
// 按钮不是自绘通知，同一颗心形要走两条通道（两边只认各自那一条）：
//
// A. Android 13+：MediaSession 的自定义 action
//    MediaControl.custom(androidIcon, label, name) → createCustomAction()
//    → PlaybackState.CustomAction → AOSP SystemUI 13
//    MediaDataManager.createActionsFromState()：标准「上一首」缺席时，第一个
//    自定义 action 填进 A 槽（`A = previous, else custom`），即折叠态第一格
//    → 点击回传 AudioHandler.customAction(name, extras)
//
// B. Android 12 及以下：自定义 action 在 audio_service 原生层不进通知的
//    nativeActions（setState 里 custom 走另一分支），而老 SystemUI 只从通知
//    action 列表取按钮 → 只能借标准 fastForward 键冒充，图标仍用自己的心形
//    → 点击走 KEYCODE_MEDIA_FAST_FORWARD → AudioHandler.fastForward()
//    这条通路还多一个自由度：折叠态取哪三格由 androidCompactActionIndices
//    指定，所以上一首可以留在列表里、只出现在下拉展开后。
//
// 两个 androidIcon 必须是包内真实存在的 drawable：SystemUI 用
// Icon.createWithResource(packageName, icon) 加载，资源缺失只会画出一个空白
// 方块（不报错、不崩溃），所以下面连带钉住资源文件是否随包存在。
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/android_platform_info.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';

void main() {
  test('未收藏 → 空心图标 + 「收藏」文案', () {
    final control = notificationFavoriteControl(
      starred: false,
      label: 'Add to favorites',
    );
    expect(control.androidIcon, kNotificationFavoriteIconOff);
    expect(control.androidIcon, 'drawable/ic_notif_favorite_border');
    expect(control.label, 'Add to favorites');
    expect(control.action, MediaAction.custom);
    expect(control.customAction?.name, kNotificationFavoriteAction);
  });

  test('已收藏 → 实心图标 + 「取消收藏」文案（图标不同才会触发原生侧刷新）', () {
    final control = notificationFavoriteControl(
      starred: true,
      label: 'Remove from favorites',
    );
    expect(control.androidIcon, kNotificationFavoriteIconOn);
    expect(control.androidIcon, 'drawable/ic_notif_favorite');
    expect(control.label, 'Remove from favorites');
    // 实心/空心只能是两种不同资源，否则点了没反应（MediaControl 的 == 比图标）。
    expect(kNotificationFavoriteIconOn, isNot(kNotificationFavoriteIconOff));
  });

  test('action 名稳定：原生点击按这个 name 回传给 customAction', () {
    expect(kNotificationFavoriteAction, 'toggleFavorite');
  });

  group('通知栏收藏：双通道下发，任一系统都只出一个心形', () {
    MediaControl bridge({bool starred = false, String label = 'Add'}) =>
        notificationFavoriteBridgeControl(starred: starred, label: label);

    test('新通路（API 33+）：上一首必须缺席，心形靠 custom 填 A 槽', () {
      final favorite = notificationFavoriteControl(
        starred: false,
        label: 'Add to favorites',
      );
      final bridgeControl = bridge(label: 'Add to favorites');
      final controls = notificationControls(
        playing: true,
        favorite: favorite,
        favoriteBridge: bridgeControl,
        legacySlotOrder: false,
      );

      expect(controls, hasLength(4));
      expect(controls[0], same(bridgeControl));
      expect(controls[0].action, MediaAction.fastForward);
      expect(controls[0].androidIcon, kNotificationFavoriteIconOff);
      expect(controls[1], same(favorite));
      expect(controls[1].action, MediaAction.custom);
      expect(controls[2].action, MediaAction.pause);
      expect(controls[3].action, MediaAction.skipToNext);

      // 一旦把 skipToPrevious 加回来，AOSP 的 A 槽会被标准上一首占掉，
      // 自定义心形只能退到 C 槽 —— 折叠态里就没了。
      expect(
        controls.any((c) => c.action == MediaAction.skipToPrevious),
        isFalse,
        reason: '33+ 槽位固定，上一首存在就挤掉收藏',
      );
      expect(
        notificationCompactIndices(legacySlotOrder: false),
        [0, 1, 2],
      );
    });

    test('旧通路（API < 33）：折叠「播放 / 下一首 / 心形」，上一首留展开态', () {
      final favorite = notificationFavoriteControl(starred: false, label: 'x');
      final bridgeControl = bridge(label: 'x');
      final controls = notificationControls(
        playing: true,
        favorite: favorite,
        favoriteBridge: bridgeControl,
        legacySlotOrder: true,
      );

      // 列表原样：上一首 / 播放 / 下一首 / 心形（= 飞牛展开态那一排）。
      expect(controls, hasLength(4));
      expect(controls[0].action, MediaAction.skipToPrevious);
      expect(controls[1].action, MediaAction.pause);
      expect(controls[2].action, MediaAction.skipToNext);
      expect(controls[3], same(bridgeControl));

      // 折叠索引从第 2 个开始取，正好跳过上一首。
      final compact = notificationCompactIndices(legacySlotOrder: true);
      expect(compact, [1, 2, 3]);
      final collapsed = [for (final i in compact) controls[i]];
      expect(collapsed, hasLength(3));
      expect(collapsed[0].action, MediaAction.pause);
      expect(collapsed[1].action, MediaAction.skipToNext);
      expect(collapsed[2], same(bridgeControl));

      // 折叠态里不允许出现上一首（它只在展开态）。
      expect(
        collapsed.any((c) => c.action == MediaAction.skipToPrevious),
        isFalse,
      );
    });

    test('旧通路暂停中：折叠首格换成 play，其余不动', () {
      final favorite = notificationFavoriteControl(starred: true, label: 'x');
      final bridgeControl = bridge(starred: true, label: 'x');
      final controls = notificationControls(
        playing: false,
        favorite: favorite,
        favoriteBridge: bridgeControl,
        legacySlotOrder: true,
      );
      final compact = notificationCompactIndices(legacySlotOrder: true);

      expect(controls[compact[0]].action, MediaAction.play);
      expect(controls[compact[1]].action, MediaAction.skipToNext);
      expect(controls[compact[2]], same(bridgeControl));
    });

    test('两条通道的心形图标与文案必须一致，否则点一下就变样', () {
      for (final starred in [false, true]) {
        final favorite = notificationFavoriteControl(
          starred: starred,
          label: 'L',
        );
        final bridgeControl = bridge(starred: starred, label: 'L');
        expect(bridgeControl.androidIcon, favorite.androidIcon);
        expect(bridgeControl.label, favorite.label);
      }
    });
  });

  test('两个心形 drawable 都在 Android 资源目录里', () {
    for (final name in ['ic_notif_favorite', 'ic_notif_favorite_border']) {
      final file = File('android/app/src/main/res/drawable/$name.xml');
      expect(
        file.existsSync(),
        isTrue,
        reason: '$name.xml 缺失 → 通知栏按钮会变成空白方块',
      );
      expect(file.readAsStringSync(), contains('<vector'));
    }
  });

  // v5.17.13：真机仍是飞牛（3.5px）的 4 倍粗。根因不是 strokeWidth 数值，而是
  // 空心那颗用了 Material 官方**带内孔**的路径——外轮廓 + 内轮廓两个子路径，
  // stroke 会把内外各描一遍，视觉厚度 = 内孔间距 2 + strokeWidth。下面两条断言
  // 一起钉死「单轮廓 + 线宽数值」，缺一条都可能让图标重新变粗。
  group('心形图标资源守卫', () {
    String read(String name) =>
        File('android/app/src/main/res/drawable/$name.xml').readAsStringSync();

    test('空心只用单条外轮廓，不许再出现内孔子路径', () {
      final border = read('ic_notif_favorite_border');

      // 带内孔的 pathData 里必然有 "zM"（第一条子路径闭合后紧跟第二条）。
      expect(
        border,
        isNot(contains('zM')),
        reason: '双轮廓路径 + stroke = 视觉厚度 4.6 单位，比参考实现粗 4 倍',
      );

      final paths = RegExp(r'android:pathData="([^"]+)"')
          .allMatches(border)
          .map((m) => m[1])
          .toList();
      expect(paths, hasLength(2));
      expect(paths[0], paths[1], reason: '白层与深色层必须描同一条轮廓');

      // 白色在下层先画、深色在上层后画：浅色卡片上白线只从两侧露出 0.15 单位。
      final colors = RegExp(r'android:strokeColor="([^"]+)"')
          .allMatches(border)
          .map((m) => m[1])
          .toList();
      expect(colors, ['#FFFFFFFF', '#FF1A1A1A']);
    });

    test('线宽停在细档，不许回粗', () {
      final border = read('ic_notif_favorite_border');
      expect(border, contains('android:strokeWidth="1.6"'));
      expect(border, contains('android:strokeWidth="1.3"'));

      // 实心那颗单轮廓 + 白填充，描边 1.0 与空心的视觉重量对齐。
      expect(read('ic_notif_favorite'), contains('android:strokeWidth="1.0"'));
    });
  });

  group('按钮通路分叉判据（AndroidPlatformInfo）', () {
    tearDown(() => AndroidPlatformInfo.debugSetSdkInt(0));

    test('API 32 → 通知 action 列表通路（上一首可留展开态）', () {
      AndroidPlatformInfo.debugSetSdkInt(32);
      expect(AndroidPlatformInfo.usesNotificationActionSlots, isTrue);
    });

    test('API 33 → PlaybackState 槽位通路（上一首必须让位）', () {
      AndroidPlatformInfo.debugSetSdkInt(33);
      expect(AndroidPlatformInfo.usesNotificationActionSlots, isFalse);
    });

    test('未知（0）→ 按新通路，宁可少一个上一首也不挤掉收藏', () {
      AndroidPlatformInfo.debugSetSdkInt(0);
      expect(AndroidPlatformInfo.usesNotificationActionSlots, isFalse);
    });
  });
}
