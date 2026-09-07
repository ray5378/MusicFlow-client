import 'dart:async';
import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/shell_destinations.dart';

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
      label: AppLocalizations.of(context).widgets_nav_main,
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
                      child: ShellCompactDestination(
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

/// 侧栏底部「应用菜单」动作(设置)。
enum _SidebarAppAction { settings }

/// 侧栏底部常驻的应用动作组:
/// - 展开态:图标 + 文字;
/// - 收起态:仅图标,悬浮显示 Tooltip。
class ShellSidebarAppActions extends StatelessWidget {
  const ShellSidebarAppActions({required this.collapsed, this.onOpenPage});

  final bool collapsed;
  final Future<void> Function(Widget page)? onOpenPage;

  void _dispatch(BuildContext context, _SidebarAppAction action) {
    switch (action) {
      case _SidebarAppAction.settings:
        unawaited(_push(context, const AppSettingsPage()));
    }
  }

  Future<void> _push(BuildContext context, Widget page) {
    final opener = onOpenPage;
    if (opener != null) {
      return opener(page);
    }
    return Navigator.of(
      context,
    ).push(MusicFlowPageRoute<void>(context: context, builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final settingsTitle = AppLocalizations.of(context).widgets_settings;
    final actions = <(IconData, String, _SidebarAppAction)>[
      (AppIcons.settings, settingsTitle, _SidebarAppAction.settings),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final (icon, title, action) in actions)
          Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: collapsed
                ? ShellSidebarIconEntry(
                    label: title,
                    icon: icon,
                    onPressed: () => _dispatch(context, action),
                  )
                : ShellSidebarActionEntry(
                    label: title,
                    icon: icon,
                    onPressed: () => _dispatch(context, action),
                  ),
          ),
      ],
    );
  }
}

