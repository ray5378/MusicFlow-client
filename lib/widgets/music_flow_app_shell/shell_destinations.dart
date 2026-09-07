import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';

class MusicFlowShellDestination {
  const MusicFlowShellDestination({
    required this.branchIndex,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final int branchIndex;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 侧栏「曲库」快捷入口(非分支,点击直接打开对应列表页),
/// 对齐箭头音乐 Windows 版左侧栏。
class MusicFlowSidebarLibraryEntry {
  const MusicFlowSidebarLibraryEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

class ShellCompactDestination extends StatelessWidget {
  const ShellCompactDestination({
    required this.destination,
    required this.selected,
    required this.onPressed,
  });

  final MusicFlowShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return MusicFlowPressable(
      semanticLabel: destination.label,
      selected: selected,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 64),
      borderRadius: context.musicFlowRadii.detail,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: ShellSelectionMarker(
              markerKey: ValueKey<String>(
                'musicflow-compact-selection-indicator-'
                '${destination.branchIndex}',
              ),
              selected: selected,
              axis: Axis.horizontal,
            ),
          ),
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing.xxs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  ShellAnimatedDestinationIcon(
                    icon: selected
                        ? destination.selectedIcon
                        : destination.icon,
                    color: foreground,
                    size: context.musicFlowInteraction.smallIconSize,
                  ),
                  SizedBox(height: spacing.xxs),
                  ShellAnimatedDestinationLabel(
                    label: destination.label,
                    color: foreground,
                    selected: selected,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ShellRailDestination extends StatelessWidget {
  const ShellRailDestination({
    required this.destination,
    required this.selected,
    required this.onPressed,
  });

  final MusicFlowShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return MusicFlowPressable(
      semanticLabel: destination.label,
      selected: selected,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 80),
      borderRadius: context.musicFlowRadii.detail,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.xxs,
          spacing.xs,
          spacing.xxs,
          spacing.xs,
        ),
        child: Row(
          children: <Widget>[
            ShellSelectionMarker(
              markerKey: ValueKey<String>(
                'musicflow-medium-selection-indicator-'
                '${destination.branchIndex}',
              ),
              selected: selected,
              axis: Axis.vertical,
            ),
            SizedBox(width: spacing.xxs),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  ShellAnimatedDestinationIcon(
                    icon: selected
                        ? destination.selectedIcon
                        : destination.icon,
                    color: foreground,
                    size: context.musicFlowInteraction.iconSize,
                  ),
                  SizedBox(height: spacing.xxs),
                  ShellAnimatedDestinationLabel(
                    label: destination.label,
                    color: foreground,
                    selected: selected,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ShellSidebarDestination extends StatelessWidget {
  const ShellSidebarDestination({
    required this.destination,
    required this.selected,
    required this.onPressed,
  });

  final MusicFlowShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return MusicFlowPressable(
      semanticLabel: destination.label,
      selected: selected,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 64),
      borderRadius: context.musicFlowRadii.detail,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.xxs,
          spacing.xs,
          spacing.xs,
          spacing.xs,
        ),
        child: Row(
          children: <Widget>[
            ShellSelectionMarker(
              markerKey: ValueKey<String>(
                'musicflow-expanded-selection-indicator-'
                '${destination.branchIndex}',
              ),
              selected: selected,
              axis: Axis.vertical,
            ),
            SizedBox(width: spacing.xs),
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: Center(
                child: ShellAnimatedDestinationIcon(
                  icon: selected ? destination.selectedIcon : destination.icon,
                  color: foreground,
                  size: context.musicFlowInteraction.iconSize,
                ),
              ),
            ),
            SizedBox(width: spacing.xxs),
            Expanded(
              child: ShellAnimatedDestinationLabel(
                label: destination.label,
                color: foreground,
                selected: selected,
                style: context.musicFlowTypography.title,
                maxLines: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ShellSelectionMarker extends StatelessWidget {
  const ShellSelectionMarker({
    required this.markerKey,
    required this.selected,
    required this.axis,
  });

  final Key markerKey;
  final bool selected;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final motion = context.musicFlowMotion;
    final duration = motion.resolve(context, motion.state);
    final horizontal = axis == Axis.horizontal;

    return SizedBox(
      width: horizontal ? 24 : 3,
      height: horizontal ? 3 : 28,
      child: AnimatedOpacity(
        key: markerKey,
        duration: duration,
        curve: motion.easeOut,
        opacity: selected ? 1 : 0,
        child: AnimatedScale(
          duration: duration,
          curve: motion.easeOut,
          scale: selected ? 1 : 0.68,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.musicFlowColors.accent,
              borderRadius: context.musicFlowRadii.detail,
            ),
          ),
        ),
      ),
    );
  }
}

class ShellAnimatedDestinationIcon extends StatelessWidget {
  const ShellAnimatedDestinationIcon({
    required this.icon,
    required this.color,
    required this.size,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final motion = context.musicFlowMotion;
    return AnimatedSwitcher(
      duration: motion.resolve(context, motion.state),
      switchInCurve: motion.easeOut,
      switchOutCurve: motion.easeOut,
      child: Icon(
        icon,
        key: ValueKey<String>(
          '${icon.codePoint}-${icon.fontFamily}-${icon.fontPackage}',
        ),
        size: size,
        color: color,
      ),
    );
  }
}

class ShellAnimatedDestinationLabel extends StatelessWidget {
  const ShellAnimatedDestinationLabel({
    required this.label,
    required this.color,
    required this.selected,
    this.style,
    this.textAlign = TextAlign.start,
    this.maxLines = 1,
  });

  final String label;
  final Color color;
  final bool selected;
  final TextStyle? style;
  final TextAlign textAlign;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final motion = context.musicFlowMotion;
    return AnimatedDefaultTextStyle(
      duration: motion.resolve(context, motion.state),
      curve: motion.easeOut,
      style: (style ?? context.musicFlowTypography.label).copyWith(
        color: color,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      child: Text(
        label,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
      ),
    );
  }
}

/// 侧栏动作型条目(曲库快捷入口),样式与分支目的地一致。
class ShellSidebarActionEntry extends StatelessWidget {
  const ShellSidebarActionEntry({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;

    return MusicFlowPressable(
      semanticLabel: label,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 64),
      borderRadius: context.musicFlowRadii.detail,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.xxs,
          spacing.xs,
          spacing.xs,
          spacing.xs,
        ),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: Center(
                child: Icon(
                  icon,
                  size: context.musicFlowInteraction.iconSize,
                  color: colors.muted,
                ),
              ),
            ),
            SizedBox(width: spacing.xxs),
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: context.musicFlowMotion.resolve(
                  context,
                  context.musicFlowMotion.state,
                ),
                style: context.musicFlowTypography.title.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w500,
                ),
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 折叠态侧边栏条目：仅图标 + Tooltip（悬停显示文字）。
class ShellSidebarIconDestination extends StatelessWidget {
  const ShellSidebarIconDestination({
    required this.destination,
    required this.selected,
    required this.onPressed,
  });

  final MusicFlowShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return Tooltip(
      message: destination.label,
      child: MusicFlowPressable(
        semanticLabel: destination.label,
        selected: selected,
        onPressed: onPressed,
        enableHaptics: true,
        minimumSize: const Size(double.infinity, 56),
        borderRadius: context.musicFlowRadii.detail,
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.xxs,
            spacing.xs,
            spacing.xxs,
            spacing.xs,
          ),
          child: Row(
            children: <Widget>[
              ShellSelectionMarker(
                markerKey: ValueKey<String>(
                  'musicflow-expanded-collapsed-selection-indicator-'
                  '${destination.branchIndex}',
                ),
                selected: selected,
                axis: Axis.vertical,
              ),
              SizedBox(width: spacing.xxs),
              Expanded(
                child: Center(
                  child: ShellAnimatedDestinationIcon(
                    icon: selected
                        ? destination.selectedIcon
                        : destination.icon,
                    color: foreground,
                    size: context.musicFlowInteraction.iconSize,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 折叠态侧边栏曲库快捷入口：仅图标 + Tooltip。
class ShellSidebarIconEntry extends StatelessWidget {
  const ShellSidebarIconEntry({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;

    return Tooltip(
      message: label,
      child: MusicFlowPressable(
        semanticLabel: label,
        onPressed: onPressed,
        enableHaptics: true,
        minimumSize: const Size(double.infinity, 56),
        borderRadius: context.musicFlowRadii.detail,
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.xxs,
            spacing.xs,
            spacing.xxs,
            spacing.xs,
          ),
          child: Row(
            children: <Widget>[
              const SizedBox(width: 3),
              SizedBox(width: spacing.xxs),
              Expanded(
                child: Center(
                  child: Icon(
                    icon,
                    size: context.musicFlowInteraction.iconSize,
                    color: colors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
