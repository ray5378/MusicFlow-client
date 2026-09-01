import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/album.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../features/search/widgets/aggregate_search_results.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/library_stats_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/queue_origin_provider.dart';
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

  /// 播放本地专辑：拉取专辑详情歌曲后统一入口播放。
  Future<void> _playLocalAlbum(WidgetRef ref, Album album) async {
    final detail = await ref.read(albumDetailProvider(album.id).future);
    final songs = detail?.songs ?? const <Song>[];
    if (songs.isEmpty || !mounted) return;
    await playEffectiveQueue(
      ref,
      songs,
      origin: QueueOrigin(QueueOriginKind.album, album.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 标题下方只显示本页对应的计数（共多少张专辑）。
    final countsText = ref
        .watch(libraryCountsProvider)
        .maybeWhen(data: (counts) => counts.albumsLabel ?? '', orElse: () => '');

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'album_list_page',
      shouldRetry: (ref) => _list.hasError,
      onRetry: (ref) => _list.retry(),
      child: MusicFlowScaffold(
        topBar: MusicFlowTopBar.back(
          context: context,
          title: '所有专辑',
          subtitle: countsText,
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EntitySearchBar(
              query: _searchQuery,
              hintText: '搜索专辑',
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
    if (_searchQuery.isNotEmpty) {
      // 聚合搜索:本地结果 + 全网结果分块展示(强制聚合,无来源切换)。
      return AggregateSearchResults(
        kind: SearchEntityKind.album,
        query: _searchQuery,
        localBlock: AggregateLocalBlock<Album>(
          fetcher: () async {
            final repository = ref.read(musicRepositoryProvider);
            if (repository == null) {
              return (items: <Album>[], total: 0);
            }
            return repository.getAlbumsPage(1, 12, query: _searchQuery);
          },
          grid: true,
          itemBuilder: (context, album, _) => SearchAlbumCard(
            album: SearchAlbum.fromLocal(album),
            onPlay: () => unawaited(_playLocalAlbum(ref, album)),
            onImport: () {},
            onOpen: () => Navigator.of(context).push<void>(
              MusicFlowPageRoute<void>(
                context: context,
                builder: (_) => AlbumDetailPage(albumId: album.id),
              ),
            ),
            showImport: false, // 本地专辑无需入库
          ),
          emptyText: '本地库无匹配专辑',
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
              mainAxisSpacing: context.musicFlowSpacing.sm,
              crossAxisSpacing: context.musicFlowSpacing.sm,
              mainAxisExtent: 240,
            ),
            padding: EdgeInsets.only(
              left: context.musicFlowPageHorizontalPadding,
              right: context.musicFlowPageHorizontalPadding,
              top: context.musicFlowSpacing.xs,
              bottom: context.musicFlowSpacing.xxl +
                  context.musicFlowShellBottomObstruction,
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
    // 当前播放来源：识别正在播放的专辑（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);
    return MusicFlowAlbumTile(
      key: ValueKey('album-tile-${album.id}'),
      album: album,
      isNowPlaying: queueOrigin?.matchesAlbum(album.id) ?? false,
      onPressed: () {
        Navigator.of(context).push<void>(
          MusicFlowPageRoute<void>(
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
