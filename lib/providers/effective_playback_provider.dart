import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/song.dart';
import 'cast_peer_provider.dart';
import 'dlna_provider.dart';
import 'player_provider.dart';
import 'queue_origin_provider.dart';

/// 统一「本机 / 后端投流 peer / 局域网 DLNA 直投」的播放状态与控制入口。
///
/// - 本机:进度/时长/播放态取 just_audio(playerProvider);
/// - 链路 A(服务端投屏,选中远端 peer):状态取 GET /v1/peers/:id/status 轮询结果,
///   控制命令 POST 到后端,由**后端**向设备投流——客户端不自行 SSDP/SOAP;
/// - 链路 B(局域网 DLNA 直投):状态取 dlna_cast_provider 轮询+插值结果,控制命令
///   由客户端的 DlnaManager 直接 SSDP/SOAP 下发给设备(仅本地中转取流/推流不同,
///   其余操作与前端显示基本复刻链路 A:全屏页的进度条/播放暂停/上下曲/跳转统一路由)。
final _dlnaCastingProvider = Provider<bool>((ref) {
  return ref.watch(dlnaCastProvider.select((s) => s.isCasting));
});

final effectivePositionProvider = Provider<Duration>((ref) {
  if (ref.watch(_dlnaCastingProvider)) {
    // 链路 B:500ms 插值 + 2s 轮询回写修正(对齐链路 A 的 smoothPosition)。
    return Duration(
      milliseconds:
          (ref.watch(dlnaCastProvider).smoothPositionSeconds * 1000).round(),
    );
  }
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
  if (ref.watch(_dlnaCastingProvider)) {
    return Duration(seconds: ref.watch(dlnaCastProvider).status.duration);
  }
  final cast = ref.watch(castPeerControllerProvider);
  if (cast.activePeer != null) {
    return Duration(milliseconds: (cast.status.durationSeconds * 1000).round());
  }
  return ref.watch(playerProvider.select((state) => state.duration));
});

final effectiveIsPlayingProvider = Provider<bool>((ref) {
  if (ref.watch(_dlnaCastingProvider)) {
    return ref.watch(dlnaCastProvider).status.state == 'PLAYING';
  }
  final cast = ref.watch(castPeerControllerProvider);
  if (cast.activePeer != null) return cast.status.playing;
  return ref.watch(playerProvider.select((state) => state.isPlaying));
});

/// 当前控制目标名称：本机或设备名（对齐主项目前端 currentPeerName）。
String currentPlayerName(CastPeerState cast) => cast.targetName;

/// 播放/暂停：链路 B 直投→指挥 DLNA 设备；投屏→命令后端；否则驱动本地播放器。
Future<void> toggleEffectivePlayback(WidgetRef ref) async {
  if (ref.read(_dlnaCastingProvider)) {
    await ref.read(dlnaCastProvider.notifier).toggle();
    return;
  }
  await ref.read(castPeerControllerProvider.notifier).toggle();
}

/// 暂停（定时停止等场景的显式暂停）:链路 B 直投→指挥 DLNA 设备暂停;
/// 链路 A 投屏→后端暂停;本机→本地暂停。cast_peer.pause() 内部无 activePeer
/// 时会自动回退到本机暂停,因此这里统一经由它即可。
Future<void> pauseEffectivePlayback(WidgetRef ref) async {
  if (ref.read(_dlnaCastingProvider)) {
    await ref.read(dlnaCastProvider.notifier).pause();
    return;
  }
  await ref.read(castPeerControllerProvider.notifier).pause();
}

/// 跳转进度。
Future<void> seekEffectivePlayback(WidgetRef ref, Duration position) async {
  if (ref.read(_dlnaCastingProvider)) {
    await ref.read(dlnaCastProvider.notifier).seek(position.inSeconds);
    return;
  }
  await ref.read(castPeerControllerProvider.notifier).seek(position);
}

/// 下一首。
Future<bool> nextEffectivePlayback(WidgetRef ref) async {
  if (ref.read(_dlnaCastingProvider)) {
    await ref.read(dlnaCastProvider.notifier).next();
    return true;
  }
  await ref.read(castPeerControllerProvider.notifier).next();
  return true;
}

/// 上一首。
Future<bool> previousEffectivePlayback(WidgetRef ref) async {
  if (ref.read(_dlnaCastingProvider)) {
    await ref.read(dlnaCastProvider.notifier).previous();
    return true;
  }
  await ref.read(castPeerControllerProvider.notifier).previous();
  return true;
}

/// **统一播放入口** —— 播放专辑/歌单/列表(对齐主项目前端 UI-routed playQueue):
/// - 投屏(选中远端 peer):命令**后端**以该队列在设备播放(客户端是远程遥控器);
/// - 本机:走 just_audio 本地播放。
///
/// [origin] 标记本次播放的来源（歌单/专辑/艺术家等），供封面「正在播放」
/// 指示器识别；为 null 时视为其它来源（首页随机/搜索等），清空封面指示。
Future<bool> playEffectiveQueue(
  WidgetRef ref,
  List<Song> songs, {
  int startIndex = 0,
  bool shuffleRandomStart = false,
  QueueOrigin? origin,
}) async {
  // 每次发起播放都覆盖来源标记：null → other（首页随机/搜索等无来源场景）。
  ref.read(queueOriginProvider.notifier).state =
      origin ?? const QueueOrigin(QueueOriginKind.other);
  // 链路 B(局域网 DLNA 直投):复用本机中转会话直接切队列播放,本人保持遥控器态。
  if (ref.read(_dlnaCastingProvider)) {
    return ref
        .read(dlnaCastProvider.notifier)
        .playQueueOnDevice(songs, startIndex: startIndex);
  }
  final cast = ref.read(castPeerControllerProvider);
  if (cast.activePeer != null) {
    return ref
        .read(castPeerControllerProvider.notifier)
        .playQueueOnPeer(songs, startIndex: startIndex);
  }
  await ref
      .read(playerProvider.notifier)
      .playQueue(
        songs,
        startIndex: startIndex,
        shuffleRandomStart: shuffleRandomStart,
      );
  return true;
}

/// **统一点歌入口**(对齐主项目前端 UI-routed playSong):
/// - 链路 B(局域网 DLNA 直投):指挥 DLNA 设备(复用本地中转,本机不出声);
/// - 投屏:命令后端在该设备播放(带队列上下文按整队播放,否则对齐 castPlaySong);
/// - 本机:走 just_audio。
Future<bool> playEffectiveSong(
  WidgetRef ref,
  Song song, {
  List<Song>? queue,
  int? index,
}) async {
  if (ref.read(_dlnaCastingProvider)) {
    return ref
        .read(dlnaCastProvider.notifier)
        .playSongOnDevice(song, queue: queue, index: index);
  }
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
