import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/design/echo_design.dart';
import '../../features/download/pages/download_manager_page.dart';
import '../../features/settings/pages/app_settings_page.dart';
import '../app_drawer.dart' show showRouteSelectionSheet;

@immutable
class EchoShellDestination {
  const EchoShellDestination({
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

class EchoCompactNavigation extends StatelessWidget {
  const EchoCompactNavigation({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
  });

  final List<EchoShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.echoColors;
    final spacing = context.echoSpacing;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: ColoredBox(
        key: const ValueKey<String>('echo-compact-navigation'),
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

/// 主界面侧栏顶部的「应用菜单」按钮。
///
/// 桌面端(medium/expanded)不再打开铺满整窗的抽屉遮罩,而是弹出一个
/// 收在按钮下方的 Windows 风格下拉菜单(切换线路 / 下载管理 / 设置)。
enum _EchoAppMenuAction { switchLine, downloads, settings }

class EchoAppMenuButton extends StatefulWidget {
  const EchoAppMenuButton({super.key});

  @override
  State<EchoAppMenuButton> createState() => _EchoAppMenuButtonState();
}

class _EchoAppMenuButtonState extends State<EchoAppMenuButton> {
  final GlobalKey _buttonKey = GlobalKey();

  Future<void> _showMenu() async {
    final renderObject = _buttonKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (renderObject is! RenderBox || overlay is! RenderBox) return;

    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        renderObject.localToGlobal(Offset.zero, ancestor: overlay),
        renderObject.localToGlobal(
          renderObject.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final action = await showMenu<_EchoAppMenuAction>(
      context: context,
      position: position,
      color: context.echoColors.surface,
      elevation: 8.0,
      constraints: const BoxConstraints(minWidth: 216, maxWidth: 280),
      shape: RoundedRectangleBorder(
        borderRadius: context.echoRadii.control,
        side: BorderSide(color: context.echoColors.controlBoundary),
      ),
      items: <PopupMenuEntry<_EchoAppMenuAction>>[
        _menuItem(
          context,
          value: _EchoAppMenuAction.switchLine,
          icon: AppIcons.route,
          title: '切换线路',
        ),
        _menuItem(
          context,
          value: _EchoAppMenuAction.downloads,
          icon: AppIcons.downloadOutline,
          title: '下载管理',
        ),
        _menuItem(
          context,
          value: _EchoAppMenuAction.settings,
          icon: AppIcons.settings,
          title: '设置',
        ),
      ],
    );

    if (action != null && mounted) _dispatch(action);
  }

  PopupMenuEntry<_EchoAppMenuAction> _menuItem(
    BuildContext context, {
    required _EchoAppMenuAction value,
    required IconData icon,
    required String title,
  }) {
    return PopupMenuItem<_EchoAppMenuAction>(
      value: value,
      height: 44,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: context.echoColors.ink),
          SizedBox(width: context.echoSpacing.sm),
          Expanded(
            child: Text(title, style: context.echoTypography.body),
          ),
        ],
      ),
    );
  }

  void _dispatch(_EchoAppMenuAction action) {
    switch (action) {
      case _EchoAppMenuAction.switchLine:
        unawaited(showRouteSelectionSheet(context));
      case _EchoAppMenuAction.downloads:
        unawaited(_push(const DownloadManagerPage()));
      case _EchoAppMenuAction.settings:
        unawaited(_push(const AppSettingsPage()));
    }
  }

  Future<void> _push(Widget page) {
    return Navigator.of(
      context,
    ).push(EchoPageRoute<void>(context: context, builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return EchoIconButton(
      key: _buttonKey,
      icon: AppIcons.menu,
      label: '打开应用菜单',
      onPressed: _showMenu,
    );
  }
}

class EchoMediumNavigationRail extends StatelessWidget {
  const EchoMediumNavigationRail({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.onOpenDrawer,
  });

  final List<EchoShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    final spacing = context.echoSpacing;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: ColoredBox(
        key: const ValueKey<String>('echo-medium-navigation'),
        color: context.echoColors.surface,
        child: SafeArea(
          right: false,
          child: SizedBox(
            width: 96,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.all(spacing.xs),
                  child: const EchoAppMenuButton(),
                ),
                EchoDivider(inset: spacing.sm, endInset: spacing.sm),
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
class EchoSidebarLibraryEntry {
  const EchoSidebarLibraryEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

class EchoExpandedNavigationSidebar extends StatefulWidget {
  const EchoExpandedNavigationSidebar({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.onOpenDrawer,
    this.libraryEntries = const <EchoSidebarLibraryEntry>[],
  });

  final List<EchoShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onOpenDrawer;
  final List<EchoSidebarLibraryEntry> libraryEntries;

  @override
  State<EchoExpandedNavigationSidebar> createState() =>
      _EchoExpandedNavigationSidebarState();
}

/// 宽屏侧边栏：点击「收起」可折叠为图标窄栏（再点击「展开」恢复），
/// 对齐箭头音乐 Windows 版可收起的左侧栏。
class _EchoExpandedNavigationSidebarState
    extends State<EchoExpandedNavigationSidebar> {
  /// 是否折叠为图标窄栏。收起状态只保留图标与 Tooltip，节省横向空间。
  bool _collapsed = false;

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final spacing = context.echoSpacing;
    final motion = context.echoMotion;
    final duration = motion.resolve(context, motion.state);
    final collapsed = _collapsed;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: collapsed ? '主导航（已收起）' : '主导航',
      child: ColoredBox(
        key: const ValueKey<String>('echo-expanded-navigation'),
        color: context.echoColors.surface,
        child: SafeArea(
          right: false,
          child: AnimatedContainer(
            duration: duration,
            curve: motion.easeOut,
            width: collapsed ? 76 : 232,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 头部：展开态显示品牌名 + 收起按钮；折叠态只留菜单与展开按钮。
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: spacing.xs,
                    vertical: spacing.xs,
                  ),
                  child: collapsed
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const EchoAppMenuButton(),
                            SizedBox(height: spacing.xs),
                            EchoIconButton(
                              icon: AppIcons.chevronRight,
                              label: '展开侧边栏',
                              onPressed: _toggleCollapsed,
                            ),
                          ],
                        )
                      : Row(
                          children: <Widget>[
                            const EchoAppMenuButton(),
                            SizedBox(width: spacing.sm),
                            Expanded(
                              child: Semantics(
                                header: true,
                                child: Text(
                                  'MusicFlow',
                                  style: context.echoTypography.title,
                                ),
                              ),
                            ),
                            EchoIconButton(
                              icon: AppIcons.chevronLeft,
                              label: '收起侧边栏',
                              onPressed: _toggleCollapsed,
                            ),
                          ],
                        ),
                ),
                EchoDivider(
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

  final EchoShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.echoColors;
    final spacing = context.echoSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return EchoPressable(
      semanticLabel: destination.label,
      selected: selected,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 64),
      borderRadius: context.echoRadii.detail,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: _SelectionMarker(
              markerKey: ValueKey<String>(
                'echo-compact-selection-indicator-'
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
                    size: context.echoInteraction.smallIconSize,
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

  final EchoShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.echoColors;
    final spacing = context.echoSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return EchoPressable(
      semanticLabel: destination.label,
      selected: selected,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 80),
      borderRadius: context.echoRadii.detail,
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
                'echo-medium-selection-indicator-'
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
                    size: context.echoInteraction.iconSize,
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

  final EchoShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.echoColors;
    final spacing = context.echoSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return EchoPressable(
      semanticLabel: destination.label,
      selected: selected,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 64),
      borderRadius: context.echoRadii.detail,
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
                'echo-expanded-selection-indicator-'
                '${destination.branchIndex}',
              ),
              selected: selected,
              axis: Axis.vertical,
            ),
            SizedBox(width: spacing.xs),
            SizedBox.square(
              dimension: context.echoInteraction.minimumTouchTarget,
              child: Center(
                child: _AnimatedDestinationIcon(
                  icon: selected ? destination.selectedIcon : destination.icon,
                  color: foreground,
                  size: context.echoInteraction.iconSize,
                ),
              ),
            ),
            SizedBox(width: spacing.xxs),
            Expanded(
              child: _AnimatedDestinationLabel(
                label: destination.label,
                color: foreground,
                selected: selected,
                style: context.echoTypography.title,
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
    final motion = context.echoMotion;
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
              color: context.echoColors.accent,
              borderRadius: context.echoRadii.detail,
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
    final motion = context.echoMotion;
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
    final motion = context.echoMotion;
    return AnimatedDefaultTextStyle(
      duration: motion.resolve(context, motion.state),
      curve: motion.easeOut,
      style: (style ?? context.echoTypography.label).copyWith(
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
    final colors = context.echoColors;
    final spacing = context.echoSpacing;

    return EchoPressable(
      semanticLabel: label,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: const Size(double.infinity, 64),
      borderRadius: context.echoRadii.detail,
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
              dimension: context.echoInteraction.minimumTouchTarget,
              child: Center(
                child: Icon(
                  icon,
                  size: context.echoInteraction.iconSize,
                  color: colors.muted,
                ),
              ),
            ),
            SizedBox(width: spacing.xxs),
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: context.echoMotion.resolve(
                  context,
                  context.echoMotion.state,
                ),
                style: context.echoTypography.title.copyWith(
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

  final EchoShellDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.echoColors;
    final spacing = context.echoSpacing;
    final foreground = selected ? colors.accent : colors.muted;

    return Tooltip(
      message: destination.label,
      child: EchoPressable(
        semanticLabel: destination.label,
        selected: selected,
        onPressed: onPressed,
        enableHaptics: true,
        minimumSize: const Size(double.infinity, 56),
        borderRadius: context.echoRadii.detail,
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
                  'echo-expanded-collapsed-selection-indicator-'
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
                    size: context.echoInteraction.iconSize,
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
    final colors = context.echoColors;
    final spacing = context.echoSpacing;

    return Tooltip(
      message: label,
      child: EchoPressable(
        semanticLabel: label,
        onPressed: onPressed,
        enableHaptics: true,
        minimumSize: const Size(double.infinity, 56),
        borderRadius: context.echoRadii.detail,
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
                    size: context.echoInteraction.iconSize,
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
