import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../widgets/media_card.dart';
import '../widgets/song_tile.dart';

/// 首页：分类入口 + 随机歌曲 + 最近更新的歌单。
/// 窄屏列表 / 宽屏网格（对齐 windowsui.png）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api, required this.onPlayQueue, required this.onOpen});

  final ApiClient api;
  final void Function(List<Song> songs, int startIndex) onPlayQueue;
  final void Function(HomeTarget target) onOpen;

  @override
  State<HomePage> createState() => _HomePageState();
}

enum HomeTarget { artists, albums, songs, playlists, favorite }

class _HomePageState extends State<HomePage> {
  late Future<List<Song>> _random = widget.api.randomSongs(size: 12);
  late Future<List<Playlist>> _playlists = widget.api
      .playlistsPage(1)
      .then((p) => p.items);

  Future<void> _refresh() async {
    setState(() {
      _random = widget.api.randomSongs(size: 12);
      _playlists = widget.api.playlistsPage(1).then((p) => p.items);
    });
    await Future.wait([_random.catchError((_) => <Song>[]), _playlists.catchError((_) => <Playlist>[])]);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Row(
            children: [
              Expanded(child: Text('MusicFlow', style: tt.displaySmall)),
              IconButton(
                tooltip: '搜索',
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.of(context).pushNamed('/search'),
              ),
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).pushNamed('/settings'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 分类入口行（对齐箭头音乐五宫格）。
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final (target, icon, label) in const <(HomeTarget, IconData, String)>[
                (HomeTarget.artists, Icons.mic_none, '艺术家'),
                (HomeTarget.albums, Icons.album_outlined, '专辑'),
                (HomeTarget.songs, Icons.music_note_outlined, '歌曲'),
                (HomeTarget.playlists, Icons.queue_music_outlined, '歌单'),
                (HomeTarget.favorite, Icons.favorite_border, '喜爱'),
              ])
                InkWell(
                  onTap: () => widget.onOpen(target),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                      width: 64,
                      child: Column(
                        children: [
                          Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(height: 6),
                          Text(label, style: tt.labelMedium),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionHeader(title: '随机歌曲', onRefresh: _refresh),
          FutureBuilder<List<Song>>(
            future: _random,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
              }
              if (snap.hasError || (snap.data?.isEmpty ?? true)) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('暂无可播放的歌曲')),
                );
              }
              final songs = snap.data!;
              if (wide) return _RandomGrid(api: widget.api, songs: songs, onPlayQueue: widget.onPlayQueue);
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < songs.length; i++)
                      SongTile(
                        api: widget.api,
                        song: songs[i],
                        onPlay: () => widget.onPlayQueue(songs, i),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          _SectionHeader(title: '最近更新的歌单', onRefresh: _refresh),
          FutureBuilder<List<Playlist>>(
            future: _playlists,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
              }
              final list = snap.data ?? [];
              if (list.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('暂无歌单')));
              return SizedBox(
                height: 190,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final pl = list[i];
                    return MediaCard(
                      coverUrl: widget.api.coverUrl(pl.coverArt, size: 300),
                      title: pl.name,
                      subtitle: '歌曲数: ${pl.songCount ?? '-'}',
                      onTap: () => Navigator.of(context)
                          .pushNamed('/playlist', arguments: pl.id),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onRefresh});

  final String title;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const Spacer(),
        IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: onRefresh),
      ],
    );
  }
}

/// 随机歌曲网格（桌面端）：两列一组、多组横排，对齐 windowsui.png 的 3~4 列布局。
class _RandomGrid extends StatelessWidget {
  const _RandomGrid({required this.api, required this.songs, required this.onPlayQueue});

  final ApiClient api;
  final List<Song> songs;
  final void Function(List<Song>, int) onPlayQueue;

  @override
  Widget build(BuildContext context) {
    const rowsPerCol = 3;
    final cols = (songs.length / rowsPerCol).ceil();
    return SizedBox(
      height: rowsPerCol * 68 + 8,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        itemCount: cols,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, c) => SizedBox(
          width: 360,
          child: Column(
            children: [
              for (var r = 0; r < rowsPerCol && c * rowsPerCol + r < songs.length; r++)
                SongTile(
                  api: api,
                  song: songs[c * rowsPerCol + r],
                  onPlay: () => onPlayQueue(songs, c * rowsPerCol + r),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
