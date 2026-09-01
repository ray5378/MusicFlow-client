import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/playlist.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/queue_origin_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/song_list_item.dart';
import '../../../widgets/cover_art_image.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../discover/widgets/discover_media_widgets.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../widgets/album_options_sheet.dart';
import '../widgets/artist_options_sheet.dart';
import '../widgets/library_collection_components.dart';
import '../widgets/playlist_options_sheet.dart';
import 'album_detail_page.dart';
import 'artist_detail_page.dart';
import 'playlist_detail_page.dart';

enum StarredTab { playlists, songs, albums, artists }

class StarredPage extends ConsumerWidget {
  const StarredPage({super.key, this.initialTab = StarredTab.playlists});

  final StarredTab initialTab;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(starredProvider);
    ref.invalidate(favoritePlaylistsProvider);
    await ref.read(starredProvider.future);
    await ref.read(favoritePlaylistsProvider.future);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starredAsync = ref.watch(starredProvider);
    final playlistsAsync = ref.watch(favoritePlaylistsProvider);
    final loadFailed = ref.watch(starredLoadFailedProvider);
    final playlistsLoadFailed = ref.watch(favoritePlaylistsLoadFailedProvider);
    final value = starredAsync.valueOrNull;
    final total = value == null
        ? null
        : value.songs.length +
              value.albums.length +
              value.artists.length +
              (playlistsAsync.valueOrNull?.length ?? 0);
    // 标题下方只显示收藏总数。
    final subtitleText = total == null ? null : '$total 项收藏';

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'starred_page',
      shouldRetry: (ref) =>
          loadFailed || playlistsLoadFailed || starredAsync.hasError,
      onRetry: (ref) {
        ref.invalidate(starredProvider);
        ref.invalidate(favoritePlaylistsProvider);
      },
      child: DefaultTabController(
        length: StarredTab.values.length,
        initialIndex: initialTab.index,
        child: Builder(
          builder: (tabContext) {
            final controller = DefaultTabController.of(tabContext);
            return MusicFlowScaffold(
              topBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  MusicFlowTopBar.back(
                    context: tabContext,
                    title: '收藏夹',
                    subtitle: subtitleText,
                  ),
                  _StarredTabStrip(controller: controller),
                  const MusicFlowDivider(),
                ],
              ),
              body: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: TabBarView(
                    controller: controller,
                    children: <Widget>[
                      _buildPlaylistsTab(context, ref),
                      _buildSongsTab(context, ref),
                      _buildAlbumsTab(context, ref),
                      _buildArtistsTab(context, ref),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPlaylistsTab(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(favoritePlaylistsProvider);
    final loadFailed = ref.watch(favoritePlaylistsLoadFailedProvider);

    return playlistsAsync.when(
      data: (playlists) {
        if (loadFailed && playlists.isEmpty) {
          return MusicFlowErrorState(
            title: '收藏歌单加载失败',
            description: '请检查网络或服务器状态后重试。',
            actionLabel: '重试',
            onAction: () => ref.invalidate(favoritePlaylistsProvider),
          );
        }
        if (playlists.isEmpty) {
          return _refreshableEmpty(
            context: context,
            ref: ref,
            title: '暂无收藏歌单',
            description: '在歌单卡片点亮红心后，会显示在这里。',
            icon: AppIcons.playlist,
          );
        }

        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final largeText = textScale >= 1.6;
        final content = largeText
            ? ListView.builder(
                key: const ValueKey<String>('starred-playlists-list-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: context.musicFlowSpacing.xxl +
                      context.musicFlowShellBottomObstruction,
                ),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final pl = playlists[index];
                  return DiscoverPlaylistTile(
                    playlist: pl,
                    onPressed: () => _openPlaylist(context, ref, pl.id),
                    onLongPress: () => showPlaylistOptionsSheet(
                      context: context,
                      playlist: pl,
                    ),
                  );
                },
              )
            : GridView.builder(
                key: const ValueKey<String>('starred-playlists-grid-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  context.musicFlowPageHorizontalPadding,
                  context.musicFlowSpacing.md,
                  context.musicFlowPageHorizontalPadding,
                  context.musicFlowSpacing.xxl +
                      context.musicFlowShellBottomObstruction,
                ),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisExtent: 220 + 76 * textScale,
                  crossAxisSpacing: context.musicFlowSpacing.sm,
                  mainAxisSpacing: context.musicFlowSpacing.md,
                ),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final pl = playlists[index];
                  return _StarredPlaylistTile(
                    playlist: pl,
                    onPressed: () => _openPlaylist(context, ref, pl.id),
                    onLongPress: () => showPlaylistOptionsSheet(
                      context: context,
                      playlist: pl,
                    ),
                  );
                },
              );

        return MusicFlowRefreshView(onRefresh: () => _refresh(ref), child: content);
      },
      loading: () => const MusicFlowAlbumGridSkeleton(count: 6),
      error: (error, stackTrace) => MusicFlowErrorState(
        title: '收藏歌单加载失败',
        description: '请检查网络或服务器状态后重试。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(favoritePlaylistsProvider),
      ),
    );
  }

  void _openPlaylist(BuildContext context, WidgetRef ref, String playlistId) {
    final pl = ref
        .read(favoritePlaylistsProvider)
        .valueOrNull
        ?.where((p) => p.id == playlistId)
        .firstOrNull;
    Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(
        context: context,
        builder: (context) => PlaylistDetailPage(
          playlistId: playlistId,
          initialName: pl?.name,
          initialSongCount: pl?.songCount,
          initialCoverArt: pl?.coverArt,
        ),
      ),
    );
  }

