import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/player/widgets/player_backdrop.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

/// 圆形直径与间距 —— 这是**专用页面**，不挤在 mini 条上方，所以给足尺寸。
const double _kRingSize = 78;
const double _kRingGap = 24;

/// 「流转播放队列」专用页面。
///
/// 一个圆 = 一个播放端：圆内是该端**此刻在播**的封面（没在播则显示设备图标），
/// 下方是**完整名称**（页面空间充足，不压缩成短名）。**本机占第一个圆。**
///
/// 交互：按住任意一个圆拖到另一个圆 —— 拖动方向就是「源 → 目标」。
/// 这本质上是把「流转播放」里既有的推 / 拉播放列表，做成一次拖拽。
///
/// 视觉：整页沿用大屏播放页那套「封面取色」体系（MusicFlowMediaColorScope +
/// MusicFlowPlayerBackdrop），不是一块白板；文字/图标色由 scope 重映射，
/// 深浅封面下都保证对比度。点空白处即可关闭（不放关闭按钮）。
class PlayerTransferPage extends ConsumerStatefulWidget {
  const PlayerTransferPage({super.key, required this.onTransfer});

  /// 执行流转：从 [from] 搬到 [to]；返回是否成功。
  final Future<bool> Function(PeerInfo from, PeerInfo to) onTransfer;

  /// 从任意入口打开本页面。
  static Future<void> open(
    BuildContext context, {
    required Future<bool> Function(PeerInfo from, PeerInfo to) onTransfer,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => PlayerTransferPage(onTransfer: onTransfer),
      ),
    );
  }

  @override
  ConsumerState<PlayerTransferPage> createState() => _PlayerTransferPageState();
}

class _PlayerTransferPageState extends ConsumerState<PlayerTransferPage> {
  /// null = 还在拉取。用普通 State 而不是 FutureProvider：
  /// 与已验证可用的「流转播放」弹窗（player_switcher）走同一套 loadPeers 调用方式，
  /// 避免 provider 依赖链上的加载态卡死（实测过：用 FutureProvider 时页面一直转圈）。
  List<PeerInfo>? _peers;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // **必须等首帧之后再拉**：loadPeers() 内部会写 castPeerController 的 state
    // (loadingPeers 标记)，而在 initState 这种 widget 生命周期里改 provider 会被
    // Riverpod 拒绝并抛「Tried to modify a provider while the widget tree was building」，
    // 整个页面直接崩掉 —— 表现就是一直转圈、一个圆都不出现。
    // player_switcher(流转播放弹窗)同样用 postFrameCallback，这里保持一致。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  /// 拉取可流转的播放端：本机排第一，其余为**在线**、非 Web 的端。
  ///
  /// 过滤口径与「流转播放」一致：离线端不展示（避免拖到一台已下线的端上才失败）；
  /// Web 端不出声，本就不是流转目标。
  Future<void> _load() async {
    final controller = ref.read(castPeerControllerProvider.notifier);
    final all = await controller.loadPeers();
    if (!mounted) return;
    PeerInfo? self;
    final others = <PeerInfo>[];
    for (final p in all) {
      if (p.isLocal && p.self) {
        self = p;
        continue;
      }
      if (p.available && p.platform != 'web') others.add(p);
    }
    setState(() => _peers = <PeerInfo>[if (self != null) self, ...others]);
  }

