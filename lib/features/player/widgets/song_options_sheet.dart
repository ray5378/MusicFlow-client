import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/network_error_notifier.dart';
import '../../../core/utils/toast_notifier.dart';
import '../../../data/models/song.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/dlna_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../widgets/music_flow_artwork.dart';
import '../../library/pages/album_detail_page.dart';
import '../../library/pages/artist_detail_page.dart';
import '../../../l10n/generated/app_localizations.dart';

class SongOptionsExtraAction {
  const SongOptionsExtraAction({
    required this.icon,
    required this.title,
    required this.onPressed,
    this.isDestructive = false,
  });

  final IconData icon;
  final String title;
  final bool isDestructive;
  final FutureOr<void> Function() onPressed;
}

Future<void> showSongOptionsSheet({
  required BuildContext context,
  required Song song,
  bool useRootNavigator = true,
  List<SongOptionsExtraAction> extraActions = const <SongOptionsExtraAction>[],
  MusicFlowMediaVisuals? mediaVisuals,
}) async {
  // 桌面端:在触发点附近渲染「菜单」型小弹窗;移动端保留底部抽屉样式。
  final compactSheet =
      context.musicFlowWindowClass == MusicFlowWindowClass.compact;
  await showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    desktopAnchored: !compactSheet,
    builder: (_) {
      final sheet = _SongOptionsSheet(
        hostContext: context,
        song: song,
        extraActions: extraActions,
        compactSheet: compactSheet,
      );
      if (mediaVisuals == null) return sheet;
      return MusicFlowMediaColorScope(
        visuals: mediaVisuals,
        role: MusicFlowMediaSurfaceRole.panel,
        child: sheet,
      );
    },
  );
}

class _SongOptionsSheet extends ConsumerWidget {
  const _SongOptionsSheet({
    required this.hostContext,
    required this.song,
    required this.extraActions,
    required this.compactSheet,
  });

  final BuildContext hostContext;
  final Song song;
  final List<SongOptionsExtraAction> extraActions;

  /// 是否为移动端(compact)底部抽屉;false 时表现为桌面端锚点弹窗。
  final bool compactSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final currentSongId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    final isCurrentSong = currentSongId != null && currentSongId == song.id;
    final isCasting = ref.watch(
      castPeerControllerProvider.select((s) => s.activePeer != null),
    );
    // 链路 B（局域网 DLNA 直投）投屏态：同样把「加入投屏队列」路由到直投队列。
    final isDlnaCasting = ref.watch(
      dlnaCastProvider.select((s) => s.isCasting),
    );
    // 「加入投屏队列」的目标：链路 A > 链路 B > 本机下一曲。
    final enqueued = isCasting || isDlnaCasting;
    final artistName = song.artist?.trim().isNotEmpty == true
        ? song.artist!.trim()
        : loc.song_option_unknown_artist;
    final albumName = song.album?.trim().isNotEmpty == true
        ? song.album!.trim()
        : loc.song_option_unknown_album;
    final canOpenArtist = song.artistId?.trim().isNotEmpty == true;
    final canOpenAlbum = song.albumId?.trim().isNotEmpty == true;

