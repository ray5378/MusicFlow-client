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
//
// 两个 androidIcon 必须是包内真实存在的 drawable：SystemUI 用
// Icon.createWithResource(packageName, icon) 加载，资源缺失只会画出一个空白
// 方块（不报错、不崩溃），所以下面连带钉住资源文件是否随包存在。
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
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

    test('播放中：列表四项，旧系统过滤掉 custom 后正好三格', () {
      final favorite = notificationFavoriteControl(
        starred: false,
        label: 'Add to favorites',
      );
      final bridgeControl = bridge(label: 'Add to favorites');
      final controls = notificationControls(
        playing: true,
        favorite: favorite,
        favoriteBridge: bridgeControl,
      );

      expect(controls, hasLength(4));
      expect(controls[0], same(bridgeControl));
      expect(controls[0].action, MediaAction.fastForward);
      expect(controls[0].androidIcon, kNotificationFavoriteIconOff);
      expect(controls[1], same(favorite));
      expect(controls[1].action, MediaAction.custom);
      expect(controls[2].action, MediaAction.pause);
      expect(controls[3].action, MediaAction.skipToNext);

      // 旧系统（Android 12 及以下）只把非 custom 控件放进通知的
      // nativeActions，再用 [0, 1, 2] 取折叠态三格 —— 必须是「心形 / 播放 /
      // 下一首」。这一条同时证明前几版「只发 custom」为什么在真机上没按钮。
      final nativeActions = controls
          .where((c) => c.action != MediaAction.custom)
          .toList();
      expect(nativeActions, hasLength(3));
      expect(nativeActions[0], same(bridgeControl));
      expect(nativeActions[1].action, MediaAction.pause);
      expect(nativeActions[2].action, MediaAction.skipToNext);

      // 一旦把 skipToPrevious 加回来，AOSP 的 A 槽会被标准上一首占掉。
      expect(
        controls.any((c) => c.action == MediaAction.skipToPrevious),
        isFalse,
        reason: '折叠态只有三格，上一首必须让位给收藏',
      );
    });

    test('暂停中：播放键位换成 play，其余不动', () {
      final favorite = notificationFavoriteControl(starred: true, label: 'x');
      final bridgeControl = bridge(starred: true, label: 'x');
      final controls = notificationControls(
        playing: false,
        favorite: favorite,
        favoriteBridge: bridgeControl,
      );

      expect(controls, hasLength(4));
      expect(controls[0], same(bridgeControl));
      expect(controls[1], same(favorite));
      expect(controls[2].action, MediaAction.play);
      expect(controls[3].action, MediaAction.skipToNext);
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
}