  Future<void> _handleDrop(PeerInfo from, PeerInfo to) async {
    if (_busy || from.peerId == to.peerId) return;
    setState(() => _busy = true);
    final ok = await widget.onTransfer(from, to);
    if (!mounted) return;
    setState(() => _busy = false);
    // 流转完成即关页：这是一次性动作，停在这里只会让人以为还要再点一下。
    if (ok) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // 与大屏播放页同一套封面取色（深浅封面自适应）。
    final visuals = ref.watch(resolvedCurrentSongMediaVisualsProvider);
    final peers = _peers;

    return MusicFlowMediaColorScope(
      visuals: visuals,
      role: MusicFlowMediaSurfaceRole.stage,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: MusicFlowPlayerBackdrop(
                visuals: visuals,
                mode: MusicFlowPlayerBackdropMode.stage,
              ),
            ),
            // 点空白即关（不放关闭按钮）。
            // 注意：这里必须包在**内容层外面** —— Scrollable 内部是
            // HitTestBehavior.opaque，会把指针事件吃掉，放在 Stack 下层的那层
            // "空白点击层"根本不在 hit test 链里，几乎触发不到（实测如此）。
            // 作为 Scrollable 的祖先才在链里：点圆 → 圆自己的 GestureDetector 吸收；
            // 点其余任何地方（圆之间的空隙、标题、上下留白）→ 落到这里关闭。
            SafeArea(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Column(
                  children: <Widget>[
                    const SizedBox(height: 20),
                    Text(
                      loc.player_transfer_title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      loc.player_transfer_hint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Expanded(
                      child: switch (peers) {
                        null => const Center(
                          child: CircularProgressIndicator(),
                        ),
                        [] => Center(child: Text(loc.player_transfer_empty)),
                        final list => SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                          child: Center(
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: _kRingGap,
                              runSpacing: _kRingGap + 8,
                              children: <Widget>[
                                for (final peer in list)
                                  _RingNode(
                                    peer: peer,
                                    isSelf: peer.isLocal && peer.self,
                                    onDragStateChanged: (_) {},
                                    onDropFrom: _handleDrop,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个播放端圆：既是拖拽源（按住它拖走 = 把它的队列给别人），
/// 也是落点（别的圆拖进来 = 把别人的队列给它）。
class _RingNode extends ConsumerWidget {
  const _RingNode({
    required this.peer,
    required this.isSelf,
    required this.onDragStateChanged,
    required this.onDropFrom,
  });

  final PeerInfo peer;

  /// 本机那个圆（列表第一位）：封面取本地播放态，不走 /status 轮询。
  final bool isSelf;
  final ValueChanged<PeerInfo?> onDragStateChanged;
  final Future<void> Function(PeerInfo from, PeerInfo to) onDropFrom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 吸收点击：在圆上按下不该被当成「点空白」而关页。
    return GestureDetector(
      onTap: () {},
      child: Draggable<PeerInfo>(
        data: peer,
        onDragStarted: () => onDragStateChanged(peer),
        onDragEnd: (_) => onDragStateChanged(null),
        onDraggableCanceled: (_, _) => onDragStateChanged(null),
        feedback: Material(
          color: Colors.transparent,
          child: _RingBubble(peer: peer, isSelf: isSelf, lifted: true),
        ),
        childWhenDragging: Opacity(
          opacity: 0.25,
          child: _RingBubble(peer: peer, isSelf: isSelf),
        ),
        child: DragTarget<PeerInfo>(
          onWillAcceptWithDetails: (details) =>
              details.data.peerId != peer.peerId,
          onAcceptWithDetails: (details) => onDropFrom(details.data, peer),
          builder: (context, candidates, rejected) => _RingBubble(
            peer: peer,
            isSelf: isSelf,
            highlighted: candidates.isNotEmpty,
          ),
        ),
      ),
    );
  }
}

/// 圆的视觉：圆内是当前曲封面，无封面时落回设备图标；下方是**完整名称**。
class _RingBubble extends ConsumerWidget {
  const _RingBubble({
    required this.peer,
    this.isSelf = false,
    this.highlighted = false,
    this.lifted = false,
  });

  final PeerInfo peer;

  /// 本机圆：封面直接取本地播放态（零延迟），不依赖服务端镜像。
  final bool isSelf;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.musicFlowColors;
    final String? cover;
    final bool playing;
    if (isSelf) {
      // 本机就是这个 App 自己 —— 本地播放态就是权威，省一次请求也零延迟。
      cover = ref.watch(
        playerProvider.select((s) => s.currentSong?.artworkReference),
      );
      playing = ref.watch(playerProvider.select((s) => s.isPlaying));
    } else {
      final nowPlaying = ref
          .watch(peerNowPlayingProvider(peer.peerId))
          .valueOrNull;
      playing = nowPlaying?.isActive == true;
      cover = playing ? nowPlaying?.coverArt : null;
    }

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
            // 取色体系里的 raised 面：深浅封面下都不会变成一块突兀的白。
            color: colors.raised,
            border: Border.all(
              // 落点高亮：拖到哪个圆上哪个圆亮起来 —— 「会落到谁那儿」一眼可见。
              color: highlighted
                  ? scheme.primary
                  : colors.ink.withValues(alpha: 0.28),
              width: highlighted ? 3 : 1,
            ),
          ),
          child: (playing && cover != null && cover.isNotEmpty)
              ? CoverArtImage(
                  coverArtId: cover,
                  size: _kRingSize,
                  requestSize: 240,
                  semanticLabel: peer.name,
                )
              : _DeviceIcon(peer: peer, dimmed: !playing),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: _kRingSize + 34,
          child: Text(
            peer.name,
            // 专用页面有足够空间：完整显示名称，不再压缩成短名；
            // 仅对极端长名兜底到两行，避免撑破网格。
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: lifted || highlighted ? scheme.primary : colors.ink,
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
    final colors = context.musicFlowColors;
    return Center(
      child: Icon(
        _iconFor(peer),
        size: 30,
        color: dimmed ? colors.muted : colors.ink,
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
