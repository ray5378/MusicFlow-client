import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';

/// 淡入淡出时长 Provider（毫秒，0 = 关闭）
final crossfadeDurationMsProvider =
    NotifierProvider<CrossfadeNotifier, int>(CrossfadeNotifier.new);

class CrossfadeNotifier extends Notifier<int> {
  // Riverpod 2.6 的 Notifier 没有 同步通知基类.mounted，用 onDispose 钩子
  // 仿真同一语义（ADR-23 阶段 3）：异步 _load 回来时判活再写 state。
  bool _mounted = true;

  @override
  int build() {
    ref.onDispose(() => _mounted = false);
    _load();
    return 0;
  }

  Future<void> _load() async {
    final ms = await LocalStorage.getCrossfadeDurationMs();
    if (_mounted) state = ms;
  }

  Future<void> setDuration(int ms) async {
    final clamped = ms.clamp(0, 3000);
    state = clamped;
    await LocalStorage.setCrossfadeDurationMs(clamped);
  }
}
