import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_visibility_provider.dart';
import 'effective_playback_provider.dart';
import 'lyrics_cover_provider.dart';

/// 窗口不可见时「冻结」的 UI 播放进度。
///
/// 不可见期间播放继续（position 仍按 200~500ms 更新），但 UI 不再跟随：
/// 冻结保持最后一次可见值，恢复可见的瞬间立即跳回真实进度。
/// 用于迷你条进度环 / 歌词行 / 大屏进度条等高频重建区域，避免窗口
/// 不可见时每 200~500ms 触发一次无意义的重建与重绘。
final frozenPositionProvider =
    NotifierProvider<FrozenPositionNotifier, Duration>(
      FrozenPositionNotifier.new,
    );

class FrozenPositionNotifier extends Notifier<Duration> {
  Duration _last = Duration.zero;

  @override
  Duration build() {
    final visible = ref.watch(isRenderingActiveProvider);
    final position = ref.watch(effectivePositionProvider);
    if (visible) _last = position;
    // 不可见时返回缓存值：Riverpod 按 == 去重，UI 不会收到通知、零重建。
    return _last;
  }
}

/// 同 [frozenPositionProvider]：不可见时迷你条歌词行冻结在最后一行。
final frozenLyricLineProvider =
    NotifierProvider<FrozenLyricLineNotifier, String?>(
      FrozenLyricLineNotifier.new,
    );

class FrozenLyricLineNotifier extends Notifier<String?> {
  String? _last;

  @override
  String? build() {
    final visible = ref.watch(isRenderingActiveProvider);
    final line = ref.watch(currentLyricLineProvider);
    if (visible) _last = line;
    return _last;
  }
}
