import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/song.dart';
import 'cast_peer_provider.dart';
import 'player_provider.dart';

/// 统一「本机 / 后端投流 peer」的播放状态与控制入口。
///
/// - 本机:进度/时长/播放态取 just_audio(playerProvider);
/// - 投屏(选中远端 peer):状态取 GET /v1/peers/:id/status 轮询结果,
///   控制命令 POST 到后端,由**后端**向设备投流 —— 客户端不再自行 SSDP/SOAP。
final effectivePositionProvider = Provider<Duration>((ref) {
  final cast = ref.watch(castPeerControllerProvider);
  if (cast.activePeer != null) {
    // 平滑进度:250/500ms 插值 + 轮询回写修正。
    return Duration(
      milliseconds: (cast.smoothPositionSeconds * 1000).round(),
    );
  }
  return ref.watch(playerProvider.select((state) => state.position));
});

final effectiveDurationProvider = Provider<Duration>((ref) {
  final cast = ref.watch(castPeerControllerProvider);
  if (cast.activePeer != null) {
    return Duration(milliseconds: (cast.status.durationSeconds * 1000).round());
  }
  return ref.watch(playerProvider.select((state) => state.duration));
});

final effectiveIsPlayingProvider = Provider<bool>((ref) {
  final cast = ref.watch(castPeerControllerProvider);
  if (cast.activePeer != null) return cast.status.playing;
  return ref.watch(playerProvider.select((state) => state.isPlaying));
});

/// 当前控制目标名称：本机或设备名（对齐主项目前端 currentPeerName）。
String currentPlayerName(CastPeerState cast) => cast.targetName;

/// 播放/暂停：投屏时命令后端，否则驱动本地播放器。
Future<void> toggleEffectivePlayback(WidgetRef ref) async {
  await ref.read(castPeerControllerProvider.notifier).toggle();
}

/// 跳转进度。
Future<void> seekEffectivePlayback(WidgetRef ref, Duration position) async {
  await ref.read(castPeerControllerProvider.notifier).seek(position);
}

/// 下一首。
Future<bool> nextEffectivePlayback(WidgetRef ref) async {
  await ref.read(castPeerControllerProvider.notifier).next();
  return true;
}

/// 上一首。
Future<bool> previousEffectivePlayback(WidgetRef ref) async {
  await ref.read(castPeerControllerProvider.notifier).previous();
  return true;
}

/// **统一播放入口** —— 播放专辑/歌单/列表(对齐主项目前端 UI-routed playQueue):
/// - 投屏(选中远端 peer):命令**后端**以该队列在设备播放(客户端是远程遥控器);
/// - 本机:走 just_audio 本地播放。
Future<bool> playEffectiveQueue(
  WidgetRef ref,
  List<Song> songs, {
  int startIndex = 0,
}) async {
  final cast = ref.read(castPeerControllerProvider);
  if (cast.activePeer != null) {
    return ref
        .read(castPeerControllerProvider.notifier)
        .playQueueOnPeer(songs, startIndex: startIndex);
  }
  await ref
      .read(playerProvider.notifier)
      .playQueue(songs, startIndex: startIndex);
  return true;
}

/// **统一点歌入口**(对齐主项目前端 UI-routed playSong):
/// - 投屏:命令后端在该设备播放(带队列上下文按整队播放,否则对齐 castPlaySong);
/// - 本机:走 just_audio。
Future<bool> playEffectiveSong(
  WidgetRef ref,
  Song song, {
  List<Song>? queue,
  int? index,
}) async {
  final cast = ref.read(castPeerControllerProvider);
  if (cast.activePeer != null) {
    return ref
        .read(castPeerControllerProvider.notifier)
        .playSongOnPeer(song, queue: queue, index: index);
  }
  await ref
      .read(playerProvider.notifier)
      .playSong(song, queue: queue, index: index);
  return true;
}
