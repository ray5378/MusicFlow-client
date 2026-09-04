import 'dart:async';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/library_provider.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/music_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import 'music_flow_app_shell/music_flow_drawer.dart';

/// MusicFlow's application drawer. [Scaffold] still supplies platform drawer
/// routing, focus, and back behavior; every visible surface is owned here.
class AppDrawer extends ConsumerStatefulWidget {
  const AppDrawer({super.key, this.onReturnFocus, this.onOpenPage});

  final VoidCallback? onReturnFocus;

  /// 打开页面的回调：由 MainScaffold 提供，统一落到内容区分支导航器。
  final Future<void> Function(Widget page)? onOpenPage;

  @override
  ConsumerState<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends ConsumerState<AppDrawer> {
  bool _showLibraries = false;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final authState = ref.watch(authStateProvider);
    final activeLibrary = authState.currentLibrary;
    final activeAddress = ref.watch(activeAddressProvider);

    return MusicFlowDrawerFrame(
      header: MusicFlowDrawerIdentityHeader(
        username: activeLibrary?.username ?? 'Guest',
        libraryName: activeLibrary?.name ?? loc.widgets_drawer_library_unselected,
        addressLabel: activeAddress?.label ?? loc.widgets_drawer_no_active_route,
        connectionState: _connectionState(activeAddress),
        avatarUrl: resolveMusicFlowDrawerAvatarUrl(activeLibrary),
        showingLibraries: _showLibraries,
        onToggleLibraries: () {
          setState(() {
            _showLibraries = !_showLibraries;
          });
        },
      ),
      child: _showLibraries
          ? _buildLibraryList(activeLibrary)
          : _buildNavigationList(),
    );
  }

