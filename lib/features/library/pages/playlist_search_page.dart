import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../features/discover/widgets/discover_media_widgets.dart';
import '../../../features/library/widgets/windowed_list_view.dart';
import '../../../features/library/widgets/windowed_paginated_list.dart';
import '../../../features/search/widgets/aggregate_search_results.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../library/pages/playlist_detail_page.dart';
import '../../../widgets/visible_remote_retry_scope.dart';

/// 歌单类目 —— 窗口化分页列表(本地歌单走 /v1/playlists 分页;
/// 聚合/插件搜索不变,远程歌单先入库再打开)。
class PlaylistSearchPage extends ConsumerStatefulWidget {
  const PlaylistSearchPage({super.key});

  @override
  ConsumerState<PlaylistSearchPage> createState() => _PlaylistSearchPageState();
}

class _PlaylistSearchPageState extends ConsumerState<PlaylistSearchPage> {
  String _searchQuery = '';

  late final WindowedPaginatedList<Playlist> _list =
      WindowedPaginatedList<Playlist>(
    fetcher: (page, pageSize, query) async {
      final repository = ref.read(playlistRepositoryProvider);
      if (repository == null) return (items: <Playlist>[], total: 0);
      return repository.getPlaylistsPage(page, pageSize, query: query);
    },
  );

  @override
  void initState() {
    super.initState();
    _list.load('');
  }

  /// 播放本地歌单：拉取歌单详情歌曲后统一入口播放。
  Future<void> _playLocalPlaylist(WidgetRef ref, Playlist playlist) async {
    final detail = await ref.read(playlistDetailProvider(playlist.id).future);
    final songs = detail?.songs ?? const <Song>[];
    if (songs.isEmpty || !mounted) return;
    await playEffectiveQueue(ref, songs);
  }

  @override
  Widget build(BuildContext context) {
    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'playlist_search_page',
      shouldRetry: (ref) => _list.hasError,
      onRetry: (ref) => _list.retry(),
      child: EchoScaffold(
        topBar: EchoTopBar.back(
          context: context,
          title: '所有歌单',
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EntitySearchBar(
              query: _searchQuery,
              hintText: '搜索歌单',
              onQueryChanged: (query) {
                setState(() => _searchQuery = query);
                if (query.isEmpty) _list.load('');
              },
            ),
            SizedBox(height: context.echoSpacing.xs),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_searchQuery.isNotEmpty) {
      // 聚合搜索:本地结果 + 全网结果分块展示(强制聚合,无来源切换)。
      return AggregateSearchResults(
        kind: SearchEntityKind.playlist,
        query: _searchQuery,
        localBlock: AggregateLocalBlock<Playlist>(
          fetcher: () async {
            final repository = ref.read(playlistRepositoryProvider);
            if (repository == null) {
              return (items: <Playlist>[], total: 0);
            }
            return repository.getPlaylistsPage(1, 12, query: _searchQuery);
          },
          grid: true,
          itemBuilder: (context, playlist, _) => SearchPlaylistCard(
            playlist: SearchPlaylist.fromLocal(playlist),
            onPlay: () => unawaited(_playLocalPlaylist(ref, playlist)),
            onOpen: () => Navigator.of(context).push<void>(
              EchoPageRoute<void>(
                context: context,
                builder: (_) => PlaylistDetailPage(
                  playlistId: playlist.id,
                  initialName: playlist.name,
                  initialSongCount: playlist.songCount,
                  initialCoverArt: playlist.coverArt,
                ),
              ),
            ),
          ),
          emptyText: '本地库无匹配歌单',
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: AnimatedBuilder(
          animation: _list,
          builder: (context, _) => WindowedListView<Playlist>(
            controller: _list,
            placeholderExtent: 76,
            padding: EdgeInsets.only(
              left: context.echoPageHorizontalPadding,
              right: context.echoPageHorizontalPadding,
              top: context.echoSpacing.xs,
              bottom:
                  context.echoSpacing.xxl + context.echoShellBottomObstruction,
            ),
            emptyTitle: '暂无歌单',
            emptyDescription: '创建歌单，把想连续听的音乐整理在一起。',
            emptyIcon: AppIcons.playlist,
            itemBuilder: (context, index, playlist) =>
                DiscoverPlaylistTile(
              key: ValueKey('playlist-row-${playlist!.id}'),
              playlist: playlist,
              onPressed: () => Navigator.of(context).push<void>(
                EchoPageRoute<void>(
                  context: context,
                  builder: (_) => PlaylistDetailPage(
                    playlistId: playlist.id,
                    initialName: playlist.name,
                    initialSongCount: playlist.songCount,
                    initialCoverArt: playlist.coverArt,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
