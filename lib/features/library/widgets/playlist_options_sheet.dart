import 'package:flutter/material.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/playlist.dart';

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
      playlist: playlist,
      hasSongs: hasSongs,
      compactSheet:
          context.musicFlowWindowClass == MusicFlowWindowClass.compact,
    ),
  );
}

class _PlaylistOptionsSheet extends StatelessWidget {
  final Playlist playlist;
  final bool hasSongs;
  final bool compactSheet;

  const _PlaylistOptionsSheet({
    required this.playlist,
    required this.hasSongs,
    required this.compactSheet,
  });

  @override
  Widget build(BuildContext context) {
    return MusicFlowBottomSheet(
      title: playlist.name,
      subtitle: '${playlist.songCount} 首 · ${playlist.durationString}',
      showDragHandle: compactSheet,
      sceneRadius: !compactSheet,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.queueAdd,
              title: '添加到播放列表',
              subtitle: hasSongs ? null : '歌单中暂无歌曲',
              onPressed: hasSongs
                  ? () => Navigator.of(
                      context,
                    ).pop(PlaylistOptionsAction.addToQueue)
                  : null,
            ),
            MusicFlowActionRow(
              icon: AppIcons.edit,
              title: '修改歌单',
              onPressed: () =>
                  Navigator.of(context).pop(PlaylistOptionsAction.edit),
            ),
            MusicFlowActionRow(
              icon: AppIcons.delete,
              title: '删除歌单',
              destructive: true,
              onPressed: () =>
                  Navigator.of(context).pop(PlaylistOptionsAction.delete),
            ),
          ],
        ),
      ),
    );
  }
}
