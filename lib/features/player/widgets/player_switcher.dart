import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 单个远端播放器行的实时队列摘要订阅:「打开弹窗即拉、行销毁自动回收」。
/// 接续按钮可用性/第二行歌名都从这份数据来。
class PeerCastRow extends ConsumerWidget {
  const PeerCastRow({
    super.key,
    required this.peer,
    required this.selected,
    required this.onSwitch,
    required this.onHandoff,
    this.onRefresh,
  });

  final PeerInfo peer;
  final bool selected;

  /// 点击行主体 = 切换控制目标(原有语义,不变)。
  final Future<void> Function() onSwitch;

  /// 按下接续按钮(direction: true=推到音箱, false=接回本机)。
  /// 由调用方统一弹 toast/关弹窗。
  final Future<void> Function(bool push) onHandoff;

  /// 接续失败后的可选回调(如刷新 nowPlaying)。
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final typography = context.musicFlowTypography;
    final localQueue = ref.watch(
      castPeerControllerProvider.select((s) => s.activePeer == null),
    );
    final playerQueue = ref.watch(playerProvider.select((ps) => ps.queue));
    final nowAsync = ref.watch(peerNowPlayingProvider(peer.peerId));
    final now = nowAsync.valueOrNull;
    final canPull = (now?.isActive ?? false) && (now?.total ?? 0) > 0;
    // 本机是否真有播放现场可推:非投屏态且本机队列非空
    //(投屏态下本机队列只是远端镜像,没有「现场」可推)。
    final canPush = localQueue && playerQueue.isNotEmpty;

