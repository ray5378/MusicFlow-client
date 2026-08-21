import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/design/components/echo_page_route.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/search.dart';
import '../../../features/discover/widgets/discover_media_widgets.dart';
import '../../../features/library/widgets/library_collection_components.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/search_provider.dart';
import '../../library/pages/playlist_detail_page.dart';
import '../../../widgets/visible_remote_retry_scope.dart';

/// 歌单类目：顶部搜索（聚合/本地/插件），本地歌单直接打开，远程歌单先入库再打开。
class PlaylistSearchPage extends ConsumerStatefulWidget {
  const PlaylistSearchPage({super.key});

  @override
  ConsumerState<PlaylistSearchPage> createState() => _PlaylistSearchPageState();
}

class _PlaylistSearchPageState extends ConsumerState<PlaylistSearchPage> {
  SearchMode _searchMode = SearchMode.aggregate;
  String _searchProviderId = '';
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final loadFailed = ref.watch(playlistsLoadFailedProvider);

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'playlist_search_page',
      shouldRetry: (ref) => loadFailed || playlistsAsync.hasError,
      onRetry: (ref) => ref.invalidate(playlistsProvider),
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
              onQueryChanged: (query) => setState(() => _searchQuery = query),
            ),
            SizedBox(height: context.echoSpacing.xs),
            Expanded(
              child: _searchBody(playlistsAsync, loadFailed),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBody(
    AsyncValue<List<Playlist>> playlistsAsync,
    bool loadFailed,
  ) {
    if (_searchQuery.isEmpty) {
      return playlistsAsync.when(
        data: _localList,
        loading: () => const EchoMediaListSkeleton(count: 8),
        error: (error, stackTrace) => _errorState(),
      );
    }
    if (_searchMode == SearchMode.local) {
      return playlistsAsync.when(
        data: (playlists) {
          final filtered = playlists
              .where((p) => p.name.toLowerCase().contains(
                    _searchQuery.toLowerCase(),
                  ))
              .toList();
          if (filtered.isEmpty) return _emptyResults();
          return _localList(filtered);
        },
        loading: () => const EchoMediaListSkeleton(count: 8),
        error: (error, stackTrace) => _errorState(),
      );
    }
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
          ? _emptyResults()
          : SearchResultList(kind: SearchEntityKind.playlist, outcome: outcome),
      loading: () => const EchoMediaListSkeleton(count: 8),
      error: (error, stackTrace) => _errorState(),
    );
  }

  Widget _localList(List<Playlist> playlists) {
    if (playlists.isEmpty) {
      return const EchoEmptyState(
        title: '暂无歌单',
        description: '创建歌单，把想连续听的音乐整理在一起。',
        icon: AppIcons.playlist,
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: ListView.builder(
          padding: EdgeInsets.only(
            bottom: context.echoSpacing.xxl + context.echoShellBottomObstruction,
          ),
          itemCount: playlists.length,
          itemBuilder: (context, index) {
            final playlist = playlists[index];
            return DiscoverPlaylistTile(
              playlist: playlist,
              onPressed: () => Navigator.of(context).push<void>(
                EchoPageRoute<void>(
                  context: context,
                  builder: (_) => PlaylistDetailPage(playlistId: playlist.id),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _emptyResults() => const EchoEmptyState(
        title: '未找到结果',
        description: '换个关键词或切换搜索来源试试。',
        icon: AppIcons.search,
      );

  Widget _errorState() => EchoErrorState(
        title: '加载失败',
        description: '请检查网络或服务器状态后重试。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(playlistsProvider),
      );
}