  Widget _buildSongsTab(BuildContext context, WidgetRef ref) {
    final starredAsync = ref.watch(starredProvider);
    return starredAsync.when(
      data: (starred) {
        final songs = starred.songs;
        if (songs.isEmpty) {
          return _refreshableEmpty(
            context: context,
            ref: ref,
            title: '暂无收藏歌曲',
            description: '在歌曲操作中点亮红心后，会显示在这里。',
            icon: AppIcons.heartOutline,
          );
        }

        return MusicFlowRefreshView(
          onRefresh: () => _refresh(ref),
          child: ListView.builder(
            key: const ValueKey<String>('starred-songs-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              bottom: context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
            ),
            itemCount: songs.length + 1,
            itemBuilder: (context, listIndex) {
              if (listIndex == 0) {
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    context.musicFlowPageHorizontalPadding,
                    context.musicFlowSpacing.sm,
                    context.musicFlowPageHorizontalPadding,
                    context.musicFlowSpacing.xs,
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: context.musicFlowSpacing.sm,
                    runSpacing: context.musicFlowSpacing.xs,
                    children: <Widget>[
                      Text(
                        '歌曲 (${songs.length})',
                        style: context.musicFlowTypography.headline,
                      ),
                      MusicFlowButton.ghost(
                        label: '播放全部',
                        leadingIcon: AppIcons.play,
                        onPressed: () => playEffectiveQueue(ref, songs),
                      ),
                    ],
                  ),
                );
              }

              final index = listIndex - 1;
              final song = songs[index];
              // 当前播放歌曲 id：识别正在播放的歌曲行（封面叠加跳动竖条）。
              final currentSongId = ref.watch(
                playerProvider.select((state) => state.currentSong?.id),
              );
              return SongListItem(
                song: song,
                index: index,
                variant: SongListItemVariant.standard,
                isCurrent: song.id == currentSongId,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: context.musicFlowPageHorizontalPadding,
                  vertical: context.musicFlowSpacing.xs,
                ),
                onTap: () => playEffectiveQueue(
                  ref,
                  songs,
                  startIndex: index,
                ),
                onLongPress: () =>
                    showSongOptionsSheet(context: context, song: song),
              );
            },
          ),
        );
      },
      loading: () => const MusicFlowMediaListSkeleton(count: 7),
      error: (error, stackTrace) => MusicFlowErrorState(
        title: '收藏加载失败',
        description: '请检查网络或服务器状态后重试。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(starredProvider),
      ),
    );
  }

  Widget _buildAlbumsTab(BuildContext context, WidgetRef ref) {
    // 当前播放来源：识别正在播放的专辑（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);
    final starredAsync = ref.watch(starredProvider);
    return starredAsync.when(
      data: (starred) {
        final albums = starred.albums;
        if (albums.isEmpty) {
          return _refreshableEmpty(
            context: context,
            ref: ref,
            title: '暂无收藏专辑',
            description: '长按专辑并点亮收藏后，会显示在这里。',
            icon: AppIcons.albumOutline,
          );
        }

        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final largeText = textScale >= 1.6;
        final content = largeText
            ? ListView.builder(
                key: const ValueKey<String>('starred-albums-list-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom:
                      context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
                ),
                itemCount: albums.length,
                itemBuilder: (context, index) {
                  final album = albums[index];
                  return MusicFlowAlbumRow(
                    album: album,
                    onPressed: () => _openAlbum(context, album.id),
                    onLongPress: () => showAlbumOptionsSheet(
                      context: context,
                      ref: ref,
                      album: album,
                    ),
                  );
                },
              )
            : GridView.builder(
                key: const ValueKey<String>('starred-albums-grid-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  context.musicFlowPageHorizontalPadding,
                  context.musicFlowSpacing.md,
                  context.musicFlowPageHorizontalPadding,
                  context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
                ),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisExtent: 220 + 76 * textScale,
                  crossAxisSpacing: context.musicFlowSpacing.sm,
                  mainAxisSpacing: context.musicFlowSpacing.md,
                ),
                itemCount: albums.length,
                itemBuilder: (context, index) {
                  final album = albums[index];
                  return MusicFlowAlbumTile(
                    album: album,
                    isNowPlaying: queueOrigin?.matchesAlbum(album.id) ??
                        false,
                    onPressed: () => _openAlbum(context, album.id),
                    onLongPress: () => showAlbumOptionsSheet(
                      context: context,
                      ref: ref,
                      album: album,
                    ),
                  );
                },
              );

        return MusicFlowRefreshView(
          onRefresh: () => _refresh(ref),
          child: content,
        );
      },
      loading: () => const MusicFlowAlbumGridSkeleton(count: 6),
      error: (error, stackTrace) => MusicFlowErrorState(
        title: '收藏加载失败',
        description: '请检查网络或服务器状态后重试。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(starredProvider),
      ),
    );
  }

  Widget _buildArtistsTab(BuildContext context, WidgetRef ref) {
    final starredAsync = ref.watch(starredProvider);
    return starredAsync.when(
      data: (starred) {
        final artists = starred.artists;
        if (artists.isEmpty) {
          return _refreshableEmpty(
            context: context,
            ref: ref,
            title: '暂无收藏歌手',
            description: '收藏的歌手会集中显示在这里。',
            icon: AppIcons.profile,
          );
        }

        return MusicFlowRefreshView(
          onRefresh: () => _refresh(ref),
          child: ListView.builder(
            key: const ValueKey<String>('starred-artists-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              bottom: context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
            ),
            itemCount: artists.length,
            itemBuilder: (context, index) {
              final artist = artists[index];
              return MusicFlowArtistRow(
                artist: artist,
                onPressed: () => Navigator.of(context).push<void>(
                  MusicFlowPageRoute<void>(
                    context: context,
                    builder: (_) => ArtistDetailPage(artistId: artist.id),
                  ),
                ),
                onLongPress: () => showArtistOptionsSheet(
                  context: context,
                  ref: ref,
                  artist: artist,
                ),
              );
            },
          ),
        );
      },
      loading: () => const MusicFlowMediaListSkeleton(count: 5),
      error: (error, stackTrace) => MusicFlowErrorState(
        title: '收藏加载失败',
        description: '请检查网络或服务器状态后重试。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(starredProvider),
      ),
    );
  }

  Widget _refreshableEmpty({
    required BuildContext context,
    required WidgetRef ref,
    required String title,
    required String description,
    required IconData icon,
  }) {
    return MusicFlowRefreshView(
      onRefresh: () => _refresh(ref),
      child: CustomScrollView(
        key: const ValueKey<String>('starred-empty-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: context.musicFlowShellBottomObstruction,
            ),
            sliver: SliverFillRemaining(
              hasScrollBody: false,
              child: MusicFlowEmptyState(
                title: title,
                description: description,
                icon: icon,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openAlbum(BuildContext context, String albumId) {
    Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(
        context: context,
        builder: (_) => AlbumDetailPage(albumId: albumId),
      ),
    );
  }
}

class _StarredTabStrip extends StatefulWidget {
  const _StarredTabStrip({required this.controller});

  final TabController controller;

  @override
  State<_StarredTabStrip> createState() => _StarredTabStripState();
}

class _StarredTabStripState extends State<_StarredTabStrip> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _StarredTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    const labels = <String>['歌单', '歌曲', '专辑', '歌手'];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        0,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.sm,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.musicFlowColors.raised,
          borderRadius: context.musicFlowRadii.control,
        ),
        child: Row(
          children: <Widget>[
            for (var index = 0; index < labels.length; index++)
              Expanded(
                child: MusicFlowPressable(
                  semanticLabel: '${labels[index]}收藏',
                  selected: widget.controller.index == index,
                  onPressed: () => widget.controller.animateTo(
                    index,
                    duration: context.musicFlowMotion.resolve(
                      context,
                      context.musicFlowMotion.state,
                    ),
                    curve: context.musicFlowMotion.easeOut,
                  ),
                  minimumSize: Size(
                    double.infinity,
                    context.musicFlowInteraction.minimumTouchTarget,
                  ),
                  borderRadius: context.musicFlowRadii.control,
                  child: Ink(
                    decoration: BoxDecoration(
                      color: widget.controller.index == index
                          ? context.musicFlowColors.accent.withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: context.musicFlowRadii.control,
                    ),
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.musicFlowSpacing.xs,
                        ),
                        child: Text(
                          labels[index],
                          style: context.musicFlowTypography.label.copyWith(
                            color: widget.controller.index == index
                                ? context.musicFlowColors.accent
                                : context.musicFlowColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「我喜欢 - 歌单」分区网格卡片：与 MusicFlowAlbumTile 布局对齐。
class _StarredPlaylistTile extends StatelessWidget {
  const _StarredPlaylistTile({
    required this.playlist,
    required this.onPressed,
    this.onLongPress,
  });

  final Playlist playlist;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return MusicFlowPressable(
      semanticLabel: '${playlist.name}，${playlist.songCount} 首，已收藏',
      onPressed: onPressed,
      onLongPress: onLongPress,
      minimumSize: const Size(96, 96),
      borderRadius: context.musicFlowRadii.control,
      child: Padding(
        padding: EdgeInsets.only(bottom: context.musicFlowSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: context.musicFlowRadii.control,
                    child: playlist.coverArt != null &&
                            playlist.coverArt!.isNotEmpty
                        ? CoverArtImage(
                            coverArtId: playlist.coverArt,
                            requestSize: 420,
                            fit: BoxFit.cover,
                            semanticLabel: '${playlist.name} 封面',
                          )
                        : Container(
                            color: context.musicFlowColors.surface,
                            child: Center(
                              child: Icon(
                                AppIcons.playlist,
                                size: 40,
                                color: context.musicFlowColors.accent,
                              ),
                            ),
                          ),
                  ),
                  PositionedDirectional(
                    start: context.musicFlowSpacing.xs,
                    bottom: context.musicFlowSpacing.xs,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.musicFlowColors.surface,
                        borderRadius: context.musicFlowRadii.pill,
                        border: Border.all(
                          color: context.musicFlowColors.controlBoundary,
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(context.musicFlowSpacing.xxs),
                        child: Icon(
                          AppIcons.heart,
                          size: 16,
                          color: context.musicFlowColors.error,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.musicFlowSpacing.xs),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.musicFlowTypography.title,
            ),
            SizedBox(height: context.musicFlowSpacing.xxs),
            Text(
              '${playlist.songCount} 首 · ${playlist.durationString}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
