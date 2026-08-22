import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../widgets/cover.dart';
import '../widgets/song_tile.dart';

/// 专辑详情 / 艺术家详情 / 歌单详情。
class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({super.key, required this.api, required this.albumId, required this.onPlayQueue});

  final ApiClient api;
  final String albumId;
  final void Function(List<Song>, int) onPlayQueue;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  late final Future<(Album?, List<Song>)> _future = widget.api.albumDetail(widget.albumId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<(Album?, List<Song>)>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final (album, songs) = snap.data!;
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 200,
                title: Text(album?.name ?? '专辑'),
                flexibleSpace: FlexibleSpaceBar(
                  background: Center(
                    child: coverOf(widget.api, album?.coverArt, size: 140, radius: 14),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.tonalIcon(
                    onPressed: songs.isEmpty ? null : () => widget.onPlayQueue(songs, 0),
                    icon: const Icon(Icons.play_arrow),
                    label: Text('播放全部（${songs.length}）'),
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: songs.length,
                itemBuilder: (context, i) => SongTile(
                  api: widget.api,
                  song: songs[i],
                  onPlay: () => widget.onPlayQueue(songs, i),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
            ],
          );
        },
      ),
    );
  }
}

class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({super.key, required this.api, required this.artistId, required this.onOpenAlbum});

  final ApiClient api;
  final String artistId;
  final void Function(String albumId) onOpenAlbum;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  late final Future<List<Album>> _future = widget.api.artistAlbums(widget.artistId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('艺术家')),
      body: FutureBuilder<List<Album>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final albums = snap.data!;
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.82,
            ),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final a = albums[i];
              return InkWell(
                onTap: () => widget.onOpenAlbum(a.id),
                child: Column(
                  children: [
                    Expanded(child: coverOf(widget.api, a.coverArt, size: 160, radius: 12)),
                    const SizedBox(height: 6),
                    Text(a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.api, required this.playlistId, required this.onPlayQueue});

  final ApiClient api;
  final String playlistId;
  final void Function(List<Song>, int) onPlayQueue;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  late final Future<List<Song>> _future = widget.api.playlistTracks(widget.playlistId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('歌单')),
      body: FutureBuilder<List<Song>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final songs = snap.data!;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('共 ${songs.length} 首', style: Theme.of(context).textTheme.bodyMedium),
                    ),
                    FilledButton.icon(
                      onPressed: songs.isEmpty ? null : () => widget.onPlayQueue(songs, 0),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('播放全部'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: songs.length,
                  itemBuilder: (context, i) => SongTile(
                    api: widget.api,
                    song: songs[i],
                    onPlay: () => widget.onPlayQueue(songs, i),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
