import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/network_error_notifier.dart';
import '../../../core/utils/toast_notifier.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/song.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/queue_origin_provider.dart';
import '../../../l10n/generated/app_localizations.dart';

/// 歌手长按/右键菜单:播放歌手热门歌曲、收藏/取消收藏、添加到播放列表。
Future<void> showArtistOptionsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required Artist artist,
  bool useRootNavigator = true,
}) async {
  await showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) => _ArtistOptionsSheet(
      hostContext: context,
      hostRef: ref,
      artist: artist,
      compactSheet:
          context.musicFlowWindowClass == MusicFlowWindowClass.compact,
    ),
  );
}

class _ArtistOptionsSheet extends ConsumerWidget {
  const _ArtistOptionsSheet({
    required this.hostContext,
    required this.hostRef,
    required this.artist,
    required this.compactSheet,
  });

  final BuildContext hostContext;
  final WidgetRef hostRef;
  final Artist artist;
  final bool compactSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    return MusicFlowBottomSheet(
      title: artist.name,
      subtitle: artist.albumCount != null ? loc.library_album_count(artist.albumCount.toString()) : null,
      showDragHandle: compactSheet,
      sceneRadius: !compactSheet,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.play,
              title: loc.library_play_artist_top,
              onPressed: () => _closeAndRun(context, _playTopSongs),
            ),
            MusicFlowActionRow(
              icon: artist.starred ? AppIcons.heart : AppIcons.heartOutline,
              title: artist.starred ? loc.library_unfavorited_artist : loc.library_favorite_artist,
              selected: artist.starred,
              onPressed: () => _closeAndRun(context, _toggleStarred),
            ),
            MusicFlowActionRow(
              icon: AppIcons.queueAdd,
              title: loc.library_add_to_queue,
              onPressed: () => _closeAndRun(context, () async {
                final songs = await _loadTopSongs();
                if (songs == null || songs.isEmpty) return;
                hostRef.read(playerProvider.notifier).addAllToQueue(songs);
                _showMessage(loc.library_added_to_queue('${songs.length}'));
              }),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playTopSongs() async {
    final songs = await _loadTopSongs();
    if (songs == null || songs.isEmpty) return;
    await playEffectiveQueue(
      hostRef,
      songs,
      startIndex: 0,
      origin: QueueOrigin(QueueOriginKind.artist, artist.id),
    );
  }

  Future<List<Song>?> _loadTopSongs() async {
    final loc = AppLocalizations.of(hostContext);
    final repository = hostRef.read(musicRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show(loc.discover_no_library_selected);
      return null;
    }

    try {
      await hostRef.read(ensureActiveAddressProvider.future);
      final songs = await repository.getTopSongs(artist.name);
      if (songs.isEmpty) {
        NetworkErrorNotifier.show(loc.library_artist_no_songs);
        return null;
      }
      return songs;
    } catch (_) {
      NetworkErrorNotifier.show(loc.library_network_artist_load_failed);
      return null;
    }
  }

  Future<void> _toggleStarred() async {
    final loc = AppLocalizations.of(hostContext);
    final repository = hostRef.read(musicRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show(loc.discover_no_library_selected);
      return;
    }

    try {
      await hostRef.read(ensureActiveAddressProvider.future);
      final nextStarred = !artist.starred;
      await repository.setArtistStarred(artist.id, nextStarred);
      hostRef.invalidate(starredProvider);
      _showMessage(nextStarred ? loc.library_favorited_artist : loc.library_unfavorited_short);
    } catch (_) {
      NetworkErrorNotifier.show(loc.library_network_op_failed);
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
