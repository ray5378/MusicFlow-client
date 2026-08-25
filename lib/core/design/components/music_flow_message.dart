import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../music_flow_context.dart';
import '../tokens/music_flow_colors.dart';
import 'music_flow_icon_button.dart';
import 'music_flow_surface.dart';

enum MusicFlowMessageKind { info, success, warning, error }

class MusicFlowMessage extends StatelessWidget {
  const MusicFlowMessage({
    super.key,
    required this.message,
    this.kind = MusicFlowMessageKind.info,
    this.onDismiss,
  });

  final String message;
  final MusicFlowMessageKind kind;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final accent = switch (kind) {
      MusicFlowMessageKind.info => colors.accent,
      MusicFlowMessageKind.success => colors.accent,
      MusicFlowMessageKind.warning => colors.warning,
      MusicFlowMessageKind.error => colors.error,
    };
    final icon = switch (kind) {
      MusicFlowMessageKind.info => AppIcons.info,
      MusicFlowMessageKind.success => AppIcons.checkCircle,
      MusicFlowMessageKind.warning => AppIcons.warning,
      MusicFlowMessageKind.error => AppIcons.error,
    };
    final background = colors.ink;
    final messageAccent = MusicFlowColors.ensureColorContrast(
      accent,
      background: background,
      minimumRatio: 3,
    );
    final foreground = colors.canvas;

    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: MusicFlowSurface(
        level: MusicFlowSurfaceLevel.floating,
        color: background,
        borderRadius: context.musicFlowRadii.control,
        borderColor: messageAccent,
        padding: EdgeInsetsDirectional.only(
          start: context.musicFlowSpacing.sm,
          top: context.musicFlowSpacing.xs,
          bottom: context.musicFlowSpacing.xs,
          end: context.musicFlowSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: Center(child: Icon(icon, size: 22, color: messageAccent)),
            ),
            SizedBox(width: context.musicFlowSpacing.xs),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  message,
                  style: context.musicFlowTypography.body.copyWith(
                    color: foreground,
                  ),
                ),
              ),
            ),
            if (onDismiss != null) ...<Widget>[
              SizedBox(width: context.musicFlowSpacing.xs),
              MusicFlowIconButton(
                icon: AppIcons.close,
                label: '关闭通知',
                foregroundColor: foreground,
                backgroundColor: Colors.transparent,
                onPressed: onDismiss,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 统一的消息反馈：不再使用底部横幅（SnackBar），一律改为右上角 Toast。
void showMusicFlowMessage(
  BuildContext context,
  String message, {
  MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  ScaffoldMessengerState? messenger,
  Duration? duration,
}) {
  showMusicFlowToast(
    context,
    message,
    kind: kind,
    duration:
        duration ??
        (kind == MusicFlowMessageKind.error
            ? const Duration(seconds: 5)
            : const Duration(seconds: 3)),
  );
}

/// 右上角 Toast：从右侧滑入 + 淡入淡出，默认 3 秒自动消失。
/// 用于「切换播放器」等操作的轻量反馈（对齐主项目前端 Toast 交互）。
void showMusicFlowToast(
  BuildContext context,
  String message, {
  MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  Duration duration = const Duration(seconds: 3),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  insertMusicFlowToast(
    overlay,
    message,
    kind: kind,
    duration: duration,
  );
}

/// 把一条 Toast 插入指定的 [OverlayState] 中。为 `showMusicFlowToast` 与
/// `ToastNotifier`（在 Widget 树外）共用，保证统一使用右上角 Toast。
OverlayEntry insertMusicFlowToast(
  OverlayState overlay,
  String message, {
  MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  Duration duration = const Duration(seconds: 3),
}) {
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (entryContext) => _MusicFlowTopToast(
      message: message,
      kind: kind,
      duration: duration,
      onDismissed: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
  return entry;
}

/// 右上角 Toast 实现：滑入/淡出动画 + 自动消失计时。
class _MusicFlowTopToast extends StatefulWidget {
  const _MusicFlowTopToast({
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final MusicFlowMessageKind kind;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_MusicFlowTopToast> createState() => _MusicFlowTopToastState();
}

class _MusicFlowTopToastState extends State<_MusicFlowTopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _slide = Tween<Offset>(
      begin: const Offset(1.2, 0),
      end: Offset.zero,
    ).animate(curve);
    _fade = Tween<double>(begin: 0, end: 1).animate(curve);
    _controller.forward();
    _dismissTimer = Timer(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    _controller.reverse().whenComplete(() {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + context.musicFlowSpacing.sm;
    return Positioned(
      top: top,
      right: context.musicFlowSpacing.md,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            color: Colors.transparent,
            child: MusicFlowMessage(
              message: widget.message,
              kind: widget.kind,
              onDismiss: _dismiss,
            ),
          ),
        ),
      ),
    );
  }
}