    final actions = <Widget>[];
    if (song.isPreview) {
      actions.addAll(<Widget>[
        if (!isCurrentSong)
          _SongOptionRow(
            icon: AppIcons.queueAdd,
            title: enqueued ? loc.song_option_enqueue : loc.song_option_play_next,
            onPressed: () => unawaited(
              _closeAndRun(context, () async {
                if (isCasting) {
                  await ref
                      .read(castPeerControllerProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                } else if (isDlnaCasting) {
                  await ref
                      .read(dlnaCastProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                  _showMessage(loc.song_option_enqueued);
                } else {
                  await ref.read(playerProvider.notifier).playNext(song);
                }
              }),
            ),
          ),
      ]);
    } else {
      actions.addAll(<Widget>[
        _SongOptionRow(
          icon: song.starred ? AppIcons.heart : AppIcons.heartOutline,
          title: song.starred ? loc.player_unfavorite : loc.player_favorite,
          selected: song.starred,
          onPressed: () => unawaited(
            _closeAndRun(context, () async {
              final newStarred = await ref
                  .read(playerProvider.notifier)
                  .toggleSongFavorite(song);
              if (newStarred == null) {
                NetworkErrorNotifier.show(loc.song_option_operation_failed);
                return;
              }
              _showMessage(newStarred ? loc.song_option_favorite_added : loc.song_option_favorite_removed);
            }),
          ),
        ),
        _SongOptionRow(
          icon: AppIcons.playlistAdd,
          title: loc.library_add_to_playlist,
          onPressed: () => unawaited(
            _closeAndRun(context, () async {
              if (!hostContext.mounted) return;
              await showMusicFlowBottomSheet<void>(
                context: hostContext,
                useRootNavigator: true,
                isScrollControlled: true,
                builder: (_) =>
                    _AddToPlaylistSheet(hostContext: hostContext, song: song),
              );
            }),
          ),
        ),
        if (!isCurrentSong)
          _SongOptionRow(
            icon: AppIcons.queueAdd,
            title: enqueued ? loc.song_option_enqueue : loc.song_option_play_next,
            onPressed: () => unawaited(
              _closeAndRun(context, () async {
                if (isCasting) {
                  await ref
                      .read(castPeerControllerProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                  _showMessage(loc.song_option_enqueued);
                } else if (isDlnaCasting) {
                  await ref
                      .read(dlnaCastProvider.notifier)
                      .enqueueSongs(<Song>[song]);
                  _showMessage(loc.song_option_enqueued);
                } else {
                  await ref.read(playerProvider.notifier).playNext(song);
                  _showMessage(loc.song_option_play_next_added);
                }
              }),
            ),
          ),
        _SongOptionRow(
          icon: AppIcons.profile,
          title: loc.song_option_artist(artistName),
          onPressed: !canOpenArtist
              ? null
              : () => unawaited(
                  _closeAndRun(context, () async {
                    await Navigator.of(hostContext).push<void>(
                      MusicFlowPageRoute<void>(
                        context: hostContext,
                        builder: (_) =>
                            ArtistDetailPage(artistId: song.artistId!),
                      ),
                    );
                  }),
                ),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: artistName));
            ToastNotifier.show(loc.song_option_artist_copied(artistName));
          },
        ),
        _SongOptionRow(
          icon: AppIcons.albumOutline,
          title: loc.song_option_album(albumName),
          onPressed: !canOpenAlbum
              ? null
              : () => unawaited(
                  _closeAndRun(context, () async {
                    await Navigator.of(hostContext).push<void>(
                      MusicFlowPageRoute<void>(
                        context: hostContext,
                        builder: (_) => AlbumDetailPage(albumId: song.albumId!),
                      ),
                    );
                  }),
                ),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: albumName));
            ToastNotifier.show(loc.song_option_album_copied(albumName));
          },
        ),
      ]);
    }

    if (extraActions.isNotEmpty) {
      actions.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
          child: const MusicFlowDivider(),
        ),
      );
      for (final action in extraActions) {
        actions.add(
          _SongOptionRow(
            icon: action.icon,
            title: action.title,
            destructive: action.isDestructive,
            onPressed: () => unawaited(
              _closeAndRun(context, () async => action.onPressed()),
            ),
          ),
        );
      }
    }

    return MusicFlowBottomSheet(
      title: song.isPreview ? loc.song_option_title_preview : loc.song_option_title,
      showDragHandle: compactSheet,
      sceneRadius: !compactSheet,
      padding: EdgeInsets.fromLTRB(
        context.musicFlowSpacing.md,
        0,
        context.musicFlowSpacing.md,
        context.musicFlowSpacing.md,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.74,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _SongSummary(
                song: song,
                artistName: artistName,
                albumName: albumName,
                onCopyTitle: () {
                  Clipboard.setData(ClipboardData(text: song.title));
                  ToastNotifier.show(loc.song_option_copied_title(song.title));
                },
              ),
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
                child: const MusicFlowDivider(),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _closeAndRun(
    BuildContext sheetContext,
    Future<void> Function() action,
  ) async {
    Navigator.of(sheetContext).pop();
    await Future<void>.delayed(Duration.zero);
    if (!hostContext.mounted) return;
    await action();
  }

  void _showMessage(String message) {
    if (!hostContext.mounted) return;
    showMusicFlowMessage(hostContext, message);
  }
}

class _SongSummary extends StatelessWidget {
  const _SongSummary({
    required this.song,
    required this.artistName,
    required this.albumName,
    required this.onCopyTitle,
  });

  final Song song;
  final String artistName;
  final String albumName;
  final VoidCallback onCopyTitle;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MusicFlowPressable(
      semanticLabel: loc.song_option_summary_semantic(song.title, artistName, albumName),
      onLongPress: onCopyTitle,
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.expandedSongRowHeight,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: MusicFlowArtwork(
                coverArtId: song.artworkReference,
                semanticLabel: loc.song_cover_semantic(song.title),
                size: context.musicFlowInteraction.minimumTouchTarget,
                requestSize: 192,
                borderRadius: context.musicFlowRadii.detail,
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.title,
                  ),
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(
                    '$artistName · $albumName',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.metadata,
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

class _SongOptionRow extends StatelessWidget {
  const _SongOptionRow({
    required this.icon,
    required this.title,
    required this.onPressed,
    this.onLongPress,
    this.destructive = false,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool destructive;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final enabled = onPressed != null || onLongPress != null;
    final accent = destructive ? colors.error : colors.accent;
    final foreground = enabled
        ? destructive
              ? colors.error
              : colors.ink
        : colors.onDisabled;

    return MusicFlowPressable(
      semanticLabel: <String>[
        title,
        if (selected) loc.song_option_selected,
        if (!enabled) loc.song_option_not_available,
      ].join('，'),
      selected: selected,
      onPressed: onPressed,
      onLongPress: onLongPress,
      minimumSize: Size(double.infinity, context.musicFlowInteraction.songRowHeight),
      child: Ink(
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.1)
              : enabled
              ? Colors.transparent
              : colors.raised.withValues(alpha: 0.55),
          borderRadius: context.musicFlowRadii.control,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowSpacing.xs,
            vertical: context.musicFlowSpacing.xs,
          ),
          child: Row(
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
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.musicFlowTypography.title.copyWith(
                    color: foreground,
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

class _AddToPlaylistSheet extends ConsumerWidget {
  const _AddToPlaylistSheet({required this.hostContext, required this.song});

  final BuildContext hostContext;
  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final playlistsAsync = ref.watch(playlistsProvider);
    final loadFailed = ref.watch(playlistsLoadFailedProvider);

    return MusicFlowBottomSheet(
      title: loc.library_add_to_playlist,
      subtitle: song.title,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: playlistsAsync.when(
          data: (playlists) {
            if (playlists.isEmpty) {
              return MusicFlowEmptyState(
                title: loadFailed ? loc.song_option_playlist_load_failed : loc.song_option_no_playlists,
                description: loadFailed
                    ? loc.song_option_load_failed_desc
                    : loc.song_option_create_playlist_hint,
                icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
                actionLabel: loadFailed ? loc.widgets_retry : null,
                onAction: loadFailed
                    ? () => ref.invalidate(playlistsProvider)
                    : null,
                padding: EdgeInsets.all(context.musicFlowSpacing.lg),
              );
            }

            return ListView.separated(
              shrinkWrap: true,
              itemCount: playlists.length,
              separatorBuilder: (context, index) => MusicFlowDivider(
                inset:
                    context.musicFlowInteraction.minimumTouchTarget +
                    context.musicFlowSpacing.sm,
              ),
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return _PlaylistRow(
                  name: playlist.name,
                  songCount: playlist.songCount,
                  onPressed: () async {
                    Navigator.of(context).pop();
                    final repository = ref.read(playlistRepositoryProvider);
                    if (repository == null) {
                      NetworkErrorNotifier.show(loc.discover_no_library_selected);
                      return;
                    }

                    try {
                      await ref.read(ensureActiveAddressProvider.future);
                      await repository.updatePlaylist(
                        playlistId: playlist.id,
                        songIdsToAdd: <String>[song.id],
                      );
                      ref.invalidate(playlistsProvider);
                      ref.invalidate(playlistDetailProvider(playlist.id));
                      if (hostContext.mounted) {
                        showMusicFlowMessage(
                          hostContext,
                          loc.song_option_added_to_playlist(playlist.name),
                        );
                      }
                    } catch (_) {
                      NetworkErrorNotifier.show(loc.song_option_network_error);
                    }
                  },
                );
              },
            );
          },
          loading: () => const _PlaylistLoading(),
          error: (error, stackTrace) => MusicFlowErrorState(
            title: loc.song_option_playlist_load_failed,
            description: loc.song_option_load_failed_desc,
            actionLabel: loc.widgets_retry,
            onAction: () => ref.invalidate(playlistsProvider),
            padding: EdgeInsets.all(context.musicFlowSpacing.lg),
          ),
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.name,
    required this.songCount,
    required this.onPressed,
  });

  final String name;
  final int songCount;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MusicFlowPressable(
      semanticLabel: loc.song_option_playlist_row_semantic(name, songCount),
      onPressed: () => unawaited(onPressed()),
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.expandedSongRowHeight,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: Center(
                child: Icon(
                  AppIcons.playlist,
                  size: 22,
                  color: context.musicFlowColors.accent,
                ),
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.title,
                  ),
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(loc.song_option_song_count(songCount), style: context.musicFlowTypography.metadata),
                ],
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.xs),
            Icon(
              AppIcons.chevronRight,
              size: 20,
              color: context.musicFlowColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistLoading extends StatelessWidget {
  const _PlaylistLoading();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 216,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (var index = 0; index < 3; index += 1) ...<Widget>[
            Row(
              children: <Widget>[
                const MusicFlowSkeleton.circle(size: 48),
                SizedBox(width: context.musicFlowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const <Widget>[
                      MusicFlowSkeleton.line(width: 180, height: 16),
                      SizedBox(height: 8),
                      MusicFlowSkeleton.line(width: 72, height: 12),
                    ],
                  ),
                ),
              ],
            ),
            if (index < 2) SizedBox(height: context.musicFlowSpacing.sm),
          ],
        ],
      ),
    );
  }
}
