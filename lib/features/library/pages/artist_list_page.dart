import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/search.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../widgets/library_collection_components.dart';
import '../widgets/windowed_list_view.dart';
import '../widgets/windowed_paginated_list.dart';
import 'artist_detail_page.dart';

/// 艺术家库 —— 窗口化分页列表(对齐主项目前端 useInfiniteList)。
class ArtistListPage extends ConsumerStatefulWidget {
  const ArtistListPage({super.key});

  @override
  ConsumerState<ArtistListPage> createState() => _ArtistListPageState();
}

class _ArtistListPageState extends ConsumerState<ArtistListPage> {
  SearchMode _searchMode = SearchMode.aggregate;
  String _searchProviderId = '';
  String _searchQuery = '';

  late final WindowedPaginatedList<Artist> _list =
      WindowedPaginatedList<Artist>(
    fetcher: (page, pageSize, query) async {
      final repository = ref.read(musicRepositoryProvider);
      if (repository == null) return (items: <Artist>[], total: 0);
      return repository.getArtistsPage(page, pageSize, query: query);
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
      debugLabel: 'artist_list_page',
      shouldRetry: (ref) => _list.hasError,
      onRetry: (ref) => _list.retry(),
      child: EchoScaffold(
        topBar: EchoTopBar.back(context: context, title: '所有艺术家'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EntitySearchBar(
              kind: SearchEntityKind.artist,
              mode: _searchMode,
              providerId: _searchProviderId,
              query: _searchQuery,
              onSourceChanged: (source) => setState(() {
                _searchMode = source.mode;
                _searchProviderId = source.providerId;
              }),
              onQueryChanged: (query) {
                setState(() => _searchQuery = query);
                if (_searchMode == SearchMode.local) {
                  _list.load(query);
                }
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
            kind: SearchEntityKind.artist,
            mode: _searchMode,
            query: _searchQuery,
            providerId: _searchProviderId,
          ),
        ),
      );
      return results.when(
        data: (outcome) => outcome.artists.isEmpty
            ? const EchoEmptyState(
                title: '未找到结果',
                description: '换个关键词或切换搜索来源试试。',
                icon: AppIcons.search,
              )
            : SearchResultList(kind: SearchEntityKind.artist, outcome: outcome),
        loading: () => const EchoMediaListSkeleton(circle: true),
        error: (e, _) => EchoErrorState(
          title: '搜索失败',
          description: '$e',
          actionLabel: '重试',
          onAction: () {
            ref.invalidate(searchResultsProvider(SearchRequest(
              kind: SearchEntityKind.artist,
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
          builder: (context, _) => WindowedListView<Artist>(
            controller: _list,
            placeholderExtent: 72,
            padding: EdgeInsets.only(
              left: context.echoPageHorizontalPadding,
              right: context.echoPageHorizontalPadding,
              top: context.echoSpacing.xs,
              bottom: context.echoSpacing.xxl +
                  context.echoShellBottomObstruction,
            ),
            emptyTitle: '暂无歌手',
            emptyDescription: '同步音乐库后，歌手会显示在这里。',
            emptyIcon: AppIcons.profile,
            itemBuilder: (context, index, artist) => EchoArtistRow(
              key: ValueKey('artist-row-${artist!.id}'),
              artist: artist,
              contentPadding: EdgeInsetsDirectional.fromSTEB(
                0,
                context.echoSpacing.xs,
                0,
                context.echoSpacing.xs,
              ),
              onPressed: () => Navigator.of(context).push<void>(
                EchoPageRoute<void>(
                  context: context,
                  builder: (_) => ArtistDetailPage(artistId: artist.id),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
