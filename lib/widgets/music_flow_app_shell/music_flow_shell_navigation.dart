import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design/music_flow_design.dart';
import '../../features/download/pages/download_manager_page.dart';
import '../../features/settings/pages/app_settings_page.dart';
import '../app_drawer.dart' show showRouteSelectionSheet;

@immutable
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

class MusicFlowCompactNavigation extends StatelessWidget {
  const MusicFlowCompactNavigation({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
  });

  final List<MusicFlowShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: ColoredBox(
        key: const ValueKey<String>('musicflow-compact-navigation'),
        color: colors.surface,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing.xxs),
              child: Row(
                children: <Widget>[
                  for (final destination in destinations)
                    Expanded(
                      child: _CompactDestination(
                        destination: destination,
                        selected:
                            destination.branchIndex == selectedBranchIndex,
                        onPressed: () =>
                            onDestinationSelected(destination.branchIndex),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧栏底部「应用菜单」动作(切换线路 / 下载管理 / 设置)。
enum _SidebarAppAction { switchLine, downloads, settings }

/// 侧栏底部常驻的应用动作组:
/// - 展开态:图标 + 文字;
/// - 收起态:仅图标,悬浮显示 Tooltip。
class _SidebarAppActions extends StatelessWidget {
  const _SidebarAppActions({required this.collapsed});

  final bool collapsed;

  void _dispatch(BuildContext context, _SidebarAppAction action) {
    switch (action) {
      case _SidebarAppAction.switchLine:
        unawaited(showRouteSelectionSheet(context));
      case _SidebarAppAction.downloads:
        unawaited(_push(context, const DownloadManagerPage()));
      case _SidebarAppAction.settings:
        unawaited(_push(context, const AppSettingsPage()));
    }
  }

  Future<void> _push(BuildContext context, Widget page) {
    return Navigator.of(
      context,
    ).push(MusicFlowPageRoute<void>(context: context, builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    const actions = <(IconData, String, _SidebarAppAction)>[
      (AppIcons.route, '切换线路', _SidebarAppAction.switchLine),
      (AppIcons.downloadOutline, '下载管理', _SidebarAppAction.downloads),
      (AppIcons.settings, '设置', _SidebarAppAction.settings),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final (icon, title, action) in actions)
          Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: collapsed
                ? _SidebarIconEntry(
                    label: title,
                    icon: icon,
                    onPressed: () => _dispatch(context, action),
                  )
                : _SidebarActionEntry(
                    label: title,
                    icon: icon,
                    onPressed: () => _dispatch(context, action),
                  ),
          ),
      ],
    );
  }
}

class MusicFlowMediumNavigationRail extends StatelessWidget {
  const MusicFlowMediumNavigationRail({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.onOpenDrawer,
  });

  final List<MusicFlowShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: ColoredBox(
        key: const ValueKey<String>('musicflow-medium-navigation'),
        color: context.musicFlowColors.surface,
        child: SafeArea(
          right: false,
          child: SizedBox(
            width: 96,
            child: Column(
              children: <Widget>[
                SizedBox(height: spacing.sm),
                MusicFlowDivider(inset: spacing.sm, endInset: spacing.sm),
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.symmetric(vertical: spacing.sm),
                    itemCount: destinations.length,
                    itemBuilder: (context, index) {
                      final destination = destinations[index];
                      return Padding(
                        padding: EdgeInsets.only(bottom: spacing.xxs),
                        child: _RailDestination(
                          destination: destination,
                          selected:
                              destination.branchIndex == selectedBranchIndex,
                          onPressed: () =>
                              onDestinationSelected(destination.branchIndex),
                        ),
                      );
                    },
                  ),
                ),
                MusicFlowDivider(inset: spacing.sm, endInset: spacing.sm),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: spacing.sm),
                  child: const _SidebarAppActions(collapsed: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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

class MusicFlowExpandedNavigationSidebar extends StatefulWidget {
  const MusicFlowExpandedNavigationSidebar({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.onOpenDrawer,
    this.libraryEntries = const <MusicFlowSidebarLibraryEntry>[],
  });

  final List<MusicFlowShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onOpenDrawer;
  final List<MusicFlowSidebarLibraryEntry> libraryEntries;

  @override
  State<MusicFlowExpandedNavigationSidebar> createState() =>
      _MusicFlowExpandedNavigationSidebarState();
}

/// 宽屏侧边栏：点击「收起」可折叠为图标窄栏（再点击「展开」恢复），
/// 对齐箭头音乐 Windows 版可收起的左侧栏。
class _MusicFlowExpandedNavigationSidebarState
    extends State<MusicFlowExpandedNavigationSidebar> {
  /// 是否折叠为图标窄栏。收起状态只保留图标与 Tooltip，节省横向空间。
  bool _collapsed = false;

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final motion = context.musicFlowMotion;
    final duration = motion.resolve(context, motion.state);
    final collapsed = _collapsed;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: collapsed ? '主导航（已收起）' : '主导航',
      child: ColoredBox(
        key: const ValueKey<String>('musicflow-expanded-navigation'),
        color: context.musicFlowColors.surface,
        child: SafeArea(
          right: false,
          child: AnimatedContainer(
            duration: duration,
            curve: motion.easeOut,
            width: collapsed ? 76 : 232,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 头部:菜单按钮即侧边栏「收起/展开」开关;不再使用左右箭头按钮。
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: collapsed ? spacing.xxs : spacing.xs,
                    vertical: spacing.xs,
                  ),
                  child: collapsed
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            MusicFlowIconButton(
                              icon: AppIcons.menu,
                              label: '展开侧边栏',
                              onPressed: _toggleCollapsed,
                            ),
                          ],
                        )
                      : Row(
                          children: <Widget>[
                            MusicFlowIconButton(
                              icon: AppIcons.menu,
                              label: '收起侧边栏',
                              onPressed: _toggleCollapsed,
                            ),
                            SizedBox(width: spacing.sm),
                            Expanded(
                              child: Semantics(
                                header: true,
                                child: Text(
                                  'MusicFlow',
                                  style: context.musicFlowTypography.title,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                MusicFlowDivider(
                  inset: collapsed ? spacing.sm : spacing.md,
                  endInset: collapsed ? spacing.sm : spacing.md,
                ),
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.symmetric(
                      horizontal: collapsed ? spacing.xxs : spacing.sm,
                      vertical: spacing.md,
                    ),
                    itemCount:
                        widget.destinations.length + widget.libraryEntries.length,
                    itemBuilder: (context, index) {
                      final isLibrary = index >= widget.destinations.length;
                      if (collapsed) {
                        // 折叠态：全部显示为带 Tooltip 的图标窄条。
                        if (isLibrary) {
                          final entry =
                              widget.libraryEntries[index - widget.destinations.length];
                          return Padding(
                            padding: EdgeInsets.only(bottom: spacing.xxs),
                            child: _SidebarIconEntry(
                              label: entry.label,
                              icon: entry.icon,
                              onPressed: entry.onTap,
                            ),
                          );
                        }
                        final destination = widget.destinations[index];
                        return Padding(
                          padding: EdgeInsets.only(bottom: spacing.xxs),
                          child: _SidebarIconDestination(
                            destination: destination,
                            selected: destination.branchIndex ==
                                widget.selectedBranchIndex,
                            onPressed: () => widget.onDestinationSelected(
                              destination.branchIndex,
                            ),
                          ),
                        );
                      }
                      if (isLibrary) {
                        final entry =
                            widget.libraryEntries[index - widget.destinations.length];
                        return Padding(
                          padding: EdgeInsets.only(bottom: spacing.xxs),
                          child: _SidebarActionEntry(
                            label: entry.label,
                            icon: entry.icon,
                            onPressed: entry.onTap,
                          ),
                        );
                      }
                      final destination = widget.destinations[index];
                      return Padding(
                        padding: EdgeInsets.only(bottom: spacing.xxs),
                        child: _SidebarDestination(
                          destination: destination,
                          selected: destination.branchIndex ==
                              widget.selectedBranchIndex,
                          onPressed: () => widget.onDestinationSelected(
                            destination.branchIndex,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                MusicFlowDivider(
                  inset: collapsed ? spacing.sm : spacing.md,
                  endInset: collapsed ? spacing.sm : spacing.md,
                ),
                Padding(
                  padding: EdgeInsets.only(
                    left: collapsed ? spacing.xxs : spacing.sm,
                    right: collapsed ? spacing.xxs : spacing.sm,
                    bottom: spacing.md,
                  ),
                  child: _SidebarAppActions(collapsed: collapsed),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactDestination extends StatelessWidget {
  const _CompactDestination({
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
            child: _SelectionMarker(
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
                  _AnimatedDestinationIcon(
                    icon: selected
                        ? destination.selectedIcon
                        : destination.icon,
                    color: foreground,
                    size: context.musicFlowInteraction.smallIconSize,
                  ),
                  SizedBox(height: spacing.xxs),
                  _AnimatedDestinationLabel(
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

class _RailDestination extends StatelessWidget {
  const _RailDestination({
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
            _SelectionMarker(
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
                  _AnimatedDestinationIcon(
                    icon: selected
                        ? destination.selectedIcon
                        : destination.icon,
                    color: foreground,
                    size: context.musicFlowInteraction.iconSize,
                  ),
                  SizedBox(height: spacing.xxs),
                  _AnimatedDestinationLabel(
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

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
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
            _SelectionMarker(
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
                child: _AnimatedDestinationIcon(
                  icon: selected ? destination.selectedIcon : destination.icon,
                  color: foreground,
                  size: context.musicFlowInteraction.iconSize,
                ),
              ),
            ),
            SizedBox(width: spacing.xxs),
            Expanded(
              child: _AnimatedDestinationLabel(
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

class _SelectionMarker extends StatelessWidget {
  const _SelectionMarker({
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

class _AnimatedDestinationIcon extends StatelessWidget {
  const _AnimatedDestinationIcon({
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

class _AnimatedDestinationLabel extends StatelessWidget {
  const _AnimatedDestinationLabel({
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
class _SidebarActionEntry extends StatelessWidget {
  const _SidebarActionEntry({
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
class _SidebarIconDestination extends StatelessWidget {
  const _SidebarIconDestination({
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
              _SelectionMarker(
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
                  child: _AnimatedDestinationIcon(
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
class _SidebarIconEntry extends StatelessWidget {
  const _SidebarIconEntry({
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
