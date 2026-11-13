import 'dart:async';
import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/shell_destinations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/compact_navigation.dart';

class MusicFlowExpandedNavigationSidebar extends StatefulWidget {
  const MusicFlowExpandedNavigationSidebar({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.onOpenDrawer,
    this.libraryEntries = const <MusicFlowSidebarLibraryEntry>[],
    this.onLibraryEntriesReordered,
    this.onOpenPage,
  });

  final List<MusicFlowShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onOpenDrawer;
  final List<MusicFlowSidebarLibraryEntry> libraryEntries;

  /// 曲库入口拖拽排序回调（长按拖动，顺序由调用方持久化）。
  final ReorderCallback? onLibraryEntriesReordered;
  final Future<void> Function(Widget page)? onOpenPage;

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
    final loc = AppLocalizations.of(context);
    final collapsed = _collapsed;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: collapsed ? loc.widgets_nav_main_collapsed : loc.widgets_nav_main,
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
                              label: loc.widgets_nav_expand_sidebar,
                              onPressed: _toggleCollapsed,
                            ),
                          ],
                        )
                      : Row(
                          children: <Widget>[
                            MusicFlowIconButton(
                              icon: AppIcons.menu,
                              label: loc.widgets_nav_collapse_sidebar,
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
                  child: collapsed
                      ? _buildCollapsedList(spacing)
                      : _buildExpandedList(spacing),
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
                  child: ShellSidebarAppActions(
                    collapsed: collapsed,
                    onOpenPage: widget.onOpenPage,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 折叠态：全部显示为带 Tooltip 的图标窄条（不参与拖拽排序）。
  Widget _buildCollapsedList(MusicFlowSpacing spacing) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.xxs,
        vertical: spacing.md,
      ),
      itemCount: widget.destinations.length + widget.libraryEntries.length,
      itemBuilder: (context, index) {
        final isLibrary = index >= widget.destinations.length;
        if (isLibrary) {
          final entry =
              widget.libraryEntries[index - widget.destinations.length];
          return Padding(
            padding: EdgeInsets.only(bottom: spacing.xxs),
            child: ShellSidebarIconEntry(
              label: entry.label,
              icon: entry.icon,
              onPressed: entry.onTap,
            ),
          );
        }
        final destination = widget.destinations[index];
        return Padding(
          padding: EdgeInsets.only(bottom: spacing.xxs),
          child: ShellSidebarIconDestination(
            destination: destination,
            selected: destination.branchIndex == widget.selectedBranchIndex,
            onPressed: () =>
                widget.onDestinationSelected(destination.branchIndex),
          ),
        );
      },
    );
  }

  /// 展开态：分支目的地固定在上方，曲库入口可长按拖拽排序。
  Widget _buildExpandedList(MusicFlowSpacing spacing) {
    final rows = <Widget>[
      for (final destination in widget.destinations)
        Padding(
          padding: EdgeInsets.only(bottom: spacing.xxs),
          child: ShellSidebarDestination(
            destination: destination,
            selected: destination.branchIndex == widget.selectedBranchIndex,
            onPressed: () =>
                widget.onDestinationSelected(destination.branchIndex),
          ),
        ),
    ];

    final entries = widget.libraryEntries;
    final onReorder = widget.onLibraryEntriesReordered;
    if (onReorder == null) {
      rows.addAll(<Widget>[
        for (final entry in entries)
          Padding(
            padding: EdgeInsets.only(bottom: spacing.xxs),
            child: ShellSidebarActionEntry(
              label: entry.label,
              icon: entry.icon,
              onPressed: entry.onTap,
            ),
          ),
      ]);
    } else {
      rows.add(
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: entries.length,
          onReorder: onReorder,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return ReorderableDelayedDragStartListener(
              key: ValueKey<String>(
                'musicflow-sidebar-entry-'
                '${entry.id.isNotEmpty ? entry.id : entry.label}',
              ),
              index: index,
              child: Padding(
                padding: EdgeInsets.only(bottom: spacing.xxs),
                child: ShellSidebarActionEntry(
                  label: entry.label,
                  icon: entry.icon,
                  onPressed: entry.onTap,
                ),
              ),
            );
          },
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.sm,
        vertical: spacing.md,
      ),
      children: rows,
    );
  }
}

