import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../features/library/widgets/windowed_list_view.dart';
import '../../../features/library/widgets/windowed_paginated_list.dart';
import '../../../features/player/widgets/song_options_sheet.dart';
import '../../../features/search/widgets/aggregate_search_results.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/song_list_item.dart';
import '../../../widgets/visible_remote_retry_scope.dart';

/// 歌曲库 —— 窗口化分页加载(对齐主项目前端 useInfiniteList):
/// 渲染层虚拟滚动、数据层按 page/pageSize 分块拉取并剪枝;
/// 排序仅提供后端支持的两种:标题 A-Z / 最近入库。
class SongListPage extends ConsumerStatefulWidget {
  const SongListPage({super.key});

  @override
  ConsumerState<SongListPage> createState() => _SongListPageState();
}

enum _SongSort { titleAsc, recentAdded }

class _SongListPageState extends ConsumerState<SongListPage> {
  _SongSort _sort = _SongSort.titleAsc;
  String _searchQuery = '';

  late final WindowedPaginatedList<Song> _list = WindowedPaginatedList<Song>(
    fetcher: (page, pageSize, query) async {
      final repository = ref.read(musicRepositoryProvider);
      if (repository == null) return (items: <Song>[], total: 0);
      return repository.getSongsPage(
        page,
        pageSize,
        query: query,
        sort: _sort == _SongSort.recentAdded ? 'recentAdded' : '',
      );
    },
  );

  @override
  void initState() {
    super.initState();
    _list.load('');
  }

  void _reload() {
    _list.load(_searchQuery.isEmpty ? '' : _searchQuery);
  }

  Future<void> _showSortSheet() async {
    final selected = await showEchoBottomSheet<_SongSort>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: '歌曲排序',
        subtitle: '窗口化加载模式下支持以下排序',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final option in _SongSort.values)
              EchoActionRow(
                icon: option == _sort ? AppIcons.check : AppIcons.sort,
                title: switch (option) {
                  _SongSort.titleAsc => '标题 A-Z',
                  _SongSort.recentAdded => '最近入库',
                },
                selected: option == _sort,
                onPressed: () => Navigator.of(sheetContext).pop(option),
              ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null || selected == _sort) return;
    setState(() => _sort = selected);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'song_list_page',
      shouldRetry: (ref) => _list.hasError,
      onRetry: (ref) => _list.retry(),
      child: EchoScaffold(
        topBar: EchoTopBar.back(
          context: context,
          title: '所有歌曲',
          actions: <Widget>[
            if (_searchQuery.isEmpty)
              EchoIconButton(
                icon: AppIcons.sort,
                label: '歌曲排序',
                onPressed: () => unawaited(_showSortSheet()),
              ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EntitySearchBar(
              query: _searchQuery,
              hintText: '搜索歌曲',
              onQueryChanged: (query) {
                setState(() => _searchQuery = query);
                if (query.isEmpty) _reload();
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
        kind: SearchEntityKind.song,
        query: _searchQuery,
        localBlock: AggregateLocalBlock<Song>(
          fetcher: () async {
            final repository = ref.read(musicRepositoryProvider);
            if (repository == null) {
              return (items: <Song>[], total: 0);
            }
            return repository.getSongsPage(1, 12, query: _searchQuery);
          },
          horizontal: false,
          itemBuilder: (context, song) => _buildRow(0, song),
          emptyText: '本地库无匹配歌曲',
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: AnimatedBuilder(
          animation: _list,
          builder: (context, _) => WindowedListView<Song>(
            controller: _list,
            placeholderExtent: 72,
            padding: EdgeInsets.only(
              left: context.echoPageHorizontalPadding,
              right: context.echoPageHorizontalPadding,
              top: context.echoSpacing.xs,
              bottom:
                  context.echoSpacing.xxl + context.echoShellBottomObstruction,
            ),
            emptyTitle: '暂无歌曲',
            emptyDescription: '同步音乐库后，歌曲会显示在这里。',
            itemBuilder: (context, index, item) =>
                _buildRow(index, item!),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(int index, Song song) {
    return KeyedSubtree(
      key: ValueKey('song-row-${song.id}'),
      child: SongListItem(
        song: song,
        index: index,
        variant: SongListItemVariant.standard,
        contentPadding: EdgeInsetsDirectional.fromSTEB(
          context.echoPageHorizontalPadding,
          context.echoSpacing.xs,
          context.echoPageHorizontalPadding,
          context.echoSpacing.xs,
        ),
        onTap: () async {
          // 播放队列需要完整顺序表:后台一次性拉全量构建队列(仅用户主动播放时),
          // 渲染层仍保持窗口化,不回退到全量渲染。
          try {
            final all =
                await ref.read(musicRepositoryProvider)!.getAllSongs();
            if (!mounted) return;
            await ref
                .read(playerProvider.notifier)
                .playQueue(all, startIndex: index.clamp(0, all.length - 1));
          } catch (_) {
            await ref
                .read(playerProvider.notifier)
                .playQueue(<Song>[song], startIndex: 0);
          }
        },
        onLongPress: () => showSongOptionsSheet(context: context, song: song),
      ),
    );
  }
}
