import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design/music_flow_design.dart';

/// The reachability states surfaced by MusicFlow's application shell.
///
/// [online] is intentionally quiet. The shell only becomes visible when the
/// connection affects remote work, then briefly confirms recovery.
enum MusicFlowNetworkStatus { online, weak, offline }

enum _MusicFlowNetworkBannerState { hidden, weak, offline }

/// A layout-bound network status strip that preserves already loaded content.
///
/// This is deliberately not a Material banner or snackbar. It uses MusicFlow's
/// semantic colors, typography, spacing, motion, and icon vocabulary while
/// remaining inside the shell's normal layout flow.
class MusicFlowNetworkStatusBar extends StatefulWidget {
  const MusicFlowNetworkStatusBar({
    super.key,
    required this.status,
    this.recoveryDisplayDuration = const Duration(seconds: 3),
    this.includeBottomSafeArea = false,
  });

  final MusicFlowNetworkStatus status;
  final Duration recoveryDisplayDuration;
  final bool includeBottomSafeArea;

  @override
  State<MusicFlowNetworkStatusBar> createState() => _MusicFlowNetworkStatusBarState();
}

class _MusicFlowNetworkStatusBarState extends State<MusicFlowNetworkStatusBar> {
  Timer? _recoveryTimer;
  late _MusicFlowNetworkBannerState _bannerState;

  @override
  void initState() {
    super.initState();
    _bannerState = _stateForStatus(widget.status);
  }

  @override
  void didUpdateWidget(covariant MusicFlowNetworkStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status == widget.status) return;

    _recoveryTimer?.cancel();
    if (widget.status == MusicFlowNetworkStatus.online &&
        oldWidget.status != MusicFlowNetworkStatus.online) {
      _showRecovery();
      return;
    }

    setState(() {
      _bannerState = _stateForStatus(widget.status);
    });
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    super.dispose();
  }

  void _showRecovery() {
    // 网络恢复时不再使用内容区内的内联横幅，改为右上角 Toast 轻量通知，
    // 弱网/离线状态仍保留内联横幅以便持续提示。
    setState(() {
      _bannerState = _MusicFlowNetworkBannerState.hidden;
    });
    showMusicFlowToast(
      context,
      '网络已恢复',
      kind: MusicFlowMessageKind.success,
      duration: widget.recoveryDisplayDuration,
    );
  }

  static _MusicFlowNetworkBannerState _stateForStatus(MusicFlowNetworkStatus status) {
    return switch (status) {
      MusicFlowNetworkStatus.online => _MusicFlowNetworkBannerState.hidden,
      MusicFlowNetworkStatus.weak => _MusicFlowNetworkBannerState.weak,
      MusicFlowNetworkStatus.offline => _MusicFlowNetworkBannerState.offline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final motion = context.musicFlowMotion;
    final duration = motion.resolve(context, motion.state);

    return SizedBox(
      key: const ValueKey<String>('musicflow-network-status-slot'),
      width: double.infinity,
      child: ClipRect(
        child: AnimatedSize(
          alignment: Alignment.bottomCenter,
          duration: duration,
          curve: motion.easeOut,
          child: _bannerState == _MusicFlowNetworkBannerState.hidden
              ? const SizedBox.shrink()
              : AnimatedSwitcher(
                  duration: duration,
                  switchInCurve: motion.easeOut,
                  switchOutCurve: motion.easeOut,
                  child: _MusicFlowNetworkStatusContent(
                    key: ValueKey<_MusicFlowNetworkBannerState>(_bannerState),
                    state: _bannerState,
                    includeBottomSafeArea: widget.includeBottomSafeArea,
                  ),
                ),
        ),
      ),
    );
  }
}

class _MusicFlowNetworkStatusContent extends StatelessWidget {
  const _MusicFlowNetworkStatusContent({
    super.key,
    required this.state,
    required this.includeBottomSafeArea,
  });

  final _MusicFlowNetworkBannerState state;
  final bool includeBottomSafeArea;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final statusColor = colors.warning;
    final background = Color.alphaBlend(
      statusColor.withValues(
        alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.12,
      ),
      colors.surface,
    );
    final iconColor = MusicFlowColors.ensureColorContrast(
      statusColor,
      background: background,
      minimumRatio: 3,
    );
    final titleColor = MusicFlowColors.ensureColorContrast(
      colors.ink,
      background: background,
    );
    final descriptionColor = MusicFlowColors.ensureColorContrast(
      colors.muted,
      background: background,
    );
    final presentation = _presentationFor(state);
    final semanticsLabel = '${presentation.title}。${presentation.description}';

    return Semantics(
      key: ValueKey<String>('musicflow-network-status-${state.name}'),
      container: true,
      liveRegion: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.musicFlowSpacing.sm),
          child: MusicFlowSurface(
            key: const ValueKey<String>('musicflow-network-status-surface'),
            level: MusicFlowSurfaceLevel.surface,
            color: background,
            borderRadius: context.musicFlowRadii.surface,
            child: SafeArea(
              top: false,
              bottom: includeBottomSafeArea,
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  context.musicFlowPageHorizontalPadding,
                  context.musicFlowSpacing.xs,
                  context.musicFlowPageHorizontalPadding,
                  context.musicFlowSpacing.xs,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: EdgeInsets.only(
                        top: context.musicFlowSpacing.xxs / 2,
                      ),
                      child: Icon(
                        presentation.icon,
                        size: 20,
                        color: iconColor,
                      ),
                    ),
                    SizedBox(width: context.musicFlowSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            presentation.title,
                            style: context.musicFlowTypography.label.copyWith(
                              color: titleColor,
                            ),
                          ),
                          SizedBox(height: context.musicFlowSpacing.xxs),
                          Text(
                            presentation.description,
                            style: context.musicFlowTypography.metadata.copyWith(
                              color: descriptionColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static _MusicFlowNetworkPresentation _presentationFor(
    _MusicFlowNetworkBannerState state,
  ) {
    return switch (state) {
      _MusicFlowNetworkBannerState.weak => const _MusicFlowNetworkPresentation(
        title: '网络不稳定',
        description: '正在重试可用线路，已加载内容和离线歌曲仍可使用',
        icon: AppIcons.signal,
      ),
      _MusicFlowNetworkBannerState.offline => const _MusicFlowNetworkPresentation(
        title: '当前离线',
        description: '已加载内容和离线歌曲仍可使用，在线操作将在联网后恢复',
        icon: AppIcons.wifiOff,
      ),
      _MusicFlowNetworkBannerState.hidden => throw StateError(
        'Hidden network state has no visible presentation.',
      ),
    };
  }
}

class _MusicFlowNetworkPresentation {
  const _MusicFlowNetworkPresentation({
    required this.title,
    required this.description,
    required this.icon,
  });

  final String title;
  final String description;
  final IconData icon;
}
