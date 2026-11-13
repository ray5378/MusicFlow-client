import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

/// 学习歌单详情页：与音乐歌单一致的行交互，播放同样走统一入口
/// （本机 / 投屏 / 直投三链路，流转后队列可继续控制）。
class StudyPlaylistPage extends ConsumerWidget {
  const StudyPlaylistPage({
    super.key,
    required this.playlistId,
    required this.title,
  });

  final String playlistId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 学习音频播放(含流转)时按 10s 心跳上报进度。
    ref.read(studyProgressReporterProvider);
    final loc = AppLocalizations.of(context);
    final async = ref.watch(studyPlaylistTracksProvider(playlistId));
    final currentSongId =
        ref.watch(playerProvider.select((s) => s.currentSong?.id));

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: title),
      body: MusicFlowRefreshView(
        onRefresh: () async {
          ref.invalidate(studyPlaylistTracksProvider(playlistId));
          await ref
              .read(studyPlaylistTracksProvider(playlistId).future)
              .catchError((Object _) => <Song>[]);
        },
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: MusicFlowButton.secondary(
              label: loc.widgets_retry,
              onPressed: () =>
                  ref.invalidate(studyPlaylistTracksProvider(playlistId)),
            ),
          ),
          data: (songs) {
            if (songs.isEmpty) {
              return Center(
                child: Text(
                  loc.study_empty_playlist_tracks,
                  style: context.musicFlowTypography.metadata.copyWith(
                    color: context.musicFlowColors.muted,
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 32),
              itemCount: songs.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            loc.study_playlist_song_count(songs.length),
                            style: context.musicFlowTypography.metadata
                                .copyWith(
                              color: context.musicFlowColors.muted,
                            ),
                          ),
                        ),
                        MusicFlowButton.primary(
                          label: loc.library_play_all,
                          leadingIcon: AppIcons.play,
                          onPressed: () => unawaited(
                            playEffectiveQueue(ref, songs),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final song = songs[index - 1];
                return MusicFlowSongRow(
                  song: song,
                  index: index,
                  isCurrent: song.id == currentSongId,
                  onPressed: () => unawaited(
                    playEffectiveQueue(
                      ref,
                      songs,
                      startIndex: index - 1,
                    ),
                  ),
                  onMorePressed: null,
                  showMoreButton: false,
                );
              },
            );
          },
        ),
      ),
    );
  }
}
