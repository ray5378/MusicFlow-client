import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/search.dart';
import '../../../features/search/widgets/aggregate_search_results.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
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
              query: _searchQuery,
              hintText: '搜索歌手',
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
        kind: SearchEntityKind.artist,
        query: _searchQuery,
        localBlock: AggregateLocalBlock<Artist>(
          fetcher: () async {
            final repository = ref.read(musicRepositoryProvider);
            if (repository == null) {
              return (items: <Artist>[], total: 0);
            }
            return repository.getArtistsPage(1, 12, query: _searchQuery);
          },
          horizontal: false,
          itemBuilder: (context, artist) => EchoArtistRow(
            key: ValueKey('local-artist-${artist.id}'),
            artist: artist,
            contentPadding: EdgeInsetsDirectional.fromSTEB(
              context.echoPageHorizontalPadding,
              context.echoSpacing.xs,
              context.echoPageHorizontalPadding,
              context.echoSpacing.xs,
            ),
            onPressed: () => Navigator.of(context).push<void>(
              EchoPageRoute<void>(
                context: context,
                builder: (_) => ArtistDetailPage(artistId: artist.id),
              ),
            ),
          ),
          emptyText: '本地库无匹配歌手',
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
