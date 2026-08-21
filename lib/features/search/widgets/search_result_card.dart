import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:remixicon/remixicon.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/utils/cover_ref_security.dart';
import '../../../data/models/search.dart';
import '../../../data/repositories/search_repository.dart';
import '../../../widgets/cover_art_image.dart';
import '../../library/pages/remote_playlist_page.dart';
import '../search_actions.dart';

/// 远程搜索结果展示:按类目渲染歌曲/专辑/艺术家/歌单卡片,
/// 每个卡片支持「播放」与(适用时)「加入库」。
class SearchResultList extends ConsumerWidget {
  final SearchEntityKind kind;
  final SearchOutcome outcome;

  const SearchResultList({
    super.key,
    required this.kind,
    required this.outcome,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (kind) {
      case SearchEntityKind.song:
        return _songList(context, ref, outcome.songs);
      case SearchEntityKind.album:
        return _cardGrid(
          context,
          ref,
          outcome.albums
              .map((a) => _AlbumView(
                    album: a,
                    onPlay: () => playRemoteSearchCollection(
                      context,
                      ref,
                      SearchEntityKind.album,
                      a.providerId,
                      SearchSongLike(id: a.id, source: a.source),
                    ),
                    onImport: () => importSearchAlbum(context, ref, a),
                  ))
              .toList(),
        );
      case SearchEntityKind.artist:
        return _cardGrid(
          context,
          ref,
          outcome.artists
              .map((a) => _ArtistView(
                    artist: a,
                    onPlay: () => playRemoteSearchCollection(
                      context,
                      ref,
                      SearchEntityKind.artist,
                      a.providerId,
                      SearchSongLike(name: a.name),
                    ),
                  ))
              .toList(),
        );
      case SearchEntityKind.playlist:
        return _cardGrid(
          context,
          ref,
          outcome.playlists
              .map((p) => _PlaylistView(
                    playlist: p,
                    onPlay: () => playRemoteSearchCollection(
                      context,
                      ref,
                      SearchEntityKind.playlist,
                      p.providerId,
                      SearchSongLike(id: p.id, source: p.source),
                      playlist: p,
                    ),
                    onOpen: () => Navigator.of(context).push<void>(
                      EchoPageRoute<void>(
                        context: context,
                        builder: (_) => RemotePlaylistPage(
                          playlist: p,
                          providerId: p.providerId,
                        ),
                      ),
                    ),
                  ))
              .toList(),
        );
    }
  }

  Widget _songList(
    BuildContext context,
    WidgetRef ref,
    List<SearchSong> songs,
  ) {
    if (songs.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListView.separated(
      padding: EdgeInsets.only(
        left: context.echoPageHorizontalPadding,
        right: context.echoPageHorizontalPadding,
        bottom:
            context.echoSpacing.xxl + context.echoShellBottomObstruction,
      ),
      itemCount: songs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final s = songs[index];
        return ListTile(
          leading: s.cover.isNotEmpty
              ? _thumb(s.cover)
              : const Icon(AppIcons.music),
          title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [s.artist, s.platformLabel].where((e) => e.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                icon: const Icon(Remix.play_circle_line, size: 22),
                onPressed: () => playRemoteSearchSong(context, ref, s),
              ),
              IconButton(
                icon: const Icon(Remix.add_circle_line, size: 22),
                onPressed: () => importSearchSong(context, ref, s),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _cardGrid(
    BuildContext context,
    WidgetRef ref,
    List<Widget> children,
  ) {
    if (children.isEmpty) return const SizedBox.shrink();
    return GridView.count(
      crossAxisCount: 3,
      childAspectRatio: 0.8,
      padding: EdgeInsets.only(
        left: context.echoPageHorizontalPadding,
        right: context.echoPageHorizontalPadding,
        bottom:
            context.echoSpacing.xxl + context.echoShellBottomObstruction,
      ),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: children,
    );
  }

  Widget _thumb(String url) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CoverArtImage(
          coverArtId: tryToTrustedCoverUrlRef(url) ?? '',
          size: 48,
          requestSize: 96,
          fit: BoxFit.cover,
        ),
      );
}

class _AlbumView extends StatelessWidget {
  final SearchAlbum album;
  final VoidCallback onPlay;
  final VoidCallback onImport;
  const _AlbumView({
    required this.album,
    required this.onPlay,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              album.cover.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CoverArtImage(
                        coverArtId: tryToTrustedCoverUrlRef(album.cover) ?? '',
                        size: 120,
                        requestSize: 240,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: context.echoColors.surface,
                      ),
                      child: const Center(child: Icon(AppIcons.album)),
                    ),
              Positioned(
                right: 4,
                bottom: 4,
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Remix.play_circle_fill, size: 24),
                      color: context.echoColors.accent,
                      onPressed: onPlay,
                    ),
                    IconButton(
                      icon: const Icon(Remix.add_circle_line, size: 22),
                      onPressed: onImport,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(
          album.artist.isNotEmpty ? album.artist : album.platformLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.echoTypography.metadata
              .copyWith(color: context.echoColors.muted),
        ),
      ],
    );
  }
}

class _ArtistView extends StatelessWidget {
  final SearchArtist artist;
  final VoidCallback onPlay;
  const _ArtistView({required this.artist, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              artist.avatar.isNotEmpty
                  ? ClipOval(
                      child: CoverArtImage(
                        coverArtId: tryToTrustedCoverUrlRef(artist.avatar) ?? '',
                        size: 120,
                        requestSize: 240,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.echoColors.surface,
                      ),
                      child: const Center(child: Icon(AppIcons.profile)),
                    ),
              Positioned(
                right: 4,
                bottom: 4,
                child: IconButton(
                  icon: const Icon(Remix.play_circle_fill, size: 24),
                  color: context.echoColors.accent,
                  onPressed: onPlay,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(
          artist.platformLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.echoTypography.metadata
              .copyWith(color: context.echoColors.muted),
        ),
      ],
    );
  }
}

class _PlaylistView extends StatelessWidget {
  final SearchPlaylist playlist;
  final VoidCallback onPlay;
  final VoidCallback onOpen;
  const _PlaylistView({
    required this.playlist,
    required this.onPlay,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                playlist.cover.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CoverArtImage(
                          coverArtId:
                              tryToTrustedCoverUrlRef(playlist.cover) ?? '',
                          size: 120,
                          requestSize: 240,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: context.echoColors.surface,
                        ),
                        child: const Center(child: Icon(AppIcons.playlist)),
                      ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: IconButton(
                    icon: const Icon(Remix.play_circle_fill, size: 24),
                    color: context.echoColors.accent,
                    onPressed: onPlay,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            playlist.trackCount.isNotEmpty
                ? '${playlist.trackCount} 首'
                : playlist.platformLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.echoTypography.metadata
                .copyWith(color: context.echoColors.muted),
          ),
        ],
      ),
    );
  }
}
