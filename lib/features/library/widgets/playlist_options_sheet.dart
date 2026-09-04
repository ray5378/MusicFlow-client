import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/network_error_notifier.dart';
import '../../../core/utils/toast_notifier.dart';
import '../../../data/models/playlist.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/queue_origin_provider.dart';
import '../../../l10n/generated/app_localizations.dart';

/// 需要调用方继续处理的歌单操作（播放/喜欢在弹窗内直接执行）。
enum PlaylistOptionsAction { addToQueue, edit, delete }

Future<PlaylistOptionsAction?> showPlaylistOptionsSheet({
  required BuildContext context,
  required Playlist playlist,
  bool hasSongs = true,
  bool useRootNavigator = true,
}) async {
  return showMusicFlowBottomSheet<PlaylistOptionsAction>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) => _PlaylistOptionsSheet(
      hostContext: context,
      playlist: playlist,
      hasSongs: hasSongs,
      compactSheet:
          context.musicFlowWindowClass == MusicFlowWindowClass.compact,
    ),
  );
}

class _PlaylistOptionsSheet extends ConsumerWidget {
  final BuildContext hostContext;
  final Playlist playlist;
  final bool hasSongs;
  final bool compactSheet;

  const _PlaylistOptionsSheet({
    required this.hostContext,
    required this.playlist,
    required this.hasSongs,
    required this.compactSheet,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    return MusicFlowBottomSheet(
      title: playlist.name,
      // 推荐歌单等无时长来源的场景(duration=0)只显示歌曲数,不追加「0分」。
      subtitle: playlist.duration > 0
          ? loc.library_playlist_count_duration('${playlist.songCount}', playlist.durationString)
          : loc.discover_track_count('${playlist.songCount}'),
      showDragHandle: compactSheet,
      sceneRadius: !compactSheet,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.play,
              title: loc.discover_play_playlist,
              subtitle: hasSongs ? null : loc.library_playlist_no_songs,
              onPressed: hasSongs
                  ? () => unawaited(_closeAndRun(context, ref, _playAll))
                  : null,
            ),
            MusicFlowActionRow(
              icon: playlist.favorite
                  ? AppIcons.heart
                  : AppIcons.heartOutline,
              title: playlist.favorite ? loc.library_unfavorite_playlist : loc.library_favorite_playlist,
              selected: playlist.favorite,
              onPressed: () => unawaited(
                _closeAndRun(context, ref, _toggleFavorite),
              ),
            ),
            MusicFlowActionRow(
              icon: AppIcons.queueAdd,
              title: loc.library_add_to_queue,
              subtitle: hasSongs ? null : loc.library_playlist_no_songs,
              onPressed: hasSongs
                  ? () => Navigator.of(
                      context,
                    ).pop(PlaylistOptionsAction.addToQueue)
                  : null,
            ),
            MusicFlowActionRow(
              icon: AppIcons.edit,
              title: loc.library_edit_playlist,
              onPressed: () =>
                  Navigator.of(context).pop(PlaylistOptionsAction.edit),
            ),
            MusicFlowActionRow(
              icon: AppIcons.delete,
              title: loc.library_delete_playlist,
              destructive: true,
              onPressed: () =>
                  Navigator.of(context).pop(PlaylistOptionsAction.delete),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _closeAndRun(
    BuildContext sheetContext,
    WidgetRef ref,
    Future<void> Function(WidgetRef ref) action,
  ) async {
    Navigator.of(sheetContext).pop();
    await Future<void>.delayed(Duration.zero);
    if (!hostContext.mounted) return;
    await action(ref);
  }

  Future<void> _playAll(WidgetRef ref) async {
    final loc = AppLocalizations.of(hostContext);
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show(loc.discover_no_library_selected);
      return;
    }
    try {
      final songs = await repository.getAllPlaylistSongs(playlist.id);
      if (!hostContext.mounted || songs.isEmpty) return;
      await playEffectiveQueue(
        ref,
        songs,
        startIndex: 0,
        origin: QueueOrigin(QueueOriginKind.playlist, playlist.id),
      );
    } catch (_) {
      if (hostContext.mounted) {
        NetworkErrorNotifier.show(loc.discover_network_failed_play_playlist);
      }
    }
  }

  Future<void> _toggleFavorite(WidgetRef ref) async {
    final loc = AppLocalizations.of(hostContext);
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show(loc.discover_no_library_selected);
      return;
    }
    final nextFavorite = !playlist.favorite;
    try {
      final ok = await repository.setPlaylistFavorite(
        playlist.id,
        nextFavorite,
      );
      if (!ok || !hostContext.mounted) return;
      ref.invalidate(favoritePlaylistsProvider);
      ToastNotifier.show(
        nextFavorite ? loc.library_favorited_playlist(playlist.name) : loc.library_unfavorited_playlist(playlist.name),
        kind: MusicFlowMessageKind.success,
      );
    } catch (_) {
      if (hostContext.mounted) NetworkErrorNotifier.show(loc.library_network_op_failed);
    }
  }
}
