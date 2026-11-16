import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// Android 通知栏实时歌词控制器。
///
/// 把 [currentLyricLineProvider]（与迷你播放条 / 桌面歌词窗同一数据源：
/// 按当前播放进度在同步歌词里二分出的那一行）逐行推送到系统媒体通知的
/// **副标题行**（MediaItem.artist → METADATA_KEY_ARTIST）；无同步歌词 /
/// 歌词行消失时还原真实歌手。
///
/// 为什么是 artist：Android 11+ 的媒体通知由 SystemUI 用 MediaSession 元数据
/// 直接渲染，AOSP MediaDataManager 只取 `DISPLAY_TITLE ?? TITLE` 与
/// `METADATA_KEY_ARTIST`，`MediaData` 里没有 album/description 字段 ——
/// 写 displayDescription（setSubText）在 Android 11+ 上无人消费，就是
/// v5.17.2 「通知栏不显示歌词」的根因。通知栏只有两行，「底部那行」= artist。
///
/// 播放期间 Flutter 引擎因媒体前台服务（audio_service）存活，App 退到
/// 后台 / 熄屏后本控制器仍能随进度 tick 逐行更新通知。
///
/// 仅移动平台激活监听：桌面平台没有 audio_service 通知（player_provider
/// `_init` 显式抛 UnsupportedError），订阅只会白白触发歌词网络拉取——
/// 按 statusLyricsController 同样的按需订阅策略，桌面直接不监听。
/// 在 MainScaffold initState 里 read 一次以激活。
final notificationLyricsControllerProvider =
    Provider<NotificationLyricsController>((ref) {
  final controller = NotificationLyricsController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

class NotificationLyricsController {
  NotificationLyricsController(this._ref) {
    if (_isDesktopLike) return;
    _subs.add(
      _ref.listen<String?>(
        currentLyricLineProvider,
        (_, line) => _push(line),
      ),
    );
  }

  final Ref _ref;
  final List<ProviderSubscription<String?>> _subs = [];

  /// 与 player_provider 的 `_isDesktopPlatform` 同口径（web 归为桌面）。
  static bool get _isDesktopLike =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// handler 每次从 playerProvider.notifier 现取而不是缓存：
  /// `_init` 的世代重跑（invalidate / 重新初始化）会整体换实例，
  /// 缓存引用会把歌词推到已废弃的旧 handler 上。
  void _push(String? line) {
    try {
      _ref
          .read(playerProvider.notifier)
          .audioHandler
          ?.updateNotificationLyric(line);
    } catch (e) {
      Logger.warnWithTag('NOTIF_LYRICS', 'push lyric to notification', e);
    }
  }

  void dispose() {
    for (final sub in _subs) {
      sub.close();
    }
    _subs.clear();
  }
}
