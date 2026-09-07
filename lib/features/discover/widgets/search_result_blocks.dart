import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/album_options_sheet.dart';
import 'package:musicflow_client/features/library/widgets/artist_options_sheet.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/features/library/widgets/playlist_options_sheet.dart';
import 'package:musicflow_client/features/player/widgets/song_options_sheet.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/features/search/search_scope.dart';
import 'package:musicflow_client/features/search/widgets/search_result_card.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 区块标题(本地结果 / 全网结果)。
class SearchBlockHeader extends StatelessWidget {
  const SearchBlockHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: context.musicFlowTypography.title.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: context.musicFlowTypography.metadata.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 分组小标题(歌单 / 歌曲 / 专辑 / 艺术家)+ 条数。
class SearchGroupHeader extends StatelessWidget {
  const SearchGroupHeader({required this.title, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.sm,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xxs,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: context.musicFlowTypography.label.copyWith(
                color: context.musicFlowColors.accent,
              ),
            ),
          ),
          if (count != null)
            Text(
              loc.search_items_count(count!),
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
        ],
      ),
    );
  }
}

/// 本地结果区块:按 歌单 → 歌曲 → 专辑 → 艺术家 分组堆叠。
class LocalResultsBlock extends ConsumerWidget {
  const LocalResultsBlock({required this.scope, required this.query});

  final SearchScope scope;
  final String query;

  bool _hasData(WidgetRef ref, SearchScope item) => switch (item) {
        SearchScope.song =>
          (ref.watch(localSongSearchProvider(query)).valueOrNull?.items ??
                  const <Song>[])
              .isNotEmpty,
        SearchScope.album =>
          (ref.watch(localAlbumSearchProvider(query)).valueOrNull?.items ??
                  const <Album>[])
              .isNotEmpty,
        SearchScope.artist =>
          (ref.watch(localArtistSearchProvider(query)).valueOrNull?.items ??
                  const <Artist>[])
              .isNotEmpty,
        SearchScope.playlist =>
          (ref.watch(localPlaylistSearchProvider(query)).valueOrNull?.items ??
                  const <Playlist>[])
              .isNotEmpty,
        SearchScope.all => false,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final scopes = scope.stackedScopes;
    final hasAny = scopes.any((item) => _hasData(ref, item));
    final isLoading = scopes.any((item) => _isLoading(ref, item));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SearchBlockHeader(
          title: loc.search_local_results,
          subtitle: loc.search_current_library,
        ),
        for (final item in scopes)
          KeyedSubtree(
            key: ValueKey<String>('local-group-${item.name}'),
            child: LocalSearchGroup(scope: item, query: query),
          ),
        if (!hasAny)
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowPageHorizontalPadding,
              isLoading ? 0 : context.musicFlowSpacing.xs,
              context.musicFlowPageHorizontalPadding,
              context.musicFlowSpacing.xs,
            ),
            child: isLoading
                ? const MusicFlowMediaListSkeleton(count: 3)
                : Text(
                    loc.search_local_no_results,
                    style: context.musicFlowTypography.metadata.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
          ),
      ],
    );
  }

  bool _isLoading(WidgetRef ref, SearchScope item) => switch (item) {
        SearchScope.song =>
          ref.watch(localSongSearchProvider(query)).isLoading,
        SearchScope.album =>
          ref.watch(localAlbumSearchProvider(query)).isLoading,
        SearchScope.artist =>
          ref.watch(localArtistSearchProvider(query)).isLoading,
        SearchScope.playlist =>
          ref.watch(localPlaylistSearchProvider(query)).isLoading,
        SearchScope.all => false,
      };
}

/// 单个本地分组(按类型渲染)。
class LocalSearchGroup extends ConsumerWidget {
  const LocalSearchGroup({required this.scope, required this.query});

