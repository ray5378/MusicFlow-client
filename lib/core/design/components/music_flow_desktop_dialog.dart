import 'package:flutter/material.dart';

import '../music_flow_context.dart';
import '../../theme/app_icons.dart';
import 'music_flow_icon_button.dart';
import 'music_flow_surface.dart';

/// 在 Windows/桌面端显示「窗户」样式的模态弹窗。
///
/// 与安卓式的底部抽屉不同:无拖拽把手、四角等圆角、顶部是独立的标题栏,
/// 呈现原生 Windows 对话框的观感。用于更新检测等需要区隔平台样式的交互。
Future<T?> showMusicFlowDesktopDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
}) {
  final duration = context.musicFlowMotion.resolve(
    context,
    context.musicFlowMotion.scene,
  );

  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: context.musicFlowColors.scrim,
    transitionDuration: duration,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (dialogContext, animation, secondaryAnimation) => SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 320,
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.85,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: builder(dialogContext),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Windows 风格的对话框窗体:id=独立的标题栏 + 正文区,四角等圆角,无底部抽屉痕。
class MusicFlowDesktopDialog extends StatelessWidget {
  const MusicFlowDesktopDialog({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.showCloseButton = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool showCloseButton;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final colors = context.musicFlowColors;
    final radius = context.musicFlowRadii.scene;

    return Semantics(
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: MusicFlowSurface(
        level: MusicFlowSurfaceLevel.modal,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 独立标题栏:与安卓底部抽屉不同,Windows 对话框有独立的窗头。
            Container(
              color: colors.raised.withValues(alpha: 0.6),
              padding: EdgeInsets.fromLTRB(
                spacing.md,
                spacing.xs,
                spacing.xs,
                spacing.xs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon!, size: 20, color: colors.accent),
                    SizedBox(width: spacing.sm),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: context.musicFlowTypography.title.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colors.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showCloseButton) ...<Widget>[
                    SizedBox(width: spacing.xs),
                    MusicFlowIconButton(
                      icon: AppIcons.close,
                      label: '关闭',
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  ],
                ],
              ),
            ),
            if (subtitle != null) ...<Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  spacing.md,
                  spacing.md,
                  spacing.md,
                  0,
                ),
                child: Text(
                  subtitle!,
                  style: context.musicFlowTypography.body.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
            ],
            // 正文区:内容超出可用高度时在此滚动,标题栏保持固定(Windows 习惯)。
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    spacing.md,
                    spacing.md,
                    spacing.md,
                    spacing.md,
                  ),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}