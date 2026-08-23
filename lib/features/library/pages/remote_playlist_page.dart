import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/utils/cover_ref_security.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../features/library/widgets/library_collection_components.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../widgets/cover_art_image.dart';
import '../../../widgets/song_list_item.dart';
import '../../search/search_actions.dart';

/// 远程平台歌单预览页(对齐主项目前端 RemoteDetailDialog):
/// 点击搜索结果**不直接入库**,而是先拉取歌单内歌曲预览,可「播放全部」直接播,
/// 「加入库」才走异步导入。歌曲行点击也是直接播放(stream-remote),不写入本地库。
class RemotePlaylistPage extends ConsumerStatefulWidget {
  final SearchPlaylist playlist;
  final String providerId;

  const RemotePlaylistPage({
    super.key,
    required this.playlist,
    required this.providerId,
  });

  @override
  ConsumerState<RemotePlaylistPage> createState() => _RemotePlaylistPageState();
}

class _RemotePlaylistPageState extends ConsumerState<RemotePlaylistPage> {
  late Future<List<Song>> _songsFuture;

  @override
  void initState() {
    super.initState();
    _songsFuture = _loadSongs();
  }

  Future<List<Song>> _loadSongs() async {
    final repo = ref.read(searchRepositoryProvider);
    if (repo == null) return [];
    return repo.getPlaylistSongs(widget.providerId, widget.playlist);
  }

  void _reload() => setState(() => _songsFuture = _loadSongs());

  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    await playEffectiveQueue(ref, songs, startIndex: 0);
  }

  Future<void> _addToLibrary() async {
    await importSearchPlaylist(context, ref, widget.playlist);
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    return EchoScaffold(
      topBar: EchoTopBar.back(context: context, title: playlist.name),
      body: FutureBuilder<List<Song>>(
        future: _songsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const EchoMediaListSkeleton(count: 8);
          }
          if (snapshot.hasError) {
            return EchoErrorState(
              title: '加载失败',
              description: '拉取歌单歌曲时出错,可重试。',
              actionLabel: '重试',
              onAction: _reload,
            );
          }
          final songs = snapshot.data ?? [];
          return CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _Header(
                  playlist: playlist,
                  songCount: songs.length,
                  onPlayAll: () => _playAll(songs),
                  onAddToLibrary: songs.isEmpty ? null : _addToLibrary,
                ),
              ),
              if (songs.isEmpty)
                const SliverToBoxAdapter(
                  child: EchoEmptyState(
                    title: '没有可播放的歌曲',
                    description: '该平台歌单暂时拉取不到歌曲。',
                    icon: AppIcons.playlist,
                    padding: EdgeInsets.all(32),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final song = songs[index];
                    return SongListItem(
                      key: ValueKey<String>('remote-song-${song.id}-$index'),
                      song: song,
                      index: index,
                      variant: SongListItemVariant.standard,
                      isPreview: song.isPreview,
                      onTap: () =>
                          playEffectiveQueue(ref, songs, startIndex: index),
                    );
                  }, childCount: songs.length),
                ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height:
                      context.echoSpacing.xxl +
                      context.echoShellBottomObstruction,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.playlist,
    required this.songCount,
    required this.onPlayAll,
    required this.onAddToLibrary,
  });

  final SearchPlaylist playlist;
  final int songCount;
  final VoidCallback onPlayAll;
  final VoidCallback? onAddToLibrary;

  @override
  Widget build(BuildContext context) {
    final cover = playlist.cover.isNotEmpty
        ? ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CoverArtImage(
              coverArtId: tryToTrustedCoverUrlRef(playlist.cover) ?? '',
              size: 120,
              requestSize: 240,
              fit: BoxFit.cover,
            ),
          )
        : Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: context.echoColors.surface,
            ),
            child: const Center(child: Icon(AppIcons.playlist, size: 40)),
          );

    return Padding(
      padding: EdgeInsets.all(context.echoSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox.square(dimension: 120, child: cover),
              SizedBox(width: context.echoSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.echoTypography.headline,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      <String>[
                        if (playlist.trackCount.isNotEmpty)
                          '${playlist.trackCount} 首'
                        else if (songCount > 0)
                          '$songCount 首',
                        if (playlist.platformLabel.isNotEmpty)
                          playlist.platformLabel,
                      ].where((e) => e.isNotEmpty).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.echoTypography.metadata.copyWith(
                        color: context.echoColors.muted,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        EchoButton.primary(
                          label: '播放全部',
                          leadingIcon: AppIcons.play,
                          onPressed: onPlayAll,
                        ),
                        SizedBox(width: context.echoSpacing.sm),
                        EchoButton.secondary(
                          label: '加入库',
                          leadingIcon: AppIcons.playlistAdd,
                          onPressed: onAddToLibrary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: context.echoSpacing.sm),
        ],
      ),
    );
  }
}
