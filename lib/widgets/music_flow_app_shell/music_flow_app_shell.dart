import 'package:flutter/material.dart';

import '../../core/design/music_flow_design.dart';
import 'music_flow_network_status_bar.dart';
import 'music_flow_shell_navigation.dart';

class MusicFlowAppShell extends StatelessWidget {
  const MusicFlowAppShell({
    super.key,
    required this.scaffoldKey,
    required this.body,
    required this.drawer,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.miniPlayer,
    required this.showMiniPlayer,
    this.networkStatus = MusicFlowNetworkStatus.online,
    this.onOpenDrawer,
    this.showNavigationBar = true,
    this.libraryEntries = const <MusicFlowSidebarLibraryEntry>[],
  });

  final GlobalKey<ScaffoldState> scaffoldKey;
  final Widget body;
  final Widget drawer;
  final List<MusicFlowShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget miniPlayer;
  final bool showMiniPlayer;
  final MusicFlowNetworkStatus networkStatus;
  final VoidCallback? onOpenDrawer;
  final bool showNavigationBar;
  final List<MusicFlowSidebarLibraryEntry> libraryEntries;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final windowClass = context.musicFlowBreakpoints.classify(width);
    final colors = context.musicFlowColors;
    final networkStatusBar = MusicFlowNetworkStatusBar(
      status: networkStatus,
      includeBottomSafeArea:
          windowClass != MusicFlowWindowClass.compact && !showMiniPlayer,
    );

    return Scaffold(
      key: scaffoldKey,
      backgroundColor: colors.canvas,
      extendBody: windowClass == MusicFlowWindowClass.compact,
      drawer: drawer,
      drawerScrimColor: colors.scrim,
      body: switch (windowClass) {
        MusicFlowWindowClass.compact => _CompactShellBody(
          color: colors.canvas,
          body: body,
        ),
        MusicFlowWindowClass.medium || MusicFlowWindowClass.expanded => _WideShellBody(
          windowClass: windowClass,
          destinations: destinations,
          selectedBranchIndex: selectedBranchIndex,
          onDestinationSelected: onDestinationSelected,
          onOpenDrawer:
              onOpenDrawer ?? () => scaffoldKey.currentState?.openDrawer(),
          body: body,
          miniPlayer: miniPlayer,
          showMiniPlayer: showMiniPlayer,
          networkStatusBar: networkStatusBar,
          libraryEntries: libraryEntries,
        ),
      },
      bottomNavigationBar: windowClass == MusicFlowWindowClass.compact
          ? Column(
              key: const ValueKey<String>('musicflow-compact-bottom-chrome'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                networkStatusBar,
                MusicFlowMiniPlayerSlot(
                  visible: showMiniPlayer,
                  includeBottomSafeArea: false,
                  child: miniPlayer,
                ),
                if (showNavigationBar)
                  MusicFlowCompactNavigation(
                    destinations: destinations,
                    selectedBranchIndex: selectedBranchIndex,
                    onDestinationSelected: onDestinationSelected,
                  ),
              ],
            )
          : null,
    );
  }
}

class _CompactShellBody extends StatelessWidget {
  const _CompactShellBody({required this.color, required this.body});

  final Color color;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return MusicFlowShellObstructionScope(
      bottom: mediaQuery.padding.bottom,
      child: MediaQuery(
        data: mediaQuery.removePadding(removeBottom: true),
        child: ColoredBox(
          key: const ValueKey<String>('musicflow-shell-content'),
          color: color,
          child: body,
        ),
      ),
    );
  }
}

class MusicFlowMiniPlayerSlot extends StatelessWidget {
  const MusicFlowMiniPlayerSlot({
    super.key,
    required this.visible,
    required this.child,
    this.includeBottomSafeArea = true,
  });

  final bool visible;
  final Widget child;
  final bool includeBottomSafeArea;

  @override
  Widget build(BuildContext context) {
    final motion = context.musicFlowMotion;
    final spacing = context.musicFlowSpacing;

    return SizedBox(
      key: const ValueKey<String>('musicflow-mini-player-slot'),
      width: double.infinity,
      child: ClipRect(
        child: AnimatedSize(
          alignment: Alignment.topCenter,
          duration: motion.resolve(context, motion.state),
          curve: motion.easeOut,
          child: visible
              ? Listener(
                  key: const ValueKey<String>(
                    'musicflow-mini-player-pointer-shield',
                  ),
                  behavior: HitTestBehavior.opaque,
                  child: SafeArea(
                    top: false,
                    bottom: includeBottomSafeArea,
                    child: Padding(
                      key: const ValueKey<String>('musicflow-mini-player-chrome'),
                      padding: EdgeInsets.fromLTRB(
                        spacing.sm,
                        spacing.xs,
                        spacing.sm,
                        spacing.xxs,
                      ),
                      child: child,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _WideShellBody extends StatelessWidget {
  const _WideShellBody({
    required this.windowClass,
    required this.destinations,
    required this.selectedBranchIndex,
    required this.onDestinationSelected,
    required this.onOpenDrawer,
    required this.body,
    required this.miniPlayer,
    required this.showMiniPlayer,
    required this.networkStatusBar,
    required this.libraryEntries,
  });

  final MusicFlowWindowClass windowClass;
  final List<MusicFlowShellDestination> destinations;
  final int selectedBranchIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onOpenDrawer;
  final Widget body;
  final Widget miniPlayer;
  final bool showMiniPlayer;
  final Widget networkStatusBar;
  final List<MusicFlowSidebarLibraryEntry> libraryEntries;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        if (windowClass == MusicFlowWindowClass.medium)
          MusicFlowMediumNavigationRail(
            destinations: destinations,
            selectedBranchIndex: selectedBranchIndex,
            onDestinationSelected: onDestinationSelected,
            onOpenDrawer: onOpenDrawer,
          )
        else
          MusicFlowExpandedNavigationSidebar(
            destinations: destinations,
            selectedBranchIndex: selectedBranchIndex,
            onDestinationSelected: onDestinationSelected,
            onOpenDrawer: onOpenDrawer,
            libraryEntries: libraryEntries,
          ),
        Expanded(
          child: Column(
            children: <Widget>[
              Expanded(
                child: ColoredBox(
                  key: const ValueKey<String>('musicflow-shell-content'),
                  color: context.musicFlowColors.canvas,
                  child: MusicFlowShellObstructionScope(bottom: 0, child: body),
                ),
              ),
              networkStatusBar,
              MusicFlowMiniPlayerSlot(visible: showMiniPlayer, child: miniPlayer),
            ],
          ),
        ),
      ],
    );
  }
}
