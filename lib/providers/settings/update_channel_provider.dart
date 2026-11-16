import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';

/// 更新通道偏好 Provider（StateNotifier，镜像 appLanguageProvider 的范式）。
///
/// - 默认 [UpdateChannel.gitee]（用户确认的默认通道，国内直连更快）；
/// - 构造时异步从 [LocalStorage] 加载已保存的偏好（老用户升级后无记录
///   → 保持默认 gitee）；
/// - [UpdateChannelNotifier.setChannel] 先改内存态再持久化，UI 即时反馈。
final updateChannelProvider =
    StateNotifierProvider<UpdateChannelNotifier, UpdateChannel>(
      (ref) => UpdateChannelNotifier(),
    );

/// 更新通道偏好 Notifier。
class UpdateChannelNotifier extends StateNotifier<UpdateChannel> {
  UpdateChannelNotifier() : super(UpdateChannel.gitee) {
    _load();
  }

  Future<void> _load() async {
    final raw = await LocalStorage.getUpdateChannel();
    // 异步加载完成前 provider 可能已被销毁（页面退出/测试 dispose）：
    // 此后再写 state 会抛 StateError，直接丢弃这次加载即可。
    if (!mounted) return;
    if (raw == UpdateChannel.github.name) {
      state = UpdateChannel.github;
    }
  }

  /// 切换更新通道并持久化（同值时为 no-op，避免无谓写 prefs）。
  Future<void> setChannel(UpdateChannel channel) async {
    if (state == channel) return;
    state = channel;
    await LocalStorage.setUpdateChannel(channel.name);
  }
}
