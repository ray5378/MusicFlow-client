import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/network_error_notifier.dart';
import '../../../core/utils/toast_notifier.dart';
import '../../../data/models/album.dart';
import '../../../data/models/song.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/queue_origin_provider.dart';
import '../../../l10n/generated/app_localizations.dart';

Future<void> showAlbumOptionsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required Album album,
  bool useRootNavigator = true,
}) async {
  await showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) => _AlbumOptionsSheet(
      hostContext: context,
      hostRef: ref,
      album: album,
      compactSheet:
          context.musicFlowWindowClass == MusicFlowWindowClass.compact,
    ),
  );
}

class _AlbumOptionsSheet extends ConsumerWidget {
  const _AlbumOptionsSheet({
    required this.hostContext,
    required this.hostRef,
    required this.album,
    required this.compactSheet,
  });

  final BuildContext hostContext;
  final WidgetRef hostRef;
  final Album album;
  final bool compactSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final artistName = album.artist?.trim().isNotEmpty == true
        ? album.artist!.trim()
        : loc.library_unknown_artist;

    return MusicFlowBottomSheet(
      title: album.name,
      subtitle: artistName,
      showDragHandle: compactSheet,
      sceneRadius: !compactSheet,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.play,
              title: loc.library_play_album,
              onPressed: () => _closeAndRun(context, _playAlbum),
            ),
            MusicFlowActionRow(
              icon: album.starred ? AppIcons.heart : AppIcons.heartOutline,
              title: album.starred ? loc.library_unfavorited_album : loc.library_favorite_album,
              selected: album.starred,
              onPressed: () => _closeAndRun(context, () async {
                final repository = hostRef.read(musicRepositoryProvider);
                if (repository == null) {
                  NetworkErrorNotifier.show(loc.discover_no_library_selected);
                  return;
                }

                try {
                  await hostRef.read(ensureActiveAddressProvider.future);
                  final nextStarred = !album.starred;
                  await repository.setAlbumStarred(album.id, nextStarred);
                  _invalidateAlbumQueries();
                  _showMessage(nextStarred ? loc.library_favorited_album : loc.library_unfavorited_short);
                } catch (_) {
                  NetworkErrorNotifier.show(loc.library_network_op_failed);
                }
              }),
            ),
            MusicFlowActionRow(
              icon: AppIcons.queueAdd,
              title: loc.library_add_to_queue,
              onPressed: () => _closeAndRun(context, () async {
                final songs = await _loadAlbumSongs();
                if (songs == null || songs.isEmpty) return;
                hostRef.read(playerProvider.notifier).addAllToQueue(songs);
                _showMessage(loc.library_added_to_queue('${songs.length}'));
              }),
            ),
            MusicFlowActionRow(
              icon: AppIcons.playlistAdd,
              title: loc.library_add_to_playlist,
              onPressed: () => _closeAndRun(context, () async {
                final songs = await _loadAlbumSongs();
                if (songs == null || songs.isEmpty || !hostContext.mounted) {
                  return;
                }

                await showMusicFlowBottomSheet<void>(
                  context: hostContext,
                  useRootNavigator: true,
                  isScrollControlled: true,
                  builder: (_) => _AddAlbumToPlaylistSheet(
                    hostContext: hostContext,
                    album: album,
                    songs: songs,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playAlbum() async {
    final songs = await _loadAlbumSongs();
    if (songs == null || songs.isEmpty) return;
    await playEffectiveQueue(
      hostRef,
      songs,
      startIndex: 0,
      origin: QueueOrigin(QueueOriginKind.album, album.id),
    );
  }

  Future<List<Song>?> _loadAlbumSongs() async {
    final loc = AppLocalizations.of(hostContext);
    if (album.songCount <= 0) {
      NetworkErrorNotifier.show(loc.library_album_no_songs);
      return null;
    }

    final repository = hostRef.read(musicRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show(loc.discover_no_library_selected);
      return null;
    }

    try {
      await hostRef.read(ensureActiveAddressProvider.future);
      final detail = await repository.getAlbum(album.id);
      final songs = detail?.songs ?? const <Song>[];
      if (songs.isEmpty) {
        NetworkErrorNotifier.show(loc.library_album_no_songs);
        return null;
      }
      return songs;
    } catch (_) {
      NetworkErrorNotifier.show(loc.library_network_album_load_failed);
      return null;
    }
  }

  void _invalidateAlbumQueries() {
    hostRef.invalidate(starredProvider);
    hostRef.invalidate(allAlbumsProvider);
    hostRef.invalidate(recentAlbumsProvider);
    hostRef.invalidate(frequentAlbumsProvider);
    hostRef.invalidate(albumDetailProvider(album.id));
    final artistId = album.artistId;
    if (artistId != null && artistId.trim().isNotEmpty) {
      hostRef.invalidate(artistDetailProvider(artistId));
    }
  }

  void _closeAndRun(BuildContext sheetContext, Future<void> Function() action) {
    Navigator.of(sheetContext).pop();
    Future<void>.microtask(() async {
      if (!hostContext.mounted) return;
      await action();
    });
  }

  void _showMessage(String message) {
    if (!hostContext.mounted) return;
    ToastNotifier.show(message, kind: MusicFlowMessageKind.success);
  }
}

class _AddAlbumToPlaylistSheet extends ConsumerWidget {
  const _AddAlbumToPlaylistSheet({
    required this.hostContext,
    required this.album,
    required this.songs,
  });

  final BuildContext hostContext;
  final Album album;
  final List<Song> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final playlistsAsync = ref.watch(playlistsProvider);
    final loadFailed = ref.watch(playlistsLoadFailedProvider);
    final songIds = songs.map((song) => song.id).toSet().toList();
    final maxListHeight = MediaQuery.sizeOf(context).height * 0.56;

    return MusicFlowBottomSheet(
      title: loc.library_add_to_playlist,
      subtitle: album.name,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxListHeight),
        child: playlistsAsync.when(
          data: (playlists) {
            if (playlists.isEmpty) {
              return MusicFlowEmptyState(
                title: loadFailed ? loc.library_playlists_unavailable : loc.library_no_playlists,
                description: loadFailed ? loc.library_retry_on_network : loc.library_create_playlist_first,
                icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
                actionLabel: loadFailed ? loc.widgets_retry : null,
                onAction: loadFailed
                    ? () => ref.invalidate(playlistsProvider)
                    : null,
                padding: const EdgeInsets.all(24),
              );
            }

            return ListView.builder(
              shrinkWrap: true,
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return MusicFlowActionRow(
                  icon: AppIcons.playlist,
                  title: playlist.name,
                  subtitle: loc.discover_track_count(playlist.songCount.toString()),
                  onPressed: () {
                    Navigator.of(context).pop();
                    unawaited(
                      _addToPlaylist(
                        ref: ref,
                        playlistId: playlist.id,
                        playlistName: playlist.name,
                        songIds: songIds,
                      ),
                    );
                  },
                );
              },
            );
          },
          loading: () => const _PlaylistSkeletonList(),
          error: (_, _) => MusicFlowErrorState(
            title: loc.library_playlist_load_failed,
            description: loc.library_playlist_load_failed_desc,
            actionLabel: loc.widgets_retry,
            onAction: () => ref.invalidate(playlistsProvider),
            padding: const EdgeInsets.all(24),
          ),
        ),
      ),
    );
  }

  Future<void> _addToPlaylist({
    required WidgetRef ref,
    required String playlistId,
    required String playlistName,
    required List<String> songIds,
  }) async {
    final loc = AppLocalizations.of(hostContext);
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show(loc.discover_no_library_selected);
      return;
    }

    try {
      await ref.read(ensureActiveAddressProvider.future);
      await repository.updatePlaylist(
        playlistId: playlistId,
        songIdsToAdd: songIds,
      );
      ref.invalidate(playlistsProvider);
      ref.invalidate(playlistDetailProvider(playlistId));
      if (hostContext.mounted) {
        ToastNotifier.show(
          loc.library_added_to_playlist(album.name, playlistName),
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (_) {
      NetworkErrorNotifier.show(loc.library_network_add_failed);
    }
  }
}

class _PlaylistSkeletonList extends StatelessWidget {
  const _PlaylistSkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      itemCount: 3,
      separatorBuilder: (context, index) =>
          SizedBox(height: context.musicFlowSpacing.xs),
      itemBuilder: (context, index) => Row(
        children: <Widget>[
          const MusicFlowSkeleton.circle(size: 48),
          SizedBox(width: context.musicFlowSpacing.sm),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                MusicFlowSkeleton.line(width: 160),
                SizedBox(height: 8),
                MusicFlowSkeleton.line(width: 72, height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
