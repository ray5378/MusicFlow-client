import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../features/library/widgets/windowed_list_view.dart';
import '../../../features/library/widgets/windowed_paginated_list.dart';
import '../../../features/player/widgets/song_options_sheet.dart';
import '../../../features/search/widgets/aggregate_search_results.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/library_stats_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/song_list_item.dart';
import '../../../l10n/generated/app_localizations.dart';
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
    final loc = AppLocalizations.of(context);
    final selected = await showMusicFlowBottomSheet<_SongSort>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.library_song_sort,
        subtitle: loc.library_sort_sheet_subtitle,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final option in _SongSort.values)
              MusicFlowActionRow(
                icon: option == _sort ? AppIcons.check : AppIcons.sort,
                title: switch (option) {
                  _SongSort.titleAsc => loc.song_sort_title_asc,
                  _SongSort.recentAdded => loc.song_sort_recent_added,
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
    final loc = AppLocalizations.of(context);
    // 标题下方只显示本页对应的计数（共多少首歌曲）。
    final countsText = ref
        .watch(libraryCountsProvider)
        .maybeWhen(data: (counts) => counts.songsLabel ?? '', orElse: () => '');

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'song_list_page',
      shouldRetry: (ref) => _list.hasError,
      onRetry: (ref) => _list.retry(),
      child: MusicFlowScaffold(
        topBar: MusicFlowTopBar.back(
          context: context,
          title: loc.library_all_songs,
          subtitle: countsText,
          actions: <Widget>[
            if (_searchQuery.isEmpty)
              MusicFlowIconButton(
                icon: AppIcons.sort,
                label: loc.library_song_sort,
                onPressed: () => unawaited(_showSortSheet()),
              ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EntitySearchBar(
              query: _searchQuery,
              hintText: loc.library_search_songs,
              onQueryChanged: (query) {
                setState(() => _searchQuery = query);
                if (query.isEmpty) _reload();
              },
            ),
            SizedBox(height: context.musicFlowSpacing.xs),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final loc = AppLocalizations.of(context);
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
          itemBuilder: (context, song, index) => _buildRow(index, song),
          emptyText: loc.library_local_no_match_songs,
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
              left: context.musicFlowPageHorizontalPadding,
              right: context.musicFlowPageHorizontalPadding,
              top: context.musicFlowSpacing.xs,
              bottom:
                  context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
            ),
            emptyTitle: loc.library_empty_songs,
            emptyDescription: loc.library_empty_songs_desc,
            itemBuilder: (context, index, item) =>
                _buildRow(index, item!),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(int index, Song song) {
    // 当前播放歌曲 id：识别正在播放的歌曲行（封面叠加跳动竖条）。
    final currentSongId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    return KeyedSubtree(
      key: ValueKey('song-row-${song.id}'),
      child: SongListItem(
        song: song,
        index: index,
        variant: SongListItemVariant.standard,
        isCurrent: song.id == currentSongId,
        contentPadding: EdgeInsetsDirectional.fromSTEB(
          context.musicFlowPageHorizontalPadding,
          context.musicFlowSpacing.xs,
          context.musicFlowPageHorizontalPadding,
          context.musicFlowSpacing.xs,
        ),
        onTap: () async {
          if (_searchQuery.isNotEmpty) {
            // 搜索模式:队列用本地搜索结果(与展示列表一致,至多 12 首),
            // startIndex 指向被点击的这首,保证「点哪首播哪首」。
            await _playFromSearchResults(index, song);
            return;
          }
          // 播放队列需要完整顺序表:后台一次性拉全量构建队列(仅用户主动播放时),
          // 渲染层仍保持窗口化,不回退到全量渲染。
          try {
            final all =
                await ref.read(musicRepositoryProvider)!.getAllSongs();
            if (!mounted) return;
            await playEffectiveQueue(
              ref,
              all,
              startIndex: index.clamp(0, all.length - 1),
            );
          } catch (_) {
            await playEffectiveQueue(ref, <Song>[song], startIndex: 0);
          }
        },
        onLongPress: () => showSongOptionsSheet(context: context, song: song),
      ),
    );
  }

  /// 搜索模式下播放:以本地搜索结果构建队列(与搜索页展示的列表一致),
  /// 从被点击的这首开始播。结果为空或拉取失败时退化为单曲播放。
  Future<void> _playFromSearchResults(int index, Song song) async {
    final repository = ref.read(musicRepositoryProvider);
    if (repository == null) {
      await playEffectiveQueue(ref, <Song>[song], startIndex: 0);
      return;
    }
    try {
      final result = await repository.getSongsPage(
        1,
        12,
        query: _searchQuery,
      );
      if (!mounted) return;
      final searchSongs = result.items;
      if (searchSongs.isEmpty) {
        await playEffectiveQueue(ref, <Song>[song], startIndex: 0);
        return;
      }
      final start = index.clamp(0, searchSongs.length - 1);
      await playEffectiveQueue(ref, searchSongs, startIndex: start);
    } catch (_) {
      if (mounted) {
        await playEffectiveQueue(ref, <Song>[song], startIndex: 0);
      }
    }
  }
}