  final SearchScope scope;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (scope) {
      SearchScope.song => _songs(context, ref),
      SearchScope.album => _albums(context, ref),
      SearchScope.artist => _artists(context, ref),
      SearchScope.playlist => _playlists(context, ref),
      SearchScope.all => const SizedBox.shrink(),
    };
  }

  Widget _songs(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final async = ref.watch(localSongSearchProvider(query));
    final songs = async.valueOrNull?.items ?? const <Song>[];
    if (songs.isEmpty) return const SizedBox.shrink();
    final currentSongId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SearchGroupHeader(title: loc.widgets_songs, count: async.valueOrNull?.total),
        for (var index = 0; index < songs.length; index++)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
            ),
            child: MusicFlowSongRow(
              song: songs[index],
              index: index,
              isCurrent: songs[index].id == currentSongId,
              onPressed: () =>
                  playEffectiveQueue(ref, songs, startIndex: index),
              onLongPress: () =>
                  showSongOptionsSheet(context: context, song: songs[index]),
              onMorePressed: () =>
                  showSongOptionsSheet(context: context, song: songs[index]),
            ),
          ),
      ],
    );
  }

  Widget _albums(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final async = ref.watch(localAlbumSearchProvider(query));
    final albums = async.valueOrNull?.items ?? const <Album>[];
    if (albums.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SearchGroupHeader(title: loc.widgets_albums, count: async.valueOrNull?.total),
        for (final album in albums)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
              vertical: context.musicFlowSpacing.xxs,
            ),
            child: MusicFlowAlbumRow(
              album: album,
              onPressed: () => Navigator.of(context).push<void>(
                MusicFlowPageRoute<void>(
                  context: context,
                  builder: (context) => AlbumDetailPage(albumId: album.id),
                ),
              ),
              onLongPress: () => showAlbumOptionsSheet(
                context: context,
                ref: ref,
                album: album,
              ),
            ),
          ),
      ],
    );
  }

  Widget _artists(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final async = ref.watch(localArtistSearchProvider(query));
    final artists = async.valueOrNull?.items ?? const <Artist>[];
    if (artists.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SearchGroupHeader(title: loc.widgets_artists, count: async.valueOrNull?.total),
        for (final artist in artists)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
              vertical: context.musicFlowSpacing.xxs,
            ),
            child: MusicFlowArtistRow(
              artist: artist,
              onPressed: () => Navigator.of(context).push<void>(
                MusicFlowPageRoute<void>(
                  context: context,
                  builder: (context) => ArtistDetailPage(artistId: artist.id),
                ),
              ),
              onLongPress: () => showArtistOptionsSheet(
                context: context,
                ref: ref,
                artist: artist,
              ),
            ),
          ),
      ],
    );
  }

  Widget _playlists(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final async = ref.watch(localPlaylistSearchProvider(query));
    final playlists = async.valueOrNull?.items ?? const <Playlist>[];
    if (playlists.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SearchGroupHeader(title: loc.widgets_playlists, count: async.valueOrNull?.total),
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.musicFlowPageHorizontalPadding,
            context.musicFlowSpacing.xs,
            context.musicFlowPageHorizontalPadding,
            0,
          ),
          child: Wrap(
            spacing: context.musicFlowSpacing.sm,
            runSpacing: context.musicFlowSpacing.sm,
            children: <Widget>[
              for (final playlist in playlists)
                DiscoverPlaylistCard(
                  width: 128,
                  title: playlist.name,
                  subtitle: loc.search_song_count('${playlist.songCount}'),
                  coverArtId: playlist.coverArt,
                  onPressed: () => Navigator.of(context).push<void>(
                    MusicFlowPageRoute<void>(
                      context: context,
                      builder: (context) => PlaylistDetailPage(
                        playlistId: playlist.id,
                        initialName: playlist.name,
                        initialSongCount: playlist.songCount,
                        initialCoverArt: playlist.coverArt,
                      ),
                    ),
                  ),
                  onLongPress: () => showPlaylistOptionsSheet(
                    context: context,
                    playlist: playlist,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 全网结果区块:已启用插件的合并搜索,按类型分组堆叠。
class NetworkResultsBlock extends ConsumerWidget {
  const NetworkResultsBlock({required this.scope, required this.query});

  final SearchScope scope;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final scopes = scope.stackedScopes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SearchBlockHeader(
          title: loc.search_network_results,
          subtitle: loc.search_network_results_subtitle,
        ),
        for (var i = 0; i < scopes.length; i++)
          KeyedSubtree(
            key: ValueKey<String>('network-group-${scopes[i].name}'),
            child: NetworkSearchGroup(
              scope: scopes[i],
              query: query,
              includeBottomPadding: i == scopes.length - 1,
            ),
          ),
      ],
    );
  }
}

class NetworkSearchGroup extends ConsumerWidget {
  const NetworkSearchGroup({
    required this.scope,
    required this.query,
    required this.includeBottomPadding,
  });

  final SearchScope scope;
  final String query;
  final bool includeBottomPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final kind = scope.kind;
    if (kind == null) return const SizedBox.shrink();
    final request = SearchRequest(
      kind: kind,
      mode: SearchMode.aggregate,
      query: query,
      providerId: '',
    );
    final async = ref.watch(searchResultsProvider(request));

    return async.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
        ),
        child: const MusicFlowMediaListSkeleton(count: 3),
      ),
      error: (error, stackTrace) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Text(
          loc.search_group_search_failed(scope.sectionTitle(loc)),
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.muted,
          ),
        ),
      ),
      data: (outcome) {
        if (outcome.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SearchGroupHeader(title: scope.sectionTitle(loc)),
            SearchResultList(
              kind: kind,
              outcome: outcome,
              includeBottomPadding: includeBottomPadding,
            ),
          ],
        );
      },
    );
  }
}
