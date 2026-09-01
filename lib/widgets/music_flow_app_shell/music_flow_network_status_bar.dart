import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design/components/music_flow_message.dart';
import '../../core/design/music_flow_design.dart';
import '../../core/utils/network_error_notifier.dart';

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
    this.startupSilentRecoveryWindow = const Duration(seconds: 30),
  });

  final MusicFlowNetworkStatus status;
  final Duration recoveryDisplayDuration;
  final bool includeBottomSafeArea;

  /// 启动后该窗口内的「连接达到」视为冷启动连上,静默恢复不弹提示。
  /// 可注入以便测试(测试时钟无法推进 DateTime.now 的真实时间)。
  final Duration startupSilentRecoveryWindow;

  @override
  State<MusicFlowNetworkStatusBar> createState() => _MusicFlowNetworkStatusBarState();
}

class _MusicFlowNetworkStatusBarState extends State<MusicFlowNetworkStatusBar> {
  Timer? _recoveryTimer;
  late _MusicFlowNetworkBannerState _bannerState;
  late final DateTime _createdAt;

  @override
  void initState() {
    super.initState();
    _createdAt = DateTime.now();
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

    // 「连接不到服务器」只在真正离线(本机断网)时才弹轻提示；
    // weak 仅代表可用线路健康瞬时波动/重试中，已通过内联横幅「网络不稳定」表达，
    // 不弹较重提示，避免「已连接并正在播放」时仍误报连接不到服务器。
    // 提示统一经 NetworkErrorNotifier，享受启动宽限期与节流去重。
    if (widget.status == MusicFlowNetworkStatus.offline &&
        oldWidget.status != MusicFlowNetworkStatus.offline) {
      // didUpdateWidget 发生在 build 阶段,此时同步插入 Toast 会触发对 Overlay
      // 的 markNeedsBuild(setState during build)。推迟到当前帧结束再通知。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        NetworkErrorNotifier.show('连接不到服务器');
      });
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
    setState(() {
      _bannerState = _MusicFlowNetworkBannerState.hidden;
    });
    // 启动后前 30 秒内连接上的场景视为「冷启动连上」,静默恢复即可,
    // 不弹「网络已恢复」的成功 Toast(横幅已隐藏)。30 秒后再恢复则正常提示。
    if (DateTime.now().difference(_createdAt) <
        widget.startupSilentRecoveryWindow) {
      return;
    }
    // 网络恢复：释放内联横幅空间，改为右上角成功 Toast。didUpdateWidget 发生在
    // build 阶段,推迟到帧结束再插入 Overlay,避免 setState during build。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      insertMusicFlowToast(
        overlay,
        '网络已恢复',
        kind: MusicFlowMessageKind.success,
        duration: widget.recoveryDisplayDuration,
        startAutoDismissOnInsert: true,
      );
    });
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
