import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/player/widgets/mini_player.dart';

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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cast = ref.watch(castPeerControllerProvider);
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = _peers;
    // 只展示后端回报为可用（available）的远端设备，离线设备不显示。
    final remotePeers = (peers ?? const <PeerInfo>[])
        .where((p) => !p.isLocal && p.available)
        .toList();

    return MusicFlowBottomSheet(
      title: loc.player_select_source_title,
      subtitle: loc.player_select_source_subtitle,
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
                    ? (cast.offline ? loc.player_source_offline : loc.player_source_casting)
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
                  subtitle: loc.player_stop_cast_subtitle(cast.activePeer!.name),
                  onPressed: () async {
                    await controller.stopCasting();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              if (remotePeers.isNotEmpty)
                for (final peer in remotePeers)
                  MusicFlowActionRow(
                    icon: switch (peer.kind) {
                      'group' => AppIcons.people,
                      'airplay' => AppIcons.signalTower,
                      _ => AppIcons.signalTower,
                    },
                    title: peer.name,
                    subtitle: <String>[
                      peer.kindLabel,
                      if (peer.queueTotal > 0) peer.queueLabel,
                    ].join(' · '),
                    selected: cast.activePeer?.peerId == peer.peerId,
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      final ok = await controller.switchTo(peer);
                      if (!ok && context.mounted) {
                        showMusicFlowMessage(
                          context,
                          loc.player_cast_failed(peer.name),
                          kind: MusicFlowMessageKind.error,
                        );
                        return;
                      }
                      navigator.pop();
                    },
                  )
              else
                Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: context.musicFlowSpacing.sm,
                  ),
                  child: Text(
                    _peers == null ? loc.player_loading_peers : loc.player_no_other_players,
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

/// 电脑端「切换播放器」小弹窗：播放控件上方弹出、点击外部自动关闭。
/// 数据源直接取后端 /peers 列表（后端自行扫描维护可用状态，客户端不触发
/// 扫描）；只展示 available 的远端设备，离线设备不显示。
/// 切换完成或关闭后通过 [onSwitched] 回调通知调用方弹出右上角 Toast。
class PlayerSwitcherPopover extends ConsumerStatefulWidget {
  const PlayerSwitcherPopover({super.key, required this.onSwitched});

  /// 切换完成（或用户主动关闭）时回调，参数为要展示的 Toast 文案。
  final ValueChanged<String?> onSwitched;

  @override
  ConsumerState<PlayerSwitcherPopover> createState() =>
      _PlayerSwitcherPopoverState();
}

class _PlayerSwitcherPopoverState extends ConsumerState<PlayerSwitcherPopover> {
  List<PeerInfo>? _peers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = await controller.loadPeers();
    if (mounted) setState(() => _peers = peers);
  }

  void _close({String? toast}) {
    widget.onSwitched(toast);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cast = ref.watch(castPeerControllerProvider);
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = _peers;
    final remotePeers = (peers ?? const <PeerInfo>[])
        .where((p) => !p.isLocal && p.available)
        .toList();
    final isDesktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

    return Stack(
      children: <Widget>[
        // 点击弹窗外任意位置自动关闭。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _close(),
          ),
        ),
        Positioned(
          // 播放控件(MiniPlayer)上方的小弹窗。
          bottom: isDesktop ? MiniPlayer.height + 24 : 80,
          right: 16,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              constraints: const BoxConstraints(maxHeight: 380),
              child: MusicFlowSurface(
                level: MusicFlowSurfaceLevel.floating,
                borderRadius: context.musicFlowRadii.scene,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.musicFlowSpacing.sm,
                        context.musicFlowSpacing.xs,
                        context.musicFlowSpacing.xs,
                        context.musicFlowSpacing.xxs,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              loc.player_select_source_title,
                              style: context.musicFlowTypography.headline,
                            ),
                          ),
                          MusicFlowIconButton(
                            icon: AppIcons.close,
                            label: loc.widgets_window_close,
                            onPressed: () => _close(),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          context.musicFlowSpacing.xs,
                          0,
                          context.musicFlowSpacing.xs,
                          context.musicFlowSpacing.xs,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            MusicFlowActionRow(
                              icon: AppIcons.headphones,
                              title: loc.player_source_local_title,
                              subtitle: cast.activePeer != null
                                  ? (cast.offline ? loc.player_source_offline : loc.player_source_casting)
                                  : loc.player_source_local_desc,
                              selected: cast.activePeer == null,
                              onPressed: () async {
                                await controller.backToLocal(resumeLocal: true);
                                _close(toast: loc.player_switched_local);
                              },
                            ),
                            if (cast.activePeer != null)
                              MusicFlowActionRow(
                                icon: AppIcons.close,
                                title: loc.player_stop_cast,
                                subtitle: loc.player_stop_cast_subtitle(cast.activePeer!.name),
                                onPressed: () async {
                                  await controller.stopCasting();
                                  _close(toast: loc.player_stopped_cast);
                                },
                              ),
                            if (remotePeers.isNotEmpty)
                              for (final peer in remotePeers)
                                MusicFlowActionRow(
                                  icon: switch (peer.kind) {
                                    'group' => AppIcons.people,
                                    _ => AppIcons.signalTower,
                                  },
                                  title: peer.name,
                                  subtitle: <String>[
                                    peer.kindLabel,
                                    if (peer.queueTotal > 0) peer.queueLabel,
                                  ].join(' · '),
                                  selected:
                                      cast.activePeer?.peerId == peer.peerId,
                                  onPressed: () async {
                                    final ok = await controller.switchTo(peer);
                                    if (!ok) {
                                      if (context.mounted) {
                                        showMusicFlowMessage(
                                          context,
                                          loc.player_cast_failed(peer.name),
                                          kind: MusicFlowMessageKind.error,
                                        );
                                      }
                                      return;
                                    }
                                    _close(toast: loc.player_remote_control(peer.name));
                                  },
                                )
                            else
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  vertical: context.musicFlowSpacing.sm,
                                ),
                                child: Text(
                                  _peers == null ? loc.player_loading_peers : loc.player_no_other_players,
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
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : null,
                              onPressed: cast.loadingPeers
                                  ? null
                                  : () => _reload(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
