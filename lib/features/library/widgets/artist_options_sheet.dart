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
    return MusicFlowBottomSheet(
      title: artist.name,
      subtitle: artist.albumCount != null ? '${artist.albumCount} 张专辑' : null,
      showDragHandle: compactSheet,
      sceneRadius: !compactSheet,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.play,
              title: '播放歌手热门歌曲',
              onPressed: () => _closeAndRun(context, _playTopSongs),
            ),
            MusicFlowActionRow(
              icon: artist.starred ? AppIcons.heart : AppIcons.heartOutline,
              title: artist.starred ? '取消收藏歌手' : '收藏歌手',
              selected: artist.starred,
              onPressed: () => _closeAndRun(context, _toggleStarred),
            ),
            MusicFlowActionRow(
              icon: AppIcons.queueAdd,
              title: '添加到播放列表',
              onPressed: () => _closeAndRun(context, () async {
                final songs = await _loadTopSongs();
                if (songs == null || songs.isEmpty) return;
                hostRef.read(playerProvider.notifier).addAllToQueue(songs);
                _showMessage('已添加 ${songs.length} 首到播放列表');
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
    final repository = hostRef.read(musicRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show('未选择音乐库');
      return null;
    }

    try {
      await hostRef.read(ensureActiveAddressProvider.future);
      final songs = await repository.getTopSongs(artist.name);
      if (songs.isEmpty) {
        NetworkErrorNotifier.show('歌手暂无可用歌曲');
        return null;
      }
      return songs;
    } catch (_) {
      NetworkErrorNotifier.show('网络异常，歌手歌曲加载失败');
      return null;
    }
  }

  Future<void> _toggleStarred() async {
    final repository = hostRef.read(musicRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show('未选择音乐库');
      return;
    }

    try {
      await hostRef.read(ensureActiveAddressProvider.future);
      final nextStarred = !artist.starred;
      await repository.setArtistStarred(artist.id, nextStarred);
      hostRef.invalidate(starredProvider);
      _showMessage(nextStarred ? '已收藏歌手' : '已取消收藏');
    } catch (_) {
      NetworkErrorNotifier.show('网络异常，操作失败');
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
