import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/utils/cover_ref_security.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/search_repository.dart';
import '../../../features/library/widgets/library_collection_components.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../widgets/cover_art_image.dart';
import '../../../widgets/song_list_item.dart';

/// 远程平台艺术家预览页(对齐主项目前端 RemoteDetailDialog):
/// 点击搜索结果**不直接入库**,而是先拉取该艺术家歌曲预览,可「播放全部」直接播。
/// 歌曲行点击也是直接播放(stream-remote),不写入本地库。
class RemoteArtistPage extends ConsumerStatefulWidget {
  final SearchArtist artist;
  final String providerId;

  const RemoteArtistPage({
    super.key,
    required this.artist,
    required this.providerId,
  });

  @override
  ConsumerState<RemoteArtistPage> createState() => _RemoteArtistPageState();
}

class _RemoteArtistPageState extends ConsumerState<RemoteArtistPage> {
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
      SearchEntityKind.artist,
      widget.providerId,
      SearchSongLike(name: widget.artist.name),
    );
  }

  void _reload() => setState(() => _songsFuture = _loadSongs());

  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    await playEffectiveQueue(ref, songs, startIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    return EchoScaffold(
      topBar: EchoTopBar.back(context: context, title: artist.name),
      body: FutureBuilder<List<Song>>(
        future: _songsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const EchoMediaListSkeleton(count: 8);
          }
          if (snapshot.hasError) {
            return EchoErrorState(
              title: '加载失败',
              description: '拉取艺术家歌曲时出错,可重试。',
              actionLabel: '重试',
              onAction: () => _reload(),
            );
          }
          final songs = snapshot.data ?? [];
          return CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _Header(
                  artist: artist,
                  songCount: songs.length,
                  onPlayAll: () => _playAll(songs),
                ),
              ),
              if (songs.isEmpty)
                const SliverToBoxAdapter(
                  child: EchoEmptyState(
                    title: '没有可播放的歌曲',
                    description: '该平台艺术家暂时拉取不到歌曲。',
                    icon: AppIcons.profile,
                    padding: EdgeInsets.all(32),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = songs[index];
                      return SongListItem(
                        key: ValueKey<String>('remote-artist-song-${song.id}-$index'),
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
                  height: context.echoSpacing.xxl +
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
    required this.artist,
    required this.songCount,
    required this.onPlayAll,
  });

  final SearchArtist artist;
  final int songCount;
  final VoidCallback onPlayAll;

  @override
  Widget build(BuildContext context) {
    final cover = artist.avatar.isNotEmpty
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
            child: const Center(child: Icon(AppIcons.profile, size: 40)),
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
                      artist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.echoTypography.headline,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      <String>[
                        if (songCount > 0) '$songCount 首',
                        if (artist.platformLabel.isNotEmpty)
                          artist.platformLabel,
                      ].where((e) => e.isNotEmpty).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.echoTypography.metadata
                          .copyWith(color: context.echoColors.muted),
                    ),
                    const SizedBox(height: 14),
                    EchoButton.primary(
                      label: '播放全部',
                      leadingIcon: AppIcons.play,
                      onPressed: onPlayAll,
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
