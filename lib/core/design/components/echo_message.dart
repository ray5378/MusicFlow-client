import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../echo_context.dart';
import '../tokens/echo_colors.dart';
import 'echo_icon_button.dart';
import 'echo_surface.dart';

enum EchoMessageKind { info, success, warning, error }

class EchoMessage extends StatelessWidget {
  const EchoMessage({
    super.key,
    required this.message,
    this.kind = EchoMessageKind.info,
    this.onDismiss,
  });

  final String message;
  final EchoMessageKind kind;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.echoColors;
    final accent = switch (kind) {
      EchoMessageKind.info => colors.accent,
      EchoMessageKind.success => colors.accent,
      EchoMessageKind.warning => colors.warning,
      EchoMessageKind.error => colors.error,
    };
    final icon = switch (kind) {
      EchoMessageKind.info => AppIcons.info,
      EchoMessageKind.success => AppIcons.checkCircle,
      EchoMessageKind.warning => AppIcons.warning,
      EchoMessageKind.error => AppIcons.error,
    };
    final background = colors.ink;
    final messageAccent = EchoColors.ensureColorContrast(
      accent,
      background: background,
      minimumRatio: 3,
    );
    final foreground = colors.canvas;

    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: EchoSurface(
        level: EchoSurfaceLevel.floating,
        color: background,
        borderRadius: context.echoRadii.control,
        borderColor: messageAccent,
        padding: EdgeInsetsDirectional.only(
          start: context.echoSpacing.sm,
          top: context.echoSpacing.xs,
          bottom: context.echoSpacing.xs,
          end: context.echoSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: context.echoInteraction.minimumTouchTarget,
              child: Center(child: Icon(icon, size: 22, color: messageAccent)),
            ),
            SizedBox(width: context.echoSpacing.xs),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  message,
                  style: context.echoTypography.body.copyWith(
                    color: foreground,
                  ),
                ),
              ),
            ),
            if (onDismiss != null) ...<Widget>[
              SizedBox(width: context.echoSpacing.xs),
              EchoIconButton(
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

ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showEchoMessage(
  BuildContext context,
  String message, {
  EchoMessageKind kind = EchoMessageKind.info,
  ScaffoldMessengerState? messenger,
  Duration? duration,
}) {
  final messengerState = messenger ?? ScaffoldMessenger.of(context);
  final animationsDisabled =
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  final motion = context.echoMotion;
  messengerState.hideCurrentSnackBar();

  final snackBar = SnackBar(
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    margin: EdgeInsets.fromLTRB(
      context.echoSpacing.md,
      context.echoSpacing.xs,
      context.echoSpacing.md,
      context.echoSpacing.md,
    ),
    behavior: SnackBarBehavior.floating,
    dismissDirection: DismissDirection.horizontal,
    duration:
        duration ??
        (kind == EchoMessageKind.error
            ? const Duration(seconds: 5)
            : const Duration(seconds: 3)),
    content: EchoMessage(
      message: message,
      kind: kind,
      onDismiss: messengerState.hideCurrentSnackBar,
    ),
  );

  return messengerState.showSnackBar(
    snackBar,
    snackBarAnimationStyle: animationsDisabled
        ? AnimationStyle.noAnimation
        : AnimationStyle(
            duration: motion.resolve(context, motion.feedback),
            reverseDuration: motion.resolve(context, motion.feedback),
          ),
  );
}

/// 右上角 Toast：从右侧滑入 + 淡入淡出，默认 3 秒自动消失。
/// 用于「切换播放器」等操作的轻量反馈（对齐主项目前端 Toast 交互）。
void showEchoToast(
  BuildContext context,
  String message, {
  EchoMessageKind kind = EchoMessageKind.info,
  Duration duration = const Duration(seconds: 3),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (entryContext) => _EchoTopToast(
      message: message,
      kind: kind,
      duration: duration,
      onDismissed: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

/// 右上角 Toast 实现：滑入/淡出动画 + 自动消失计时。
class _EchoTopToast extends StatefulWidget {
  const _EchoTopToast({
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final EchoMessageKind kind;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_EchoTopToast> createState() => _EchoTopToastState();
}

class _EchoTopToastState extends State<_EchoTopToast>
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
    final top = MediaQuery.paddingOf(context).top + context.echoSpacing.sm;
    return Positioned(
      top: top,
      right: context.echoSpacing.md,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            color: Colors.transparent,
            child: EchoMessage(
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
