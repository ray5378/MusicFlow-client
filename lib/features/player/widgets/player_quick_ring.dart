import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

/// 快捷区是否展开 —— 由 mini 播放器的封面长按切换（触屏长按 / 鼠标按住同一套手势）。
///
/// 放在 provider 而不是局部 state：mini 封面（既是「本机」节点又是开关）与本组件
/// （其它端的圆）分属两棵子树，必须共享同一个开关。
final playerQuickRingVisibleProvider = StateProvider<bool>((ref) => false);

/// 快捷区数据源：可流转的播放端。
///
/// - `others`：**在线**、非 Web、排除本机自己那条 —— 这些各占一个圆；
/// - `self`：本机那条（不占圆，视觉由 mini 播放器的封面承担，同时兼作长按开关）。
///
/// autoDispose + 只在展开时被 watch ⇒ 收起即释放，不会常驻轮询列表。
final quickRingPeersProvider = FutureProvider.autoDispose<
    ({List<PeerInfo> others, PeerInfo? self})>((ref) async {
  final peers = await ref.read(castPeerControllerProvider.notifier).loadPeers();
  PeerInfo? self;
  final others = <PeerInfo>[];
  for (final p in peers) {
    if (p.isLocal && p.self) {
      self = p;
      continue;
    }
    // 过滤口径与「选择播放器」一致：离线端不展示（避免拖到一台已下线的端上才失败）；
    // Web 端不出声，本就不是流转目标。
    if (p.available && p.platform != 'web') others.add(p);
  }
  return (others: others, self: self);
});

/// 展开后无操作多久自动收起（用户口径「两种都要」：拖完即收 + 闲置也收）。
const Duration kQuickRingIdleDismiss = Duration(seconds: 6);

const double _kRingSize = 54;
const double _kRingGap = 16;

/// mini 播放器上方的「播放器圆形快捷区」。
///
/// 一个圆 = 一个当前可流转的播放端：圆内是该端**此刻在播**的封面（没在播则落回
/// 设备图标），下方一行短名（过长截断）。**本机不在这里** —— 它就是 mini 播放器
/// 那张封面本身（既是节点又是长按开关）。
///
/// 交互：按住任意圆拖到另一个圆（或本机封面）即完成一次流转 —— 拖动方向就是
/// 源 → 目标。松手立即收起，闲置数秒也会收起。
class PlayerQuickRing extends ConsumerStatefulWidget {
  const PlayerQuickRing({super.key, required this.onTransfer});

  /// 执行流转：从 [from] 搬到 [to]；返回是否成功。
  final Future<bool> Function(PeerInfo from, PeerInfo to) onTransfer;

  @override
  ConsumerState<PlayerQuickRing> createState() => _PlayerQuickRingState();
}

class _PlayerQuickRingState extends ConsumerState<PlayerQuickRing> {
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _restartIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  void _restartIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(kQuickRingIdleDismiss, _dismiss);
  }

  void _dismiss() {
    _idleTimer?.cancel();
    if (mounted) {
      ref.read(playerQuickRingVisibleProvider.notifier).state = false;
    }
  }

  Future<void> _handleDrop(PeerInfo from, PeerInfo to) async {
    if (from.peerId == to.peerId) return;
    // 拖完即收：不给"它还在那儿"的错觉，也避免紧接着误触第二次。
    _dismiss();
    await widget.onTransfer(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(quickRingPeersProvider).valueOrNull;
    final others = data?.others ?? const <PeerInfo>[];
    if (others.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: _kRingGap,
        runSpacing: _kRingGap,
        children: <Widget>[
          for (final peer in others)
            _RingNode(
              peer: peer,
              onDropFrom: _handleDrop,
              onInteract: _restartIdle,
            ),
        ],
      ),
    );
  }
}

/// 单个播放端圆：既是拖拽源（按住它拖走 = 把它的队列给别人），
/// 也是落点（别的圆 / 本机封面拖进来 = 把别人的队列给它）。
class _RingNode extends ConsumerWidget {
  const _RingNode({
    required this.peer,
    required this.onDropFrom,
    required this.onInteract,
  });

  final PeerInfo peer;
  final Future<void> Function(PeerInfo from, PeerInfo to) onDropFrom;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Draggable<PeerInfo>(
      data: peer,
      onDragStarted: onInteract,
      // 拖起来的那份：略透明，明确"手上拿着它"。
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(opacity: 0.92, child: _RingBubble(peer: peer, lifted: true)),
      ),
      childWhenDragging: Opacity(opacity: 0.28, child: _RingBubble(peer: peer)),
      child: DragTarget<PeerInfo>(
        onWillAcceptWithDetails: (details) {
          // 自己拖自己不算流转。
          if (details.data.peerId == peer.peerId) return false;
          onInteract(); // 悬停即续命：正在操作时不该被闲置计时器收起
          return true;
        },
        onAcceptWithDetails: (details) => onDropFrom(details.data, peer),
        builder: (context, candidates, rejected) => _RingBubble(
          peer: peer,
          highlighted: candidates.isNotEmpty,
        ),
      ),
    );
  }
}

/// 圆的视觉：圆内是当前曲封面，无封面时落回设备图标；下方一行短名（截断）。
class _RingBubble extends ConsumerWidget {
  const _RingBubble({
    required this.peer,
    this.highlighted = false,
    this.lifted = false,
  });

  final PeerInfo peer;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final nowPlaying = ref.watch(peerNowPlayingProvider(peer.peerId)).valueOrNull;
    final playing = nowPlaying?.isActive == true;
    final cover = playing ? nowPlaying?.coverArt : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: _kRingSize,
          height: _kRingSize,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surfaceContainerHighest,
            border: Border.all(
              // 落点高亮：拖到哪个圆上哪个圆亮起来 —— 「会落到谁那儿」一眼可见。
              color: highlighted ? scheme.primary : scheme.outlineVariant,
              width: highlighted ? 2.5 : 1,
            ),
          ),
          child: (cover != null && cover.isNotEmpty)
              ? CoverArtImage(
                  coverArtId: cover,
                  size: _kRingSize,
                  requestSize: 120,
                  semanticLabel: peer.name,
                )
              : _DeviceIcon(peer: peer, dimmed: !playing),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: _kRingSize + 16,
          child: Text(
            peer.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis, // 短名过长直接截断
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: lifted || highlighted
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }
}

/// 没在播（或曲目无封面）时的设备图标：按 kind + platform 区分。
class _DeviceIcon extends StatelessWidget {
  const _DeviceIcon({required this.peer, this.dimmed = false});

  final PeerInfo peer;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Icon(
        _iconFor(peer),
        size: 22,
        color: dimmed ? scheme.onSurfaceVariant : scheme.onSurface,
      ),
    );
  }

  IconData _iconFor(PeerInfo p) {
    if (p.kind == 'group') return Icons.speaker_group_outlined;
    if (p.kind == 'airplay') return Icons.airplay;
    if (p.kind == 'sendspin') return Icons.graphic_eq;
    if (p.kind == 'local') {
      return switch ((p.platform ?? '').toLowerCase()) {
        'android' || 'ios' => Icons.smartphone,
        'windows' || 'macos' || 'linux' => Icons.desktop_windows_outlined,
        _ => Icons.devices_other,
      };
    }
    return Icons.speaker_outlined; // dlna 及其它渲染器
  }
}
