import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/widgets/music_flow_artwork.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

class AddToPlaylistSheet extends ConsumerWidget {
  const AddToPlaylistSheet({required this.hostContext, required this.song});

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
                return PlaylistOptionRow(
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
          loading: () => const PlaylistOptionsLoading(),
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

class PlaylistOptionRow extends StatelessWidget {
  const PlaylistOptionRow({
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

class PlaylistOptionsLoading extends StatelessWidget {
  const PlaylistOptionsLoading();

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
