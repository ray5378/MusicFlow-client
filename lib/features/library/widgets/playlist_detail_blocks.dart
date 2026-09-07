import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';

class PlaylistSongEntry {
  const PlaylistSongEntry({required this.song, required this.originalIndex});

  final Song song;
  final int originalIndex;
}

class PlaylistSelectionBar extends StatelessWidget {
  const PlaylistSelectionBar({
    required this.selectedCount,
    required this.removing,
    required this.onRemove,
  });

  final int selectedCount;
  final bool removing;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final count = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(loc.library_remove_from_current_playlist, style: context.musicFlowTypography.title),
        SizedBox(height: context.musicFlowSpacing.xxs),
        Text(
          loc.library_selected_count_rationale('$selectedCount'),
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.muted,
          ),
        ),
      ],
    );

    MusicFlowButton removeButton({required bool expand}) => MusicFlowButton.destructive(
      label: removing ? loc.library_removing : loc.library_remove_selected,
      semanticLabel: loc.library_remove_selected_semantics,
      leadingIcon: AppIcons.removeCircle,
      expand: expand,
      onPressed: removing ? null : onRemove,
    );

    return MusicFlowSurface(
      level: MusicFlowSurfaceLevel.surface,
      borderRadius: BorderRadius.zero,
      borderColor: context.musicFlowColors.divider,
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stack =
              constraints.maxWidth < 380 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                count,
                SizedBox(height: context.musicFlowSpacing.xs),
                removeButton(expand: true),
              ],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(child: count),
              SizedBox(width: context.musicFlowSpacing.md),
              removeButton(expand: false),
            ],
          );
        },
      ),
    );
  }
}

class PlaylistIdentityHeader extends StatelessWidget {
  const PlaylistIdentityHeader({
    required this.playlist,
    required this.songCount,
    this.isNowPlaying = false,
  });

  final Playlist playlist;
  final int songCount;

  /// 该歌单是否正在播放：封面右下角叠加半透明遮罩 + 白色跳动竖条。
  final bool isNowPlaying;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final comment = playlist.comment?.trim();

    return MediaDetailHeaderSurface(
      coverArtId: playlist.coverArt,
      child: Padding(
        padding: EdgeInsets.all(context.musicFlowSpacing.lg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 680;
            final cover = SizedBox.square(
              dimension: wide ? 176 : 120,
              child: MediaDetailArtwork(
                coverArtId: playlist.coverArt,
                semanticLabel: loc.library_playlist_cover(playlist.name),
                heroTag: 'playlist-cover-${playlist.id}',
                requestSize: 480,
                isNowPlaying: isNowPlaying,
              ),
            );
            final information = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    playlist.name,
                    style: context.musicFlowTypography.display,
                  ),
                ),
                if (comment != null && comment.isNotEmpty) ...<Widget>[
                  SizedBox(height: context.musicFlowSpacing.xs),
                  Text(comment, style: context.musicFlowTypography.body),
                ],
                SizedBox(height: context.musicFlowSpacing.sm),
                Wrap(
                  spacing: context.musicFlowSpacing.xs,
                  runSpacing: context.musicFlowSpacing.xxs,
                  children: <Widget>[
                    Text(
                      loc.library_song_count('$songCount'),
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                    Text(
                      playlist.durationString,
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                    Text(
                      playlist.public ? loc.library_public_playlist : loc.library_private_playlist,
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ],
                ),
              ],
            );

            if (!wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  cover,
                  SizedBox(width: context.musicFlowSpacing.md),
                  Expanded(child: information),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                cover,
                SizedBox(width: context.musicFlowSpacing.xl),
                Expanded(child: information),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 歌单详情加载中的占位预览：利用列表传入的预加载数据立即展示封面+标题，
/// 避免用户点击后看到白屏 loading spinner。
class PlaylistLoadingPreview extends StatelessWidget {
  const PlaylistLoadingPreview({
    required this.name,
    required this.songCount,
    this.coverArt,
  });

  final String name;
  final int songCount;
  final String? coverArt;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: MediaDetailHeaderSurface(
                coverArtId: coverArt,
                child: Padding(
                  padding: EdgeInsets.all(context.musicFlowSpacing.lg),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox.square(
                        dimension: 120,
                        child: MediaDetailArtwork(
                          coverArtId: coverArt,
                          semanticLabel: loc.library_playlist_cover(name),
                          heroTag: 'playlist-cover-$name',
                          requestSize: 480,
                        ),
                      ),
                      SizedBox(width: context.musicFlowSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(name, style: context.musicFlowTypography.display),
                            SizedBox(height: context.musicFlowSpacing.sm),
                            Text(
                              loc.library_song_count('$songCount'),
                              style: context.musicFlowTypography.metadata.copyWith(
                                color: context.musicFlowColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
