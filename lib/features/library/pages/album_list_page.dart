import 'dart:math' as math;

import 'package:azlistview/azlistview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/design/components/echo_page_route.dart';
import '../../../data/models/album.dart';
import '../../../data/models/search.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../utils/az_item.dart';
import '../../../utils/pinyin_helper.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../widgets/album_options_sheet.dart';
import '../widgets/library_collection_components.dart';
import 'album_detail_page.dart';

/// Alphabetical album collection with a responsive, content-led grid.
class AlbumListPage extends ConsumerStatefulWidget {
  const AlbumListPage({super.key});

  @override
  ConsumerState<AlbumListPage> createState() => _AlbumListPageState();
}

class _AlbumListPageState extends ConsumerState<AlbumListPage> {
  List<AzItem<List<Album>>> _albumRows = const <AzItem<List<Album>>>[];
  int _albumsSignature = 0;
  int _cachedItemsPerRow = 0;
  SearchMode _searchMode = SearchMode.aggregate;
  String _searchProviderId = '';
  String _searchQuery = '';

  int _buildAlbumsSignature(List<Album> albums) {
    return Object.hashAll(
      albums.map(
        (album) => Object.hash(
          album.id,
          album.name,
          album.artist,
          album.coverArt,
          album.starred,
        ),
      ),
    );
  }

  List<AzItem<List<Album>>> _buildAlbumRows(
    List<Album> albums,
    int itemsPerRow,
  ) {
    final items = albums
        .map((album) {
          return AzItem<Album>(
            data: album,
            tag: PinyinUtils.getFirstChar(album.name),
            namePinyin: PinyinUtils.getPinyin(album.name),
          );
        })
        .toList(growable: false);
    SuspensionUtil.sortListBySuspensionTag(items);

    final grouped = <String, List<Album>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.tag, () => <Album>[]).add(item.data);
    }

    final rows = <AzItem<List<Album>>>[];
    for (final entry in grouped.entries) {
      final group = entry.value;
      for (var start = 0; start < group.length; start += itemsPerRow) {
        final end = math.min(start + itemsPerRow, group.length);
        final albumsInRow = group.sublist(start, end);
        rows.add(
          AzItem<List<Album>>(
            data: albumsInRow,
            tag: entry.key,
            namePinyin: PinyinUtils.getPinyin(albumsInRow.first.name),
          ),
        );
      }
    }
    SuspensionUtil.setShowSuspensionStatus(rows);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final albumsAsync = ref.watch(allAlbumsProvider);
    final loadFailed = ref.watch(allAlbumsLoadFailedProvider);

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'album_list_page',
      shouldRetry: (ref) => loadFailed || albumsAsync.hasError,
      onRetry: (ref) => ref.invalidate(allAlbumsProvider),
      child: EchoScaffold(
        topBar: EchoTopBar.back(
          context: context,
          title: '所有专辑',
        ),
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
              onQueryChanged: (query) => setState(() => _searchQuery = query),
            ),
            SizedBox(height: context.echoSpacing.xs),
            Expanded(
              child: _searchBody(albumsAsync, loadFailed),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBody(AsyncValue<List<Album>> albumsAsync, bool loadFailed) {
    if (_searchQuery.isEmpty) {
      return albumsAsync.when(
        data: (albums) => _localList(albums, loadFailed),
        loading: () => const EchoAlbumGridSkeleton(),
        error: (error, stackTrace) => _errorState(),
      );
    }
    if (_searchMode == SearchMode.local) {
      return albumsAsync.when(
        data: (albums) {
          final filtered =
              albums.where((a) => _matches(a, _searchQuery)).toList();
          if (filtered.isEmpty) return _emptyResults();
          return _buildAlbumCollection(context, filtered);
        },
        loading: () => const EchoAlbumGridSkeleton(),
        error: (error, stackTrace) => _errorState(),
      );
    }
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
          ? _emptyResults()
          : SearchResultList(kind: SearchEntityKind.album, outcome: outcome),
      loading: () => const EchoAlbumGridSkeleton(),
      error: (error, stackTrace) => _errorState(),
    );
  }

  bool _matches(Album album, String query) {
    final lower = query.toLowerCase();
    return (album.name.toLowerCase().contains(lower)) ||
        (album.artist?.toLowerCase().contains(lower) ?? false);
  }

  Widget _localList(List<Album> albums, bool loadFailed) {
    if (albums.isEmpty) {
      if (loadFailed) return _errorState();
      return const EchoEmptyState(
        title: '暂无专辑',
        description: '同步音乐库后，专辑会按名称分组显示在这里。',
        icon: AppIcons.albumOutline,
      );
    }
    return _buildAlbumCollection(context, albums);
  }

  Widget _buildAlbumCollection(BuildContext context, List<Album> albums) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final effectiveWidth = math.min(1400.0, screenWidth);
    final targetExtent = textScale >= 1.6 ? 280.0 : 180.0;
    final itemsPerRow = math.max(1, (effectiveWidth / targetExtent).floor());

    final signature = _buildAlbumsSignature(albums);
    if (signature != _albumsSignature ||
        _cachedItemsPerRow != itemsPerRow ||
        _albumRows.isEmpty) {
      _albumRows = _buildAlbumRows(albums, itemsPerRow);
      _albumsSignature = signature;
      _cachedItemsPerRow = itemsPerRow;
    }
    final rows = _albumRows;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: EchoAzIndexReveal(
          builder: (context, opacity, _) => AzListView(
            key: const ValueKey<String>('album-list-scroll'),
            data: rows,
            itemCount: rows.length,
            padding: EdgeInsets.only(
              bottom:
                  context.echoSpacing.xxl + context.echoShellBottomObstruction,
            ),
            itemBuilder: (context, index) {
              final item = rows[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (item.isShowSuspension)
                    EchoLibrarySectionLabel(
                      label: item.getSuspensionTag(),
                    ),
                  Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(
                      context.echoPageHorizontalPadding,
                      context.echoSpacing.xs,
                      44,
                      context.echoSpacing.sm,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (var slot = 0; slot < itemsPerRow; slot++) ...<Widget>[
                          Expanded(
                            child: slot < item.data.length
                                ? EchoAlbumTile(
                                    album: item.data[slot],
                                    allowFullText: textScale >= 1.6,
                                    onPressed: () =>
                                        _openAlbum(context, item.data[slot]),
                                    onLongPress: () => showAlbumOptionsSheet(
                                      context: context,
                                      ref: ref,
                                      album: item.data[slot],
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          if (slot < itemsPerRow - 1)
                            SizedBox(width: context.echoSpacing.sm),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
            indexBarData: SuspensionUtil.getTagIndexList(rows),
            indexBarWidth: 24,
            indexBarMargin: EdgeInsetsDirectional.only(
              end: context.echoSpacing.xxs,
            ),
            indexBarOptions: echoIndexBarOptions(
              context,
              opacity: opacity,
            ),
          ),
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
        onAction: () => ref.invalidate(allAlbumsProvider),
      );

  void _openAlbum(BuildContext context, Album album) {
    Navigator.of(context).push<void>(
      EchoPageRoute<void>(
        context: context,
        builder: (_) => AlbumDetailPage(albumId: album.id),
      ),
    );
  }
}
