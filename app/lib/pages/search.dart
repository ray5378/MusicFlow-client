import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../widgets/song_tile.dart';

/// 搜索页：全部走主项目聚合搜索（歌曲/专辑/艺术家三 Tab）+ 本地曲库辅助。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.api, required this.onPlayQueue, required this.onPlayRemote});

  final ApiClient api;
  final void Function(List<Song>, int) onPlayQueue;

  /// 播放在线聚合结果（/rest/stream-remote 直连）。
  final void Function(RemoteSong song) onPlayRemote;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;

  List<RemoteSong>? remoteSongs;
  List<Album>? remoteAlbums;
  List<Artist>? remoteArtists;
  List<Song>? localSongs;
  bool busy = false;
  String? error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        remoteSongs = null;
        remoteAlbums = null;
        remoteArtists = null;
        localSongs = null;
        busy = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q.trim()));
  }

  Future<void> _search(String q) async {
    setState(() {
      busy = true;
      error = null;
    });
    final results = await Future.wait<Object?>([
      widget.api.searchRemoteSongs(q).catchError((_) => <RemoteSong>[]),
      widget.api.searchRemoteAlbums(q).catchError((_) => <Album>[]),
      widget.api.searchRemoteArtists(q).catchError((_) => <Artist>[]),
      widget.api.songsPage(1, pageSize: 30, query: q).then((p) => p.items).catchError((_) => <Song>[]),
    ]);
    if (!mounted) return;
    setState(() {
      remoteSongs = results[0] as List<RemoteSong>;
      remoteAlbums = results[1] as List<Album>;
      remoteArtists = results[2] as List<Artist>;
      localSongs = results[3] as List<Song>;
      busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            decoration: const InputDecoration(
              hintText: '搜索歌曲 / 专辑 / 艺术家',
              border: InputBorder.none,
            ),
          ),
          bottom: const TabBar(
            tabs: [
              Tab(text: '歌曲'),
              Tab(text: '专辑'),
              Tab(text: '艺术家'),
              Tab(text: '我的曲库'),
            ],
          ),
        ),
        body: busy
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(child: Text('搜索失败：$error'))
                : TabBarView(
                    children: [
                      _buildSongs(),
                      _buildAlbums(),
                      _buildArtists(),
                      _buildLocal(),
                    ],
                  ),
      ),
    );
  }

  Widget _empty(String text) => Center(
        child: Text(_controller.text.trim().isEmpty ? '输入关键词开始搜索' : text,
            style: Theme.of(context).textTheme.bodyMedium),
      );

  Widget _buildSongs() {
    final list = remoteSongs;
    if (list == null) return _empty('');
    if (list.isEmpty) return _empty('没有匹配的歌曲');
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final s = list[i];
        final localEquiv = Song(
          id: 'remote:${s.providerId}:${s.source}:${s.id}',
          title: s.name,
          artist: [s.artist, if (s.platformLabel != null) '[${s.platformLabel}]'].whereType<String>().join(' · '),
          album: s.album,
          durationSeconds: s.durationSeconds,
          suffix: s.suffix,
        );
        return SongTile(
          api: widget.api,
          song: localEquiv.copyWith(),
          onPlay: () => widget.onPlayRemote(s),
        );
      },
    );
  }

  Widget _buildAlbums() {
    final list = remoteAlbums;
    if (list == null) return _empty('');
    if (list.isEmpty) return _empty('没有匹配的专辑');
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) => ListTile(
        leading: const Icon(Icons.album),
        title: Text(list[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(list[i].artist ?? ''),
        trailing: const Text('在线', style: TextStyle(fontSize: 11)),
        onTap: () {},
      ),
    );
  }

  Widget _buildArtists() {
    final list = remoteArtists;
    if (list == null) return _empty('');
    if (list.isEmpty) return _empty('没有匹配的艺术家');
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) => ListTile(
        leading: const Icon(Icons.person),
        title: Text(list[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () {},
      ),
    );
  }

  Widget _buildLocal() {
    final list = localSongs;
    if (list == null) return _empty('');
    if (list.isEmpty) return _empty('本地曲库没有匹配结果');
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: list.length,
      itemBuilder: (context, i) => SongTile(
        api: widget.api,
        song: list[i],
        onPlay: () => widget.onPlayQueue(list, i),
      ),
    );
  }
}