  Widget _buildLibraryList(MusicLibrary? activeLibrary) {
    final loc = AppLocalizations.of(context);
    final libraries = ref.watch(librariesProvider);

    return libraries.when(
      data: (items) {
        if (items.isEmpty) {
          return MusicFlowEmptyState(
            title: loc.widgets_drawer_library_empty_title,
            description: loc.widgets_drawer_library_empty_desc,
            icon: AppIcons.library,
            actionLabel: loc.widgets_drawer_add_library,
            onAction: () => _closeDrawerAndPushLocation('/login?add=true'),
          );
        }

        return ListView.builder(
          key: const PageStorageKey<String>('musicflow-drawer-libraries'),
          padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: items.length + 2,
          itemBuilder: (context, index) {
            if (index < items.length) {
              final library = items[index];
              final isActive = library.id == activeLibrary?.id;
              return Padding(
                padding: EdgeInsets.only(bottom: context.musicFlowSpacing.xs),
                child: MusicFlowDrawerLibraryRow(
                  title: library.name,
                  subtitle:
                      library.addresses.firstOrNull?.url ??
                      loc.widgets_drawer_server_unconfigured,
                  selected: isActive,
                  onSelected: () {
                    if (!isActive) {
                      _switchLibrary(library);
                    }
                    setState(() {
                      _showLibraries = false;
                    });
                    Navigator.of(context).pop();
                  },
                  onEdit: () => _closeDrawerAndPushLocation(
                    '/library/edit/${library.id}',
                  ),
                ),
              );
            }

            if (index == items.length) {
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  context.musicFlowSpacing.md,
                  context.musicFlowSpacing.xxs,
                  context.musicFlowSpacing.md,
                  context.musicFlowSpacing.sm,
                ),
                child: const MusicFlowDivider(),
              );
            }

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: context.musicFlowSpacing.xs),
              child: MusicFlowActionRow(
                icon: AppIcons.add,
                title: loc.widgets_drawer_add_new_library,
                subtitle: loc.widgets_drawer_add_new_library_subtitle,
                onPressed: () => _closeDrawerAndPushLocation('/login?add=true'),
              ),
            );
          },
        );
      },
      loading: () => const _DrawerSkeletonList(),
      error: (error, stackTrace) => MusicFlowErrorState(
        title: loc.widgets_drawer_library_error_title,
        description: loc.widgets_drawer_library_error_desc,
        actionLabel: loc.widgets_retry,
        onAction: () => ref.invalidate(librariesProvider),
      ),
    );
  }

  Widget _buildNavigationList() {
    final loc = AppLocalizations.of(context);
    final entries = <_DrawerNavigationEntry?>[
      _DrawerNavigationEntry(
        title: loc.widgets_artists,
        icon: AppIcons.profile,
        onPressed: () =>
            _closeDrawerAndPushPage((context) => const ArtistListPage()),
      ),
      _DrawerNavigationEntry(
        title: loc.widgets_albums,
        icon: AppIcons.album,
        onPressed: () =>
            _closeDrawerAndPushPage((context) => const AlbumListPage()),
      ),
      _DrawerNavigationEntry(
        title: loc.widgets_songs,
        icon: AppIcons.music,
        onPressed: () =>
            _closeDrawerAndPushPage((context) => const SongListPage()),
      ),
      _DrawerNavigationEntry(
        title: loc.widgets_playlists,
        icon: AppIcons.playlist,
        onPressed: () =>
            _closeDrawerAndPushPage((context) => const PlaylistSearchPage()),
      ),
      _DrawerNavigationEntry(
        title: loc.widgets_favorites,
        icon: AppIcons.heart,
        onPressed: () =>
            _closeDrawerAndPushPage((context) => const StarredPage()),
      ),
      _DrawerNavigationEntry(
        icon: AppIcons.settings,
        title: loc.widgets_settings,
        onPressed: () =>
            _closeDrawerAndPushPage((context) => const AppSettingsPage()),
      ),
    ];

    return ListView.builder(
      key: const PageStorageKey<String>('musicflow-drawer-navigation'),
      padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry == null) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.xxs,
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.xs,
            ),
            child: const MusicFlowDivider(),
          );
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
            context.musicFlowSpacing.xs,
            0,
            context.musicFlowSpacing.xs,
            context.musicFlowSpacing.xs,
          ),
          child: MusicFlowActionRow(
            icon: entry.icon,
            title: entry.title,
            // 安卓端侧边栏不显示向右箭头,其余平台保留。
            trailing: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
                ? null
                : Icon(
                    AppIcons.chevronRight,
                    size: context.musicFlowInteraction.smallIconSize,
                    color: context.musicFlowColors.muted,
                  ),
            onPressed: entry.onPressed,
          ),
        );
      },
    );
  }

  Future<void> _switchLibrary(MusicLibrary library) async {
    final repository = ref.read(libraryRepositoryProvider);
    await repository.setActiveLibrary(library.id);
    ref.read(authStateProvider.notifier).switchLibrary(library);

    ref.invalidate(playerProvider);
    ref.invalidate(randomSongsProvider);
    // 广播变更信号,让随机歌曲区块按需重拉新库内容。
    notifyRandomSongsChanged();
    ref.invalidate(recentAlbumsProvider);
    ref.invalidate(frequentAlbumsProvider);
    ref.invalidate(playlistsProvider);
    ref.invalidate(starredProvider);
  }

  void _closeDrawerAndPushPage(WidgetBuilder builder) {
    final navigator = Navigator.of(context);
    final page = builder(context);
    final opener = widget.onOpenPage;
    navigator.pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!navigator.mounted) return;
      if (opener != null) {
        unawaited(opener(page));
        return;
      }
      navigator.push(MusicFlowPageRoute<void>(
        context: navigator.context,
        builder: (_) => page,
      ));
    });
  }

  void _closeDrawerAndPushLocation(String location) {
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    navigator.pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!navigator.mounted) return;
      router.push(location);
    });
  }
}

@visibleForTesting
String? resolveMusicFlowDrawerAvatarUrl(MusicLibrary? library) {
  if (library == null) return null;
  final raw = library.extensions['avatarUrl'];
  if (raw is! String || raw.trim().isEmpty) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || (!uri.hasScheme && !uri.hasAbsolutePath)) return null;
  return raw.trim();
}

MusicFlowDrawerConnectionState _connectionState(ServerAddress? address) {
  if (address == null) return MusicFlowDrawerConnectionState.disconnected;
  return switch (address.status) {
    ServerAddressStatus.ok => MusicFlowDrawerConnectionState.connected,
    ServerAddressStatus.failed => MusicFlowDrawerConnectionState.failed,
    ServerAddressStatus.unknown => MusicFlowDrawerConnectionState.unknown,
  };
}

class _DrawerNavigationEntry {
  const _DrawerNavigationEntry({
    required this.icon,
    required this.title,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final VoidCallback onPressed;
}

class _DrawerSkeletonList extends StatelessWidget {
  const _DrawerSkeletonList({this.itemCount = 4});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: context.musicFlowSpacing.md,
        vertical: context.musicFlowSpacing.sm,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        return Padding(
          padding: EdgeInsets.only(bottom: context.musicFlowSpacing.md),
          child: Row(
            children: <Widget>[
              const MusicFlowSkeleton.circle(),
              SizedBox(width: context.musicFlowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    MusicFlowSkeleton.line(
                      width: index.isEven ? 140 : 112,
                      height: 16,
                    ),
                    SizedBox(height: context.musicFlowSpacing.xs),
                    const MusicFlowSkeleton.line(width: 196),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}