    return MusicFlowPressable(
      onPressed: onSwitch,
      selected: selected,
      borderRadius: context.musicFlowRadii.control,
      semanticLabel: peer.name,
      child: Ink(
        decoration: BoxDecoration(
          // 对齐 MusicFlowActionRow 选中态:accent 10% 薄染,不用实色。
          color: selected
              ? colors.accent.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: context.musicFlowRadii.control,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(
              switch (peer.kind) {
                'group' => AppIcons.people,
                _ => AppIcons.signalTower,
              },
              size: 22,
              color: selected ? colors.accent : colors.ink,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          peer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typography.title.copyWith(
                            color: selected ? colors.accent : colors.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _PeerBadge(label: peer.kindLabel, colors: colors),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    now == null
                        ? loc.player_peer_state_unknown
                        : (now.trackLabel.isEmpty
                              ? loc.player_peer_not_playing
                              : now.trackLabel),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.body.copyWith(color: colors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _HandoffButton(
              up: false,
              enabled: canPull,
              tooltip: loc.player_handoff_pull(peer.name),
              onPressed: () {
                onHandoff(false);
              },
            ),
            const SizedBox(width: 6),
            _HandoffButton(
              up: true,
              enabled: canPush,
              tooltip: loc.player_handoff_push(peer.name),
              onPressed: () {
                onHandoff(true);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 设备类型小徽章:紧跟设备名同行,展示 peer.kind(如 DLNA / AirPlay / Sendspin)。
class _PeerBadge extends StatelessWidget {
  const _PeerBadge({required this.label, required this.colors});

  final String label;
  final MusicFlowColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.controlBoundary, width: 0.5),
      ),
      child: Text(
        label,
        style: context.musicFlowTypography.body.copyWith(
          fontSize: 10,
          height: 1.4,
          color: colors.muted,
        ),
      ),
    );
  }
}

/// 接续按钮:只画一支粗箭头,朝下=接回本机(拉),朝上=推到音箱(推)。
/// 桌面端悬停高亮 + Tooltip 文字注释;无「现场」可搬时置灰。
class _HandoffButton extends StatelessWidget {
  const _HandoffButton({
    required this.up,
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool up;
  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MusicFlowPressable(
        minimumSize: const Size.square(34),
        borderRadius: BorderRadius.circular(9),
        semanticLabel: tooltip,
        onPressed: enabled ? onPressed : null,
        child: Center(
          child: CustomPaint(
            size: const Size(18, 18),
            painter: _HandoffArrowPainter(
              color: enabled ? colors.accent : colors.onDisabled,
              up: up,
            ),
          ),
        ),
      ),
    );
  }
}

/// 单箭头图标:粗竖杆 + 三角箭头头,朝向由 [up] 决定。
class _HandoffArrowPainter extends CustomPainter {
  _HandoffArrowPainter({required this.color, required this.up});

  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    // 箭头头:占上半约 55%,竖杆补满剩余长度。
    final tipY = up ? h * 0.08 : h * 0.92;
    final headBaseY = up ? h * 0.52 : h * 0.48;
    final headHalf = w * 0.34;
    final tailY = up ? h * 0.92 : h * 0.08;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.14
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(cx - headHalf, headBaseY)
      ..lineTo(cx, tipY)
      ..lineTo(cx + headHalf, headBaseY);
    canvas.drawPath(path, paint);
    canvas.drawLine(Offset(cx, headBaseY), Offset(cx, tailY), paint);
  }

  @override
  bool shouldRepaint(_HandoffArrowPainter old) =>
      old.color != color || old.up != up;
}

class PlayerSwitcherSheet extends ConsumerStatefulWidget {
  const PlayerSwitcherSheet({super.key});

  @override
  ConsumerState<PlayerSwitcherSheet> createState() =>
      _PlayerSwitcherSheetState();
}

class _PlayerSwitcherSheetState extends ConsumerState<PlayerSwitcherSheet> {
  List<PeerInfo>? _peers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  /// 直接加载后端 /peers 列表即可：后端本身持续自动扫描设备并维护
  /// available 状态，客户端不再额外触发 dlna/scan（避免每次切播放器都扫描）。
  Future<void> _reload() async {
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = await controller.loadPeers();
    if (mounted) setState(() => _peers = peers);
  }

  /// 接续搬移统一入口:push=true 本机→设备,false 设备→本机。
  /// 成功弹轻提示并关闭弹窗;失败报错且不动现有播放。
  Future<void> _doHandoff(
    BuildContext context,
    CastPeerController controller,
    PeerInfo peer,
    bool push,
  ) async {
    final loc = AppLocalizations.of(context);
    final ok = push
        ? await controller.pushLocalToPeer(peer)
        : await controller.pullPeerToLocal(peer);
    if (mounted) {
      ref.invalidate(peerNowPlayingProvider(peer.peerId));
    }
    if (!context.mounted) return;
    if (ok) {
      showMusicFlowMessage(
        context,
        push
            ? loc.player_handoff_push_success(peer.name)
            : loc.player_handoff_pull_success,
        kind: MusicFlowMessageKind.success,
      );
      if (context.mounted) Navigator.of(context).pop();
    } else {
      showMusicFlowMessage(
        context,
        loc.player_handoff_failed,
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cast = ref.watch(castPeerControllerProvider);
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = _peers;
    // 展示后端回报为可用（available）的**非本端**播放端：DLNA / AirPlay / 群组
    // 之外,还包括同账号的**另一台本机播放端**(网页端 / 另一台客户端)——它们
    // 同样是可被本端遥控的独立播放端。self 是服务端按发起请求的实例打的标,
    // 用它排除「本端自己那条」,而不是拿 kind=='local' 一刀切(那样会把别的
    // 客户端/网页端一起隐藏,表现为「流转播放里看不到 Web 播放器」)。
    final remotePeers = (peers ?? const <PeerInfo>[])
        .where((p) => !p.self && p.available)
        .toList()
        // 展示序与流转页(player_transfer_page)同一口径:**正在播的排前面**;
        // 同为在播/同为闲置时按 **客户端本机 > 群组 > 独立播放器**,再按名称。
        ..sort((a, b) {
          final pa = a.queueActive ? 0 : 1;
          final pb = b.queueActive ? 0 : 1;
          if (pa != pb) return pa - pb;
          final ra = a.isLocal ? 0 : (a.kind == 'group' ? 1 : 2);
          final rb = b.isLocal ? 0 : (b.kind == 'group' ? 1 : 2);
          if (ra != rb) return ra - rb;
          return a.name.compareTo(b.name);
        });

    return MusicFlowBottomSheet(
      title: loc.player_transfer_playback_title,
      subtitle: loc.player_transfer_playback_subtitle,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              MusicFlowActionRow(
                icon: AppIcons.headphones,
                title: loc.player_source_local_title,
                subtitle: cast.activePeer != null
                    ? (cast.offline
                          ? loc.player_source_offline
                          : loc.player_source_casting)
                    : loc.player_source_local_desc,
                selected: cast.activePeer == null,
                onPressed: () async {
                  // 回本机=仅切换控制目标(远端继续播,对齐前端 switchPeer);
                  // 用户主动选「本机播放」,快照当时在播则续播本机。
                  await controller.backToLocal(resumeLocal: true);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              if (cast.activePeer != null)
                MusicFlowActionRow(
                  icon: AppIcons.close,
                  title: loc.player_stop_cast,
                  subtitle: loc.player_stop_cast_subtitle(
                    cast.activePeer!.name,
                  ),
                  onPressed: () async {
                    await controller.stopCasting();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              if (remotePeers.isNotEmpty)
                for (final peer in remotePeers)
                  PeerCastRow(
                    key: ValueKey('sheet-peer-${peer.peerId}'),
                    peer: peer,
                    selected: cast.activePeer?.peerId == peer.peerId,
                    onSwitch: () async {
                      final ok = await controller.switchTo(peer);
                      if (!ok && context.mounted) {
                        showMusicFlowMessage(
                          context,
                          loc.player_cast_failed(peer.name),
                          kind: MusicFlowMessageKind.error,
                        );
                        return;
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    onHandoff: (push) =>
                        _doHandoff(context, controller, peer, push),
                  )
              else
                Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: context.musicFlowSpacing.sm,
                  ),
                  child: Text(
                    _peers == null
                        ? loc.player_loading_peers
                        : loc.player_no_other_players,
                    style: context.musicFlowTypography.body.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
                ),
              MusicFlowActionRow(
                icon: AppIcons.refresh,
                title: loc.player_refresh_players,
                trailing: cast.loadingPeers
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onPressed: cast.loadingPeers ? null : () => _reload(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
