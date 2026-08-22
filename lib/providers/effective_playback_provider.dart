import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'player_provider.dart';
import 'dlna_provider.dart';

/// 当正在投屏到 DLNA 设备时，播放进度/时长/状态应反映设备的实时状态，
/// 而不是本地被暂停的播放器。以下 Provider 统一屏蔽「本机 / 投屏设备」差异，
/// 供迷你播放器、全屏播放器、歌词等界面消费。
///
/// 对齐主项目前端的 remote-peer 播放状态机：切换播放器后应实时显示该播放器
/// 正在播放的内容、进度与歌词，并由当前控件控制该播放器。

final effectivePositionProvider = Provider<Duration>((ref) {
  final cast = ref.watch(dlnaCastProvider);
  if (cast.isCasting) return Duration(seconds: cast.status.position);
  return ref.watch(playerProvider.select((state) => state.position));
});

final effectiveDurationProvider = Provider<Duration>((ref) {
  final cast = ref.watch(dlnaCastProvider);
  if (cast.isCasting) return Duration(seconds: cast.status.duration);
  return ref.watch(playerProvider.select((state) => state.duration));
});

final effectiveIsPlayingProvider = Provider<bool>((ref) {
  final cast = ref.watch(dlnaCastProvider);
  if (cast.isCasting) return cast.status.state == 'PLAYING';
  return ref.watch(playerProvider.select((state) => state.isPlaying));
});

/// 切换播放/暂停：投屏时控制设备，否则控制本地播放器。
Future<void> toggleEffectivePlayback(WidgetRef ref) async {
  final cast = ref.read(dlnaCastProvider);
  if (cast.isCasting) {
    if (cast.status.state == 'PLAYING') {
      await ref.read(dlnaCastProvider.notifier).pause();
    } else {
      await ref.read(dlnaCastProvider.notifier).resume();
    }
  } else {
    await ref.read(playerProvider.notifier).togglePlayPause();
  }
}

/// 跳转进度：投屏时控制设备，否则控制本地播放器。
Future<void> seekEffectivePlayback(WidgetRef ref, Duration position) async {
  final cast = ref.read(dlnaCastProvider);
  if (cast.isCasting) {
    ref.read(dlnaCastProvider.notifier).seek(position.inSeconds);
  } else {
    await ref.read(playerProvider.notifier).seek(position);
  }
}
