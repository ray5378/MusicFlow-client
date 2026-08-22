import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../widgets/song_tile.dart';
import 'home.dart';

/// 曲库列表页（歌曲/专辑/艺术家/歌单/喜爱）：服务端分页滚动加载。
class LibraryListPage extends StatefulWidget {
  const LibraryListPage({
    super.key,
    required this.api,
    required this.target,
    required this.onPlayQueue,
  });

  final ApiClient api;
  final HomeTarget target;
  final void Function(List<Song>, int) onPlayQueue;

  @override
  State<LibraryListPage> createState() => _LibraryListPageState();
}

class _LibraryListPageState extends State<LibraryListPage> {
  final _controller = ScrollController();
  final _items = <Object?>[];
  int _page = 1;
  int _total = -1;
  bool _loading = false;
  String? _error;
  List<Song>? _starred;

  String get _title => switch (widget.target) {
        HomeTarget.artists => '艺术家',
        HomeTarget.albums => '专辑',
        HomeTarget.songs => '歌曲',
        HomeTarget.playlists => '歌单',
        HomeTarget.favorite => '喜爱的音乐',
      };

  bool get _hasMore => _total < 0 || _items.length < _total;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_controller.position.extentAfter < 400) _loadMore();
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.target == HomeTarget.favorite) {
        final starred = await widget.api.starredSongs();
        setState(() {
          _starred = starred;
          _total = starred.length;
        });
        return;
      }
      switch (widget.target) {
        case HomeTarget.songs:
          final p = await widget.api.songsPage(_page);
          setState(() {
            _items.addAll(p.items);
            _total = p.total;
          });
        case HomeTarget.albums:
          final p = await widget.api.albumsPage(_page);
          setState(() {
            _items.addAll(p.items);
            _total = p.total;
          });
        case HomeTarget.artists:
          final p = await widget.api.artistsPage(_page);
          setState(() {
            _items.addAll(p.items);
            _total = p.total;
          });
        case HomeTarget.playlists:
          final p = await widget.api.playlistsPage(_page);
          setState(() {
            _items.addAll(p.items);
            _total = p.total;
          });
        case HomeTarget.favorite:
          break;
      }
      _page++;
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.target == HomeTarget.favorite) {
      final starred = _starred;
      if (starred == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: starred.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text('$_title（${starred.length}）', style: Theme.of(context).textTheme.headlineSmall),
            );
          }
          final s = starred[i - 1];
          return SongTile(
            api: widget.api,
            song: s,
            onPlay: () => widget.onPlayQueue(starred, i - 1),
          );
        },
      );
    }

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                BackButton(onPressed: () => Navigator.of(context).maybePop()),
                Expanded(child: Text(_title, style: Theme.of(context).textTheme.headlineSmall)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                _items.clear();
                _page = 1;
                _total = -1;
                await _loadMore();
              },
              child: Stack(
                children: [
                  CustomScrollView(
                    controller: _controller,
                    slivers: [
                      SliverPadding(padding: const EdgeInsets.only(top: 4)),
                      SliverList.builder(
                        itemCount: _items.length,
                        itemBuilder: (context, i) {
                          final it = _items[i];
                          switch (it) {
                            case final Song s:
                              return SongTile(
                                api: widget.api,
                                song: s,
                                onPlay: () => widget.onPlayQueue(_items.whereType<Song>().toList(),
                                    _items.whereType<Song>().toList().indexOf(s)),
                              );
                            case final Album a:
                              return ListTile(
                                leading: const CircleAvatar(child: Icon(Icons.album)),
                                title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text([a.artist ?? '', if (a.year != null) '${a.year}'].join(' ').trim()),
                                onTap: () => Navigator.of(context).pushNamed('/album', arguments: a.id),
                              );
                            case final Artist ar:
                              return ListTile(
                                leading: const CircleAvatar(child: Icon(Icons.person)),
                                title: Text(ar.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                onTap: () => Navigator.of(context).pushNamed('/artist', arguments: ar.id),
                              );
                            case final Playlist pl:
                              return ListTile(
                                leading: const CircleAvatar(child: Icon(Icons.queue_music)),
                                title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: pl.songCount == null ? null : Text('歌曲数: ${pl.songCount}'),
                                onTap: () => Navigator.of(context).pushNamed('/playlist', arguments: pl.id),
                              );
                            default:
                              return const SizedBox.shrink();
                          }
                        },
                      ),
                      if (_loading)
                        const SliverToBoxAdapter(
                          child: Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                        ),
                      if (!_hasMore && _items.isNotEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(padding: EdgeInsets.all(20), child: Center(child: Text('没有更多了'))),
                        ),
                    ],
                  ),
                  if (_error != null && _items.isEmpty)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('加载失败：$_error'),
                          FilledButton.tonal(onPressed: _loadMore, child: const Text('重试')),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
