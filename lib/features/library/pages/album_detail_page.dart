import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/toast_notifier.dart';
import '../../../data/models/album.dart';
import '../../../data/models/song.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/queue_origin_provider.dart';
import '../../../widgets/song_list_item.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../utils/library_sorting.dart';
import '../widgets/album_options_sheet.dart';
import '../widgets/media_detail_components.dart';

class AlbumDetailPage extends ConsumerStatefulWidget {
  const AlbumDetailPage({super.key, required this.albumId});

  final String albumId;

  @override
  ConsumerState<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends ConsumerState<AlbumDetailPage> {
  SongSortOption _sortOption = SongSortOption.defaultOrder;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final detailAsync = ref.watch(albumDetailProvider(widget.albumId));
    final loadFailed = ref.watch(albumDetailLoadFailedProvider(widget.albumId));
    final currentAlbum = detailAsync.valueOrNull?.album;
    // 当前播放来源：识别本专辑是否正在播放（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);
    final isNowPlaying = queueOrigin?.matchesAlbum(widget.albumId) ?? false;

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'album_detail_page',
      shouldRetry: (ref) => loadFailed || detailAsync.hasError,
      onRetry: (ref) => ref.invalidate(albumDetailProvider(widget.albumId)),
      child: MusicFlowScaffold(
        topBar: MusicFlowTopBar.back(
          context: context,
          title: loc.library_album_title,
          actions: <Widget>[
            MusicFlowIconButton(
              icon: AppIcons.sort,
              label: loc.library_song_sort_option(_sortOption.label(loc)),
              onPressed: currentAlbum == null ? null : _selectSortOption,
            ),
            MusicFlowIconButton(
              icon: AppIcons.more,
              label: loc.library_album_actions,
              onPressed: currentAlbum == null
                  ? null
                  : () => showAlbumOptionsSheet(
                      context: context,
                      ref: ref,
                      album: currentAlbum,
                    ),
            ),
          ],
        ),
        body: detailAsync.when(
          data: (detail) {
            if (detail == null) {
              return loadFailed
                  ? MusicFlowErrorState(
                      title: loc.library_album_load_failed,
                      description: loc.library_album_load_failed_desc,
                      actionLabel: loc.widgets_retry,
                      onAction: _retry,
                    )
                  : MusicFlowEmptyState(
                      title: loc.library_album_not_found,
                      description: loc.library_album_not_found_desc,
                      icon: AppIcons.albumOutline,
                    );
            }

            final album = detail.album;
            final songs = sortSongs(detail.songs, _sortOption);
            final compact =
                MediaQuery.sizeOf(context).width <
                context.musicFlowBreakpoints.medium;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1400),
                child: CustomScrollView(
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: _AlbumIdentityHeader(
                        album: album,
                        songs: songs,
                        isNowPlaying: isNowPlaying,
                        onPlay: songs.isEmpty
                            ? null
                            : () => playEffectiveQueue(
                                ref,
                                songs,
                                origin: QueueOrigin(
                                  QueueOriginKind.album,
                                  widget.albumId,
                                ),
                              ),
                        onToggleStarred: () => _toggleStarred(album),
                      ),
                    ),
                    if (loadFailed)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            context.musicFlowSpacing.md,
                            context.musicFlowSpacing.md,
                            context.musicFlowSpacing.md,
                            0,
                          ),
                          child: MediaLoadNotice(
                            message: loc.library_network_cached_content,
                            onRetry: _retry,
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: MusicFlowSectionHeader(
                        title: loc.library_tracks,
                        description: songs.isEmpty
                            ? loc.library_album_no_tracks
                            : loc.library_track_count_sort('${songs.length}', _sortOption.label(loc)),
                        padding: EdgeInsets.fromLTRB(
                          context.musicFlowSpacing.md,
                          compact
                              ? context.musicFlowSpacing.sm
                              : context.musicFlowSpacing.lg,
                          context.musicFlowSpacing.md,
                          context.musicFlowSpacing.xs,
                        ),
                      ),
                    ),
                    if (songs.isEmpty)
                      SliverToBoxAdapter(
                        child: MusicFlowEmptyState(
                          title: loc.library_empty_tracks,
                          description: loc.library_empty_tracks_desc,
                          icon: AppIcons.music,
                          padding: EdgeInsets.all(32),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final song = songs[index];
                          return SongListItem(
                            song: song,
                            index: index,
                            variant: SongListItemVariant.albumTrack,
                            onTap: () => playEffectiveQueue(
                              ref,
                              songs,
                              startIndex: index,
                              origin: QueueOrigin(
                                QueueOriginKind.album,
                                widget.albumId,
                              ),
                            ),
                            onLongPress: () => showSongOptionsSheet(
                              context: context,
                              song: song,
                            ),
                          );
                        }, childCount: songs.length),
                      ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        key: const ValueKey<String>(
                          'album-detail-bottom-spacer',
                        ),
                        height:
                            context.musicFlowSpacing.xxl +
                            context.musicFlowShellBottomObstruction,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          loading: () => const MediaDetailLoadingView(),
          error: (error, stackTrace) => MusicFlowErrorState(
            title: loc.library_album_load_failed,
            description: loc.library_album_load_failed_desc,
            actionLabel: loc.widgets_retry,
            onAction: _retry,
          ),
        ),
      ),
    );
  }

  Future<void> _selectSortOption() async {
    final option = await showMediaSongSortSheet(
      context: context,
      current: _sortOption,
    );
    if (!mounted || option == null || option == _sortOption) return;
    setState(() => _sortOption = option);
  }

  void _retry() {
    ref.invalidate(albumDetailProvider(widget.albumId));
  }

  Future<void> _toggleStarred(Album album) async {
    final loc = AppLocalizations.of(context);
    final repository = ref.read(musicRepositoryProvider);
    if (repository == null) return;

    try {
      final nextStarred = !album.starred;
      await repository.setAlbumStarred(album.id, nextStarred);
      ref.invalidate(albumDetailProvider(widget.albumId));
      ref.invalidate(starredProvider);
      ref.invalidate(recentAlbumsProvider);
      ref.invalidate(frequentAlbumsProvider);
      if (mounted) {
        ToastNotifier.show(
          nextStarred ? loc.library_favorited_album : loc.library_unfavorited_album,
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (error) {
      if (mounted) {
        ToastNotifier.show(loc.library_operation_failed('$error'), kind: MusicFlowMessageKind.error);
      }
    }
  }
}

class _AlbumIdentityHeader extends StatelessWidget {
  const _AlbumIdentityHeader({
    required this.album,
    required this.songs,
    required this.onPlay,
    required this.onToggleStarred,
    this.isNowPlaying = false,
  });

  final Album album;
  final List<Song> songs;
  final VoidCallback? onPlay;
  final VoidCallback onToggleStarred;

  /// 该专辑是否正在播放：封面右下角叠加半透明遮罩 + 白色跳动竖条。
  final bool isNowPlaying;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MediaDetailHeaderSurface(
      coverArtId: album.coverArt,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < context.musicFlowBreakpoints.medium;
          final wide = constraints.maxWidth >= 680;
          final padding = compact
              ? EdgeInsets.symmetric(
                  horizontal: context.musicFlowSpacing.md,
                  vertical: context.musicFlowSpacing.sm,
                )
              : EdgeInsets.all(context.musicFlowSpacing.lg);

          if (compact) {
            final artwork = SizedBox.square(
              dimension: 112,
              child: MediaDetailArtwork(
                coverArtId: album.coverArt,
                semanticLabel: loc.discover_cover_semantics(album.name),
                heroTag: 'album-cover-${album.id}',
                requestSize: 480,
                isNowPlaying: isNowPlaying,
              ),
            );

            return Padding(
              padding: padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Center(child: artwork),
                  SizedBox(height: context.musicFlowSpacing.sm),
                  _AlbumInformation(
                    album: album,
                    songs: songs,
                    compact: true,
                    actions: _AlbumActions(
                      album: album,
                      onPlay: onPlay,
                      onToggleStarred: onToggleStarred,
                    ),
                  ),
                ],
              ),
            );
          }

          final artwork = ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: wide ? 280 : 260,
              maxHeight: wide ? 280 : 260,
            ),
            child: AspectRatio(
              aspectRatio: 1,
              child: MediaDetailArtwork(
                coverArtId: album.coverArt,
                semanticLabel: loc.discover_cover_semantics(album.name),
                heroTag: 'album-cover-${album.id}',
                isNowPlaying: isNowPlaying,
              ),
            ),
          );
          final information = _AlbumInformation(
            album: album,
            songs: songs,
            actions: _AlbumActions(
              album: album,
              onPlay: onPlay,
              onToggleStarred: onToggleStarred,
            ),
          );

          return Padding(
            padding: padding,
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      artwork,
                      SizedBox(width: context.musicFlowSpacing.xl),
                      Expanded(child: information),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Center(child: artwork),
                      SizedBox(height: context.musicFlowSpacing.lg),
                      information,
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _AlbumInformation extends StatelessWidget {
  const _AlbumInformation({
    required this.album,
    required this.songs,
    this.actions,
    this.compact = false,
  });

  final Album album;
  final List<Song> songs;
  final Widget? actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final artist = album.artist?.trim();
    final showFullText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final metadata = <String>[
      if (album.year != null) '${album.year}',
      if (album.genre?.trim().isNotEmpty == true) album.genre!.trim(),
      loc.discover_track_count(songs.length.toString()),
      album.durationString,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            album.name,
            maxLines: compact && !showFullText ? 2 : null,
            overflow: compact && !showFullText
                ? TextOverflow.ellipsis
                : TextOverflow.visible,
            style: compact
                ? context.musicFlowTypography.headline
                : context.musicFlowTypography.display,
          ),
        ),
        if (artist != null && artist.isNotEmpty) ...<Widget>[
          SizedBox(
            height: compact ? context.musicFlowSpacing.xxs : context.musicFlowSpacing.xs,
          ),
          Text(
            artist,
            maxLines: compact && !showFullText ? 2 : null,
            overflow: compact && !showFullText
                ? TextOverflow.ellipsis
                : TextOverflow.visible,
            style:
                (compact
                        ? context.musicFlowTypography.body.copyWith(
                            fontWeight: FontWeight.w500,
                          )
                        : context.musicFlowTypography.title)
                    .copyWith(color: context.musicFlowColors.muted),
          ),
        ],
        SizedBox(
          height: compact ? context.musicFlowSpacing.xs : context.musicFlowSpacing.sm,
        ),
        Wrap(
          spacing: context.musicFlowSpacing.xs,
          runSpacing: context.musicFlowSpacing.xxs,
          children: <Widget>[
            for (final item in metadata)
              Text(
                item,
                style: context.musicFlowTypography.metadata.copyWith(
                  color: context.musicFlowColors.muted,
                ),
              ),
          ],
        ),
        if (actions != null) ...<Widget>[
          SizedBox(
            height: compact ? context.musicFlowSpacing.sm : context.musicFlowSpacing.lg,
          ),
          actions!,
        ],
      ],
    );
  }
}

class _AlbumActions extends StatelessWidget {
  const _AlbumActions({
    required this.album,
    required this.onPlay,
    required this.onToggleStarred,
  });

  final Album album;
  final VoidCallback? onPlay;
  final VoidCallback onToggleStarred;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Wrap(
      spacing: context.musicFlowSpacing.xs,
      runSpacing: context.musicFlowSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        MusicFlowButton.primary(
          label: loc.library_play_all,
          leadingIcon: AppIcons.play,
          onPressed: onPlay,
        ),
        MusicFlowIconButton(
          icon: album.starred ? AppIcons.heart : AppIcons.heartOutline,
          label: album.starred ? loc.library_unfavorite_album : loc.library_favorite_album,
          selected: album.starred,
          onPressed: onToggleStarred,
        ),
      ],
    );
  }
}
