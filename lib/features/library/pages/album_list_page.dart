import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/album.dart';
import '../../../data/models/search.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../widgets/album_options_sheet.dart';
import '../widgets/library_collection_components.dart';
import '../widgets/windowed_list_view.dart';
import '../widgets/windowed_paginated_list.dart';
import 'album_detail_page.dart';

/// 专辑库 —— 窗口化分页网格(对齐主项目前端 useCardGrid):
/// 服务端分页 + 虚拟滚动 + 视口渐进式加载,不再一次性拉全量。
class AlbumListPage extends ConsumerStatefulWidget {
  const AlbumListPage({super.key});

  @override
  ConsumerState<AlbumListPage> createState() => _AlbumListPageState();
}

class _AlbumListPageState extends ConsumerState<AlbumListPage> {
  SearchMode _searchMode = SearchMode.aggregate;
  String _searchProviderId = '';
  String _searchQuery = '';

  late final WindowedPaginatedList<Album> _list = WindowedPaginatedList<Album>(
    fetcher: (page, pageSize, query) async {
      final repository = ref.read(musicRepositoryProvider);
      if (repository == null) return (items: <Album>[], total: 0);
      return repository.getAlbumsPage(page, pageSize, query: query);
    },
  );

  @override
  void initState() {
    super.initState();
    _list.load('');
  }

  void _reload() => _list.load(_searchQuery);

  @override
  Widget build(BuildContext context) {
    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'album_list_page',
      shouldRetry: (ref) => _list.hasError,
      onRetry: (ref) => _list.retry(),
      child: EchoScaffold(
        topBar: EchoTopBar.back(context: context, title: '所有专辑'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EntitySearchBar(
              kind: SearchEntityKind.album,
              mode: _searchMode,
              providerId: _searchProviderId,
              query: _searchQuery,
              onSourceChanged: (source) => setState(() {
                _searchMode = source.mode;
                _searchProviderId = source.providerId;
              }),
              onQueryChanged: (query) {
                setState(() => _searchQuery = query);
                if (_searchMode == SearchMode.local) _reload();
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
            kind: SearchEntityKind.album,
            mode: _searchMode,
            query: _searchQuery,
            providerId: _searchProviderId,
          ),
        ),
      );
      return results.when(
        data: (outcome) => outcome.albums.isEmpty
            ? const EchoEmptyState(
                title: '未找到结果',
                description: '换个关键词或切换搜索来源试试。',
                icon: AppIcons.search,
              )
            : SearchResultList(kind: SearchEntityKind.album, outcome: outcome),
        loading: () => const EchoAlbumGridSkeleton(),
        error: (e, _) => EchoErrorState(
          title: '搜索失败',
          description: '$e',
          actionLabel: '重试',
          onAction: () {
            ref.invalidate(searchResultsProvider(SearchRequest(
              kind: SearchEntityKind.album,
              mode: _searchMode,
              query: _searchQuery,
              providerId: _searchProviderId,
            )));
          },
        ),
      );
    }

    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final targetExtent = textScale >= 1.6 ? 280.0 : 180.0;
    final crossAxisCount =
        math.max(1, (math.min(1400.0, screenWidth) / targetExtent).floor());

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: AnimatedBuilder(
          animation: _list,
          builder: (context, _) => WindowedListView<Album>(
            controller: _list,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: context.echoSpacing.sm,
              crossAxisSpacing: context.echoSpacing.sm,
              mainAxisExtent: 240,
            ),
            padding: EdgeInsets.only(
              left: context.echoPageHorizontalPadding,
              right: context.echoPageHorizontalPadding,
              top: context.echoSpacing.xs,
              bottom: context.echoSpacing.xxl +
                  context.echoShellBottomObstruction,
            ),
            emptyTitle: '暂无专辑',
            emptyDescription: '同步音乐库后，专辑会显示在这里。',
            emptyIcon: AppIcons.albumOutline,
            itemBuilder: (context, index, album) =>
                _buildTile(index, album!),
          ),
        ),
      ),
    );
  }

  Widget _buildTile(int index, Album album) {
    return EchoAlbumTile(
      key: ValueKey('album-tile-${album.id}'),
      album: album,
      onPressed: () {
        Navigator.of(context).push<void>(
          EchoPageRoute<void>(
            context: context,
            builder: (_) => AlbumDetailPage(albumId: album.id),
          ),
        );
      },
      onLongPress: () => showAlbumOptionsSheet(
        context: context,
        ref: ref,
        album: album,
      ),
    );
  }
}
