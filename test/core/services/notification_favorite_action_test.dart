// 通知栏收藏按钮：图标/名称/文案契约钉子。
//
// 按钮不是自绘通知，而是 MediaSession 的自定义 action：
//   MediaControl.custom(androidIcon, label, name)
//   → audio_service 原生 createCustomAction() → PlaybackState.CustomAction
//   → AOSP SystemUI 13 MediaDataManager.createMediaButton() 填进展开态第 4 个槽
//   → 点击回传 AudioHandler.customAction(name, extras)
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
