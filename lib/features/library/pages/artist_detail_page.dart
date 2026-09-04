import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/utils/toast_notifier.dart';
import '../../../data/models/album.dart';
import '../../../data/models/song.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/song_list_item.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../widgets/album_options_sheet.dart';
import '../widgets/media_detail_components.dart';
import 'album_detail_page.dart';

class ArtistDetailPage extends ConsumerStatefulWidget {
  const ArtistDetailPage({super.key, required this.artistId});

  final String artistId;

  @override
  ConsumerState<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends ConsumerState<ArtistDetailPage> {

  /// 当前播放歌曲 id：识别正在播放的歌曲行（封面叠加跳动竖条）。
  String? get _currentSongId => ref.watch(
    playerProvider.select((state) => state.currentSong?.id),
  );

  bool _isCurrentSong(String songId) => songId == _currentSongId;
  static const int _topSongsPreviewCount = 5;

  int _selectedSection = 0;
  bool _showAllTopSongs = false;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final detailAsync = ref.watch(artistDetailProvider(widget.artistId));
    final loadFailed = ref.watch(
      artistDetailLoadFailedProvider(widget.artistId),
    );
    final currentArtistName = detailAsync.valueOrNull?.artist.name;
    final topSongsLoadFailed = currentArtistName == null
        ? false
        : ref.watch(topSongsByArtistLoadFailedProvider(currentArtistName));

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'artist_detail_page',
      shouldRetry: (ref) =>
          loadFailed || detailAsync.hasError || topSongsLoadFailed,
      onRetry: (ref) {
        ref.invalidate(artistDetailProvider(widget.artistId));
        if (currentArtistName?.isNotEmpty == true) {
          ref.invalidate(topSongsByArtistProvider(currentArtistName!));
        }
      },
      child: MusicFlowScaffold(
        topBar: MusicFlowTopBar.back(
          context: context,
          title: loc.library_artist_title,
          actions: <Widget>[
            MusicFlowIconButton(
              icon: AppIcons.info,
              label: loc.library_artist_song_source,
              onPressed: _showSongSourceInfo,
            ),
          ],
        ),
        body: detailAsync.when(
          data: (detail) {
            if (detail == null) {
              return loadFailed
                  ? MusicFlowErrorState(
                      title: loc.library_artist_load_failed,
                      description: loc.library_artist_load_failed_desc,
                      actionLabel: loc.widgets_retry,
                      onAction: _retryArtist,
                    )
                  : MusicFlowEmptyState(
                      title: loc.library_artist_not_found,
                      description: loc.library_artist_not_found_desc,
                      icon: AppIcons.people,
                    );
            }

            final artist = detail.artist;
            final albums = detail.albums;
            final songs = detail.songs;
            final topSongsAsync = ref.watch(
              topSongsByArtistProvider(artist.name),
            );

            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1400),
                child: CustomScrollView(
                  key: PageStorageKey<String>(
                    _selectedSection == 0
                        ? 'artist-detail-songs'
                        : 'artist-detail-albums',
                  ),
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: _ArtistIdentityHeader(
                        artistName: artist.name,
                        coverArtId: artist.coverArt,
                        starred: artist.starred,
                        songCount: songs.length,
                        albumCount: albums.length,
                        onToggleStarred: () =>
                            _toggleArtistStarred(artist.id, artist.starred),
                        onPlay: songs.isEmpty
                            ? null
                            : () => playEffectiveQueue(ref, songs),
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
                            onRetry: _retryArtist,
                          ),
                        ),
                      ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _ArtistSectionHeaderDelegate(
                        selectedIndex: _selectedSection,
                        onSelected: (index) {
                          if (index == _selectedSection) return;
                          setState(() => _selectedSection = index);
                        },
                      ),
                    ),
                    if (_selectedSection == 0)
                      ..._buildSongSlivers(artist.name, songs, topSongsAsync)
                    else
                      ..._buildAlbumSlivers(albums),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        key: const ValueKey<String>(
                          'artist-detail-bottom-spacer',
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
          loading: () => const MediaDetailLoadingView(circularArtwork: true),
          error: (error, stackTrace) => MusicFlowErrorState(
            title: loc.library_artist_load_failed,
            description: loc.library_artist_load_failed_desc,
            actionLabel: loc.widgets_retry,
            onAction: _retryArtist,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSongSlivers(
    String artistName,
    List<Song> songs,
    AsyncValue<List<Song>> topSongsAsync,
  ) {
    final loc = AppLocalizations.of(context);
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: topSongsAsync.when(
          data: (topSongs) {
            if (topSongs.isEmpty) return const SizedBox.shrink();
            final visibleSongs = _showAllTopSongs
                ? topSongs
                : topSongs.take(_topSongsPreviewCount).toList();
            return Padding(
              padding: EdgeInsets.fromLTRB(
                context.musicFlowSpacing.md,
                context.musicFlowSpacing.lg,
                context.musicFlowSpacing.md,
                context.musicFlowSpacing.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  MusicFlowSectionHeader(
                    title: loc.library_top_songs,
                    description: loc.library_top_songs_count('${topSongs.length}'),
                    actionLabel: topSongs.length > _topSongsPreviewCount
                        ? (_showAllTopSongs ? loc.action_collapse : loc.action_show_all)
                        : null,
                    onAction: () {
                      setState(() => _showAllTopSongs = !_showAllTopSongs);
                    },
                  ),
                  SizedBox(height: context.musicFlowSpacing.xs),
                  for (var index = 0; index < visibleSongs.length; index++)
                    _buildTopSongRow(index, visibleSongs[index], topSongs),
                ],
              ),
            );
          },
          loading: () => const _TopSongsSkeleton(),
          error: (error, stackTrace) => Padding(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.md,
              0,
            ),
            child: MediaLoadNotice(
              message: loc.library_top_songs_unavailable,
              onRetry: () =>
                  ref.invalidate(topSongsByArtistProvider(artistName)),
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: MusicFlowSectionHeader(
          title: loc.library_all_songs,
          description: songs.isEmpty ? loc.library_no_playable_songs : loc.library_song_count('${songs.length}'),
          actionLabel: songs.isEmpty ? null : loc.library_play_all,
          onAction: songs.isEmpty
              ? null
              : () => playEffectiveQueue(ref, songs),
          padding: EdgeInsets.fromLTRB(
            context.musicFlowSpacing.md,
            context.musicFlowSpacing.lg,
            context.musicFlowSpacing.md,
            context.musicFlowSpacing.xs,
          ),
        ),
      ),
    ];

    if (songs.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: MusicFlowEmptyState(
            title: loc.library_no_songs,
            description: loc.library_artist_no_songs,
            icon: AppIcons.music,
            padding: EdgeInsets.all(32),
          ),
        ),
      );
    } else {
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final song = songs[index];
            return _buildSongRow(index, song, songs);
          }, childCount: songs.length),
        ),
      );
    }
    return slivers;
  }

  Widget _buildTopSongRow(int index, Song song, List<Song> topSongs) {
    return SongListItem(
      song: song,
      index: index,
      variant: SongListItemVariant.standard,
      isCurrent: _isCurrentSong(song.id),
      contentPadding: EdgeInsets.symmetric(
        vertical: context.musicFlowSpacing.xs,
      ),
      onTap: () {
        final queueIndex = topSongs.indexWhere((s) => s.id == song.id);
        playEffectiveQueue(
          ref,
          topSongs,
          startIndex: queueIndex < 0 ? index : queueIndex,
        );
      },
      onLongPress: () => showSongOptionsSheet(context: context, song: song),
    );
  }

  Widget _buildSongRow(int index, Song song, List<Song> songs) {
    return SongListItem(
      song: song,
      index: index,
      variant: SongListItemVariant.standard,
      isCurrent: _isCurrentSong(song.id),
      onTap: () => playEffectiveQueue(
        ref,
        songs,
        startIndex: index,
      ),
      onLongPress: () =>
          showSongOptionsSheet(context: context, song: song),
    );
  }

  List<Widget> _buildAlbumSlivers(List<Album> albums) {
    final loc = AppLocalizations.of(context);
    if (albums.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: MusicFlowEmptyState(
            title: loc.library_no_albums,
            description: loc.library_artist_no_albums,
            icon: AppIcons.albumOutline,
          ),
        ),
      ];
    }

    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final useList = MediaQuery.sizeOf(context).width < 520 || textScale > 1.5;
    if (useList) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            context.musicFlowSpacing.md,
            context.musicFlowSpacing.lg,
            context.musicFlowSpacing.md,
            0,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final album = albums[index];
              return Padding(
                padding: EdgeInsets.only(bottom: context.musicFlowSpacing.sm),
                child: _ArtistAlbumRow(
                  album: album,
                  onPressed: () => _openAlbum(album),
                  onLongPress: () => showAlbumOptionsSheet(
                    context: context,
                    ref: ref,
                    album: album,
                  ),
                ),
              );
            }, childCount: albums.length),
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.musicFlowSpacing.md,
          context.musicFlowSpacing.lg,
          context.musicFlowSpacing.md,
          0,
        ),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisExtent: 286,
            crossAxisSpacing: 16,
            mainAxisSpacing: 20,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final album = albums[index];
            return MediaDetailAlbumTile(
              album: album,
              onPressed: () => _openAlbum(album),
              onLongPress: () => showAlbumOptionsSheet(
                context: context,
                ref: ref,
                album: album,
              ),
            );
          }, childCount: albums.length),
        ),
      ),
    ];
  }

  void _openAlbum(Album album) {
    Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(
        context: context,
        builder: (context) => AlbumDetailPage(albumId: album.id),
      ),
    );
  }

  void _retryArtist() {
    ref.invalidate(artistDetailProvider(widget.artistId));
  }

  Future<void> _toggleArtistStarred(
    String artistId,
    bool currentStarred,
  ) async {
    final loc = AppLocalizations.of(context);
    final repository = ref.read(musicRepositoryProvider);
    if (repository == null) return;
    final nextStarred = !currentStarred;

    try {
      await repository.setArtistStarred(artistId, nextStarred);
      ref.invalidate(artistDetailProvider(artistId));
      ref.invalidate(allArtistsProvider);
      ref.invalidate(starredProvider);
      if (mounted) {
        ToastNotifier.show(
          nextStarred ? loc.library_favorited_artist : loc.library_unfavorited_artist,
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (error) {
      if (mounted) {
        ToastNotifier.show(loc.library_operation_failed('$error'), kind: MusicFlowMessageKind.error);
      }
    }
  }

  Future<void> _showSongSourceInfo() {
    final loc = AppLocalizations.of(context);
    return showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.library_artist_song_source,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                loc.library_artist_song_source_desc,
                style: sheetContext.musicFlowTypography.body,
              ),
              SizedBox(height: sheetContext.musicFlowSpacing.lg),
              MusicFlowButton.secondary(
                label: loc.library_got_it,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistIdentityHeader extends StatelessWidget {
  const _ArtistIdentityHeader({
    required this.artistName,
    required this.coverArtId,
    required this.starred,
    required this.songCount,
    required this.albumCount,
    required this.onToggleStarred,
    required this.onPlay,
  });

  final String artistName;
  final String? coverArtId;
  final bool starred;
  final int songCount;
  final int albumCount;
  final VoidCallback onToggleStarred;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MediaDetailHeaderSurface(
      coverArtId: coverArtId,
      child: Padding(
        padding: EdgeInsets.all(context.musicFlowSpacing.lg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 680;
            final portrait = SizedBox.square(
              dimension: wide ? 200 : 160,
              child: MediaDetailArtwork(
                coverArtId: coverArtId,
                semanticLabel: loc.library_artist_photo(artistName),
                heroTag: 'artist-cover-$artistName',
                circular: true,
                requestSize: 480,
              ),
            );
            final information = Column(
              crossAxisAlignment: wide
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    artistName,
                    textAlign: wide ? TextAlign.start : TextAlign.center,
                    style: context.musicFlowTypography.display,
                  ),
                ),
                SizedBox(height: context.musicFlowSpacing.sm),
                Text(
                  loc.library_artist_counts('$songCount', '$albumCount'),
                  textAlign: wide ? TextAlign.start : TextAlign.center,
                  style: context.musicFlowTypography.body.copyWith(
                    color: context.musicFlowColors.muted,
                  ),
                ),
                SizedBox(height: context.musicFlowSpacing.lg),
                Wrap(
                  alignment: wide ? WrapAlignment.start : WrapAlignment.center,
                  spacing: context.musicFlowSpacing.xs,
                  runSpacing: context.musicFlowSpacing.xs,
                  children: <Widget>[
                    MusicFlowButton.primary(
                      label: loc.library_play_songs,
                      leadingIcon: AppIcons.play,
                      onPressed: onPlay,
                    ),
                    MusicFlowIconButton(
                      icon: starred ? AppIcons.heart : AppIcons.heartOutline,
                      label: starred ? loc.library_unfavorite_artist : loc.library_favorite_artist,
                      selected: starred,
                      onPressed: onToggleStarred,
                    ),
                  ],
                ),
              ],
            );

            if (!wide) {
              return Column(
                children: <Widget>[
                  portrait,
                  SizedBox(height: context.musicFlowSpacing.lg),
                  information,
                ],
              );
            }
            return Row(
              children: <Widget>[
                portrait,
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

class _ArtistSectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  _ArtistSectionHeaderDelegate({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  double get minExtent => 64;

  @override
  double get maxExtent => 64;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final loc = AppLocalizations.of(context);
    return MediaDetailSectionSwitcher(
      labels: <String>[loc.library_songs, loc.library_albums],
      selectedIndex: selectedIndex,
      onSelected: onSelected,
    );
  }

  @override
  bool shouldRebuild(_ArtistSectionHeaderDelegate oldDelegate) {
    return selectedIndex != oldDelegate.selectedIndex ||
        onSelected != oldDelegate.onSelected;
  }
}

class _ArtistAlbumRow extends StatelessWidget {
  const _ArtistAlbumRow({
    required this.album,
    required this.onPressed,
    required this.onLongPress,
  });

  final Album album;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MusicFlowPressable(
      semanticLabel: loc.library_album_count_semantics(album.name, '${album.songCount}'),
      onPressed: onPressed,
      onLongPress: onLongPress,
      minimumSize: const Size(double.infinity, 104),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: 88,
              child: MediaDetailArtwork(
                coverArtId: album.coverArt,
                semanticLabel: loc.library_album_cover(album.name),
                heroTag: 'album-cover-${album.id}',
                requestSize: 320,
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(album.name, style: context.musicFlowTypography.title),
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(
                    <String>[
                      if (album.year != null) '${album.year}',
                      loc.library_song_count('${album.songCount}'),
                    ].join(' · '),
                    style: context.musicFlowTypography.body.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.xs),
            Icon(
              AppIcons.chevronRight,
              color: context.musicFlowColors.muted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _TopSongsSkeleton extends StatelessWidget {
  const _TopSongsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(context.musicFlowSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const MusicFlowSkeleton.line(width: 160, height: 24),
          SizedBox(height: context.musicFlowSpacing.md),
          for (var index = 0; index < 3; index++) ...<Widget>[
            Row(
              children: <Widget>[
                const MusicFlowSkeleton.circle(),
                SizedBox(width: context.musicFlowSpacing.sm),
                const Expanded(child: MusicFlowSkeleton.line(height: 18)),
              ],
            ),
            SizedBox(height: context.musicFlowSpacing.sm),
          ],
        ],
      ),
    );
  }
}
