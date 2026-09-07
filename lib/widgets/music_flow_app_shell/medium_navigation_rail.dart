import 'dart:async';
import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/shell_destinations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/compact_navigation.dart';

class MusicFlowMediumNavigationRail extends StatelessWidget {
  const MusicFlowMediumNavigationRail({
    super.key,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.onOpenDrawer,
    this.onOpenPage,
  });

  final List<MusicFlowShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onOpenDrawer;
  final Future<void> Function(Widget page)? onOpenPage;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: AppLocalizations.of(context).widgets_nav_main,
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
                        child: ShellRailDestination(
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
                  child: ShellSidebarAppActions(
                    collapsed: true,
                    onOpenPage: onOpenPage,
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

