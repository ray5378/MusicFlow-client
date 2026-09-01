import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/cover_ref_security.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/search_repository.dart';
import '../../../features/library/widgets/library_collection_components.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../widgets/cover_art_image.dart';
import '../../../widgets/song_list_item.dart';
import '../../search/search_actions.dart';

/// 远程平台专辑预览页(对齐主项目前端 RemoteDetailDialog):
/// 点击搜索结果**不直接入库**,而是先拉取专辑内歌曲预览,可「播放全部」直接播,
/// 「加入库」才走异步导入。歌曲行点击也是直接播放(stream-remote),不写入本地库。
class RemoteAlbumPage extends ConsumerStatefulWidget {
  final SearchAlbum album;
  final String providerId;

  const RemoteAlbumPage({
    super.key,
    required this.album,
    required this.providerId,
  });

  @override
  ConsumerState<RemoteAlbumPage> createState() => _RemoteAlbumPageState();
}

class _RemoteAlbumPageState extends ConsumerState<RemoteAlbumPage> {
  late Future<List<Song>> _songsFuture;

  @override
  void initState() {
    super.initState();
    _songsFuture = _loadSongs();
  }

  Future<List<Song>> _loadSongs() async {
    final repo = ref.read(searchRepositoryProvider);
    if (repo == null) return [];
    return repo.getCollectionSongs(
      SearchEntityKind.album,
      widget.providerId,
      SearchSongLike(id: widget.album.id, source: widget.album.source),
    );
  }

  void _reload() => setState(() => _songsFuture = _loadSongs());

  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    await playEffectiveQueue(ref, songs, startIndex: 0);
  }

  Future<void> _addToLibrary() async {
    await importSearchAlbum(context, ref, widget.album);
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: album.name),
      body: FutureBuilder<List<Song>>(
        future: _songsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const MusicFlowMediaListSkeleton(count: 8);
          }
          if (snapshot.hasError) {
            return MusicFlowErrorState(
              title: '加载失败',
              description: '拉取专辑歌曲时出错,可重试。',
              actionLabel: '重试',
              onAction: () => _reload(),
            );
          }
          final songs = snapshot.data ?? [];
          return CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _Header(
                  album: album,
                  songCount: songs.length,
                  onPlayAll: () => _playAll(songs),
                  onAddToLibrary: songs.isEmpty ? null : _addToLibrary,
                ),
              ),
              if (songs.isEmpty)
                const SliverToBoxAdapter(
                  child: MusicFlowEmptyState(
                    title: '没有可播放的歌曲',
                    description: '该平台专辑暂时拉取不到歌曲。',
                    icon: AppIcons.album,
                    padding: EdgeInsets.all(32),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = songs[index];
                      return SongListItem(
                        key: ValueKey<String>('remote-album-song-${song.id}-$index'),
                        song: song,
                        index: index,
                        variant: SongListItemVariant.standard,
                        isPreview: song.isPreview,
                        onTap: () => playEffectiveQueue(
                          ref,
                          songs,
                          startIndex: index,
                        ),
                      );
                    },
                    childCount: songs.length,
                  ),
                ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: context.musicFlowSpacing.xxl +
                      context.musicFlowShellBottomObstruction,
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
    required this.album,
    required this.songCount,
    required this.onPlayAll,
    required this.onAddToLibrary,
  });

  final SearchAlbum album;
  final int songCount;
  final VoidCallback onPlayAll;
  final VoidCallback? onAddToLibrary;

  @override
  Widget build(BuildContext context) {
    final cover = album.cover.isNotEmpty
        ? ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CoverArtImage(
              coverArtId: toCoverArtRef(album.cover) ?? '',
              size: 120,
              requestSize: 240,
              fit: BoxFit.cover,
            ),
          )
        : Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: context.musicFlowColors.surface,
            ),
            child: const Center(child: Icon(AppIcons.album, size: 40)),
          );

    return Padding(
      padding: EdgeInsets.all(context.musicFlowSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox.square(dimension: 120, child: cover),
              SizedBox(width: context.musicFlowSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      album.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.musicFlowTypography.headline,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      <String>[
                        if (album.artist.isNotEmpty) album.artist,
                        if (songCount > 0) '$songCount 首',
                        if (album.platformLabel.isNotEmpty) album.platformLabel,
                      ].where((e) => e.isNotEmpty).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.musicFlowTypography.metadata
                          .copyWith(color: context.musicFlowColors.muted),
                    ),
                    const SizedBox(height: 14),
                    // 与 MusicFlowMediaActions 同源的窄屏自适应:
                    // 容器宽 < 340 或字号 ≥20 → 双按钮垂直堆叠;
                    // 否则双按钮 Row 各 Expanded 一半,文字自动收缩显示全。
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final scaledLabelSize = MediaQuery.textScalerOf(
                          context,
                        ).scale(
                          context.musicFlowTypography.label.fontSize ?? 13,
                        );
                        final stackActions = constraints.maxWidth < 340 ||
                            scaledLabelSize >= 20;
                        final playAll = MusicFlowButton.primary(
                          label: '播放全部',
                          leadingIcon: AppIcons.play,
                          expand: true,
                          onPressed: onPlayAll,
                        );
                        final addToLib = MusicFlowButton.secondary(
                          label: '加入库',
                          leadingIcon: AppIcons.playlistAdd,
                          expand: true,
                          onPressed: onAddToLibrary,
                        );
                        if (stackActions) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              playAll,
                              SizedBox(height: context.musicFlowSpacing.xs),
                              addToLib,
                            ],
                          );
                        }
                        return Row(
                          children: <Widget>[
                              Expanded(child: playAll),
                              SizedBox(width: context.musicFlowSpacing.sm),
                              Expanded(child: addToLib),
                            ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: context.musicFlowSpacing.sm),
        ],
      ),
    );
  }
}
