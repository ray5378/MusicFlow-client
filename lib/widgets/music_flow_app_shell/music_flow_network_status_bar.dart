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

    // 连接不上(弱网/离线)时，右上角弹红色脉冲圆点轻提示。
    if (widget.status != MusicFlowNetworkStatus.online &&
        oldWidget.status == MusicFlowNetworkStatus.online) {
      showNetworkStatusPulse(
        context,
        connected: false,
        duration: widget.recoveryDisplayDuration,
      );
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
    // 网络恢复时不再弹文字 Toast，改为右上角绿色脉冲圆点轻提示，
    // 弱网/离线状态仍保留内联横幅以便持续提示。
    setState(() {
      _bannerState = _MusicFlowNetworkBannerState.hidden;
    });
    showNetworkStatusPulse(
      context,
      connected: true,
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

/// 网络状态轻提示的颜色：连接成功绿、连接失败红。
const Color _networkConnectedGreen = Color(0xFF34C759);
const Color _networkOfflineRed = Color(0xFFFF3B30);

/// 在右上角弹出一个带光晕、会膨胀缩小的网络状态圆点轻通知。
///
/// [connected] 为 true 时显示绿色圆点（网络恢复），为 false 时显示红色圆点
/// （连接不上）。自动消失，替代原先的「网络已恢复」文字 Toast。
void showNetworkStatusPulse(
  BuildContext context, {
  required bool connected,
  Duration duration = const Duration(seconds: 3),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  insertNetworkStatusPulse(overlay, connected: connected, duration: duration);
}

/// 把网络状态脉冲圆点插入指定的 [OverlayState]（右上角）。
OverlayEntry insertNetworkStatusPulse(
  OverlayState overlay, {
  required bool connected,
  Duration duration = const Duration(seconds: 3),
}) {
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (entryContext) => _NetworkStatusPulse(
      connected: connected,
      duration: duration,
      onDismissed: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
  return entry;
}

/// 右上角脉冲圆点实现：绿/红圆点 + 光晕 + 膨胀缩小的外扩光环，自动消失。
class _NetworkStatusPulse extends StatefulWidget {
  const _NetworkStatusPulse({
    required this.connected,
    required this.duration,
    required this.onDismissed,
  });

  final bool connected;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_NetworkStatusPulse> createState() => _NetworkStatusPulseState();
}

class _NetworkStatusPulseState extends State<_NetworkStatusPulse>
    with TickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final AnimationController _pulseController;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeController.forward();
    _pulseController.repeat(reverse: true);
    _dismissTimer = Timer(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    _pulseController.stop();
    _fadeController.reverse().whenComplete(() {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _fadeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.connected ? _networkConnectedGreen : _networkOfflineRed;
    final top = MediaQuery.paddingOf(context).top + context.musicFlowSpacing.sm;
    return Positioned(
      top: top,
      right: context.musicFlowSpacing.md,
      child: FadeTransition(
        opacity: _fadeController,
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_pulseController.value);
            final haloRingOpacity = 0.5 * (1 - t);
            final glowBlur = 5.0 + 7.0 * t;
            final glowSpread = 1.0 + 2.5 * t;
            return SizedBox.square(
              dimension: 18,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // 膨胀缩小的外扩光环。
                  Transform.scale(
                    scale: 1 + 0.9 * t,
                    child: Opacity(
                      opacity: haloRingOpacity,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color.withValues(alpha: 0.6),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 光晕 + 实心圆点。
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: color.withValues(alpha: 0.55),
                          blurRadius: glowBlur,
                          spreadRadius: glowSpread,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
