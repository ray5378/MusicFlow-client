import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/search.dart';
import '../../../features/discover/widgets/discover_media_widgets.dart';
import '../../../features/library/widgets/library_collection_components.dart';
import '../../../features/library/widgets/windowed_list_view.dart';
import '../../../features/library/widgets/windowed_paginated_list.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/search_provider.dart';
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
  SearchMode _searchMode = SearchMode.aggregate;
  String _searchProviderId = '';
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
              kind: SearchEntityKind.playlist,
              mode: _searchMode,
              providerId: _searchProviderId,
              query: _searchQuery,
              onSourceChanged: (source) => setState(() {
                _searchMode = source.mode;
                _searchProviderId = source.providerId;
              }),
              onQueryChanged: (query) {
                setState(() => _searchQuery = query);
                if (_searchMode == SearchMode.local) _list.load(query);
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
    if (_searchQuery.isNotEmpty && _searchMode != SearchMode.local) {
      final results = ref.watch(
        searchResultsProvider(
          SearchRequest(
            kind: SearchEntityKind.playlist,
            mode: _searchMode,
            query: _searchQuery,
            providerId: _searchProviderId,
          ),
        ),
      );
      return results.when(
        data: (outcome) => outcome.playlists.isEmpty
            ? const EchoEmptyState(
                title: '未找到结果',
                description: '换个关键词或切换搜索来源试试。',
                icon: AppIcons.search,
              )
            : SearchResultList(
                kind: SearchEntityKind.playlist,
                outcome: outcome,
              ),
        loading: () => const EchoMediaListSkeleton(count: 8),
        error: (e, _) => EchoErrorState(
          title: '搜索失败',
          description: '$e',
          actionLabel: '重试',
          onAction: () {
            ref.invalidate(searchResultsProvider(SearchRequest(
              kind: SearchEntityKind.playlist,
              mode: _searchMode,
              query: _searchQuery,
              providerId: _searchProviderId,
            )));
          },
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
