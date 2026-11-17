import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:musicflow_client/core/utils/logger.dart';

/// 媒体通知「用户可见文本布局」的分界 API：Android 11 = API 30。
///
/// 30 起媒体卡片由 SystemUI 用 MediaSession 元数据渲染，只读
/// `DISPLAY_TITLE ?? TITLE` 与 `METADATA_KEY_ARTIST` 两行；30 以下
/// audio_service 自建 MediaStyle 通知，标题 / 歌手 / subText 三行都渲染。
const int kSystemUiMediaNotificationMinApi = 30;

/// 媒体卡片「按钮来源」的分界 API：Android 13 = API 33。
///
/// 33 起 SystemUI 改从 MediaSession 的 PlaybackState 取按钮
/// （`MediaDataManager.createActionsFromState`），槽位固定
/// `play/pause A B C D`，`A = previous, else custom`；33 以下仍从通知的
/// action 列表取按钮，只有 `nativeActions` 里的标准动作会被渲染。
/// 两条通路的按钮顺序与是否保留上一首完全不同，所以必须分叉。
const int kPlaybackStateActionSlotsMinApi = 33;

/// Android 平台信息（目前只有 API level）。
///
/// 为什么自建通道：`package_info_plus` 不给 API level，而媒体通知的歌词落点
/// 必须按版本分叉 ——
/// - API >= 30：只有两行，歌词占用副标题（artist 行）；
/// - API < 30：三行，标题=歌名、副标题=歌手、subText(displayDescription)=歌词。
///
/// v5.17.2 的教训：在 30+ 上把歌词写进 displayDescription 是**零消费方**的
/// 静默失效；反过来在 < 30 上把歌词塞进副标题则会让老设备丢掉歌手名。
/// 所以版本判定必须在入口处做对，而不是猜。
class AndroidPlatformInfo {
  AndroidPlatformInfo._();

  static const MethodChannel _channel =
      MethodChannel('com.musicflow.app/platform_info');

  static int _sdkInt = 0;

  /// 当前 API level；0 = 未知（桌面 / 非 Android / 尚未加载完成）。
  static int get sdkInt => _sdkInt;

  /// 是否走「三行」老布局：仅 Android 且 API < 30。
  ///
  /// 未知一律按新布局（两行）处理 —— 宁可少显示一行，也不要把歌词写回
  /// 30+ 上没人读的 displayDescription。
  static bool get useLegacyThreeLineNotification =>
      _sdkInt > 0 && _sdkInt < kSystemUiMediaNotificationMinApi;

  /// 是否走「通知 action 列表」这条老通路（API < 33）。
  ///
  /// true：SystemUI 按控件列表顺序画按钮，折叠态取
  /// `androidCompactActionIndices` 指定的三格 → 可以把上一首挤到展开态；
  /// false（33+）：系统按固定槽位重排，上一首一旦存在就会占掉自定义按钮的
  /// A 槽位，折叠态里就再也放不下收藏。
  ///
  /// 未知（0）按新通路处理 —— 宁可少一个上一首，也不要让收藏被挤出折叠态。
  static bool get usesNotificationActionSlots =>
      _sdkInt > 0 && _sdkInt < kPlaybackStateActionSlotsMinApi;

  /// 读取一次 API level（幂等、失败降级为「未知 → 新布局」）。
  ///
  /// 必须在 [initAudioService] 里 await 一次，早于任何 mediaItem 推送。
  static Future<void> load() async {
    if (defaultTargetPlatform != TargetPlatform.android || _sdkInt > 0) return;
    try {
      final value = await _channel.invokeMethod<int>('androidSdkInt');
      if (value != null && value > 0) _sdkInt = value;
    } catch (e) {
      Logger.warn('AndroidPlatformInfo: read androidSdkInt failed', e);
    }
  }

  /// 单测注入，生产代码不要调用。
  @visibleForTesting
  static void debugSetSdkInt(int value) => _sdkInt = value;
}
