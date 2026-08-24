import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../music_flow_context.dart';
import '../tokens/music_flow_breakpoints.dart';
import '../tokens/music_flow_spacing.dart';
import 'music_flow_icon_button.dart';
import 'music_flow_pressable.dart';
import 'music_flow_surface.dart';

Future<T?> showEchoBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = false,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
}) async {
  final previousFocus = FocusManager.instance.primaryFocus;
  final motion = context.musicFlowMotion;
  final duration = motion.resolve(context, motion.scene);

  final T? result;
  if (context.musicFlowWindowClass != MusicFlowWindowClass.compact) {
    // 桌面端(medium/expanded):不用安卓式底部抽屉,改用居中的模态弹窗,
    // 更符合 Windows「对话框」交互习惯;淡入 + 轻微缩放,共享同一动效时长。
    result = await showGeneralDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierDismissible: isDismissible,
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
            constraints: const BoxConstraints(maxWidth: 520),
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
  } else {
    // 移动端(compact):保留安卓式底部抽屉,是手机端自然的交互。
    result = await showModalBottomSheet<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useSafeArea: true,
      requestFocus: true,
      showDragHandle: false,
      elevation: 0,
      backgroundColor: Colors.transparent,
      barrierColor: context.musicFlowColors.scrim,
      clipBehavior: Clip.none,
      constraints: const BoxConstraints(maxWidth: 640),
      sheetAnimationStyle: duration == Duration.zero
          ? AnimationStyle.noAnimation
          : AnimationStyle(
              duration: duration,
              reverseDuration: motion.resolve(context, motion.state),
            ),
      builder: (sheetContext) => FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: builder(sheetContext),
      ),
    );
  }

  if (context.mounted && previousFocus?.canRequestFocus == true) {
    previousFocus!.requestFocus();
  }
  return result;
}

class MusicFlowBottomSheet extends StatelessWidget {
  const MusicFlowBottomSheet({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.showCloseButton = true,
    this.constrainToAvailableHeight = false,
    this.padding,
  });

  final String title;
  final String? subtitle;
  final bool showCloseButton;
  final bool constrainToAvailableHeight;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final sceneRadius = context.musicFlowRadii.scene;
    final topRadius = BorderRadius.only(
      topLeft: sceneRadius.topLeft,
      topRight: sceneRadius.topRight,
    );

    return Semantics(
      container: true,
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: MusicFlowSurface(
        level: MusicFlowSurfaceLevel.modal,
        borderRadius: topRadius,
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(height: spacing.xs),
              Center(
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.musicFlowColors.divider,
                      borderRadius: context.musicFlowRadii.pill,
                    ),
                    child: const SizedBox(width: 36, height: 4),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  spacing.md,
                  spacing.sm,
                  spacing.xs,
                  subtitle == null ? spacing.sm : spacing.xxs,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: context.musicFlowTypography.headline,
                        ),
                      ),
                    ),
                    if (showCloseButton) ...<Widget>[
                      SizedBox(width: spacing.sm),
                      MusicFlowIconButton(
                        icon: AppIcons.close,
                        label: '关闭',
                        onPressed: () => Navigator.maybePop(context),
                      ),
                    ],
                  ],
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    spacing.md,
                    0,
                    spacing.md,
                    spacing.md,
                  ),
                  child: Text(
                    subtitle!,
                    style: context.musicFlowTypography.body.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
                ),
              if (constrainToAvailableHeight)
                Flexible(child: _buildBody(spacing))
              else
                _buildBody(spacing),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(MusicFlowSpacing spacing) {
    return Padding(
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            spacing.md,
            subtitle == null ? spacing.xs : 0,
            spacing.md,
            spacing.md,
          ),
      child: child,
    );
  }
}

/// A domain action used inside sheets and menus. It keeps the familiar
/// icon-title-detail structure without falling back to Material [ListTile].
class MusicFlowActionRow extends StatelessWidget {
  const MusicFlowActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.trailing,
    this.selected = false,
    this.destructive = false,
    this.semanticLabel,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool selected;
  final bool destructive;
  final String? semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final enabled = onPressed != null;
    final accent = destructive ? colors.error : colors.accent;
    final foreground = enabled
        ? (destructive ? colors.error : colors.ink)
        : colors.onDisabled;
    final detailColor = enabled ? colors.muted : colors.onDisabled;
    final background = selected
        ? accent.withValues(alpha: 0.1)
        : enabled
        ? Colors.transparent
        : colors.raised.withValues(alpha: 0.55);
    final label =
        semanticLabel ??
        <String>[
          title,
          if (subtitle != null) subtitle!,
          if (selected) '已选择',
        ].join('，');

    return MusicFlowPressable(
      semanticLabel: label,
      selected: selected,
      onPressed: onPressed,
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.expandedSongRowHeight,
      ),
      borderRadius: context.musicFlowRadii.control,
      child: Ink(
        decoration: BoxDecoration(
          color: background,
          borderRadius: context.musicFlowRadii.control,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowSpacing.xs,
            vertical: context.musicFlowSpacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: Center(
                  child: Icon(
                    icon,
                    size: 22,
                    color: enabled ? accent : colors.onDisabled,
                  ),
                ),
              ),
              SizedBox(width: context.musicFlowSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: context.musicFlowTypography.title.copyWith(
                        color: foreground,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      SizedBox(height: context.musicFlowSpacing.xxs),
                      Text(
                        subtitle!,
                        style: context.musicFlowTypography.body.copyWith(
                          color: detailColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                SizedBox(width: context.musicFlowSpacing.sm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
