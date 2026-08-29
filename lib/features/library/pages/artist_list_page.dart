import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/search.dart';
import '../../../data/models/song.dart';
import '../../../features/search/widgets/aggregate_search_results.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/library_stats_provider.dart';
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

  /// 播放本地歌手歌曲：拉取歌手详情歌曲后统一入口播放。
  Future<void> _playLocalArtist(WidgetRef ref, Artist artist) async {
    final detail = await ref.read(artistDetailProvider(artist.id).future);
    final songs = detail?.songs ?? const <Song>[];
    if (songs.isEmpty || !mounted) return;
    await playEffectiveQueue(ref, songs);
  }

  @override
  Widget build(BuildContext context) {
    // 标题下方展示库总览计数（艺术家/专辑/歌曲/歌单）。
    final countsText = ref
        .watch(libraryCountsProvider)
        .maybeWhen(data: (counts) => counts.format(), orElse: () => '');

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'artist_list_page',
      shouldRetry: (ref) => _list.hasError,
      onRetry: (ref) => _list.retry(),
      child: MusicFlowScaffold(
        topBar: MusicFlowTopBar.back(
          context: context,
          title: '所有艺术家',
          subtitle: countsText,
        ),
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
          grid: true,
          itemBuilder: (context, artist, _) => SearchArtistCard(
            artist: SearchArtist.fromLocal(artist),
            onPlay: () => unawaited(_playLocalArtist(ref, artist)),
            onOpen: () => Navigator.of(context).push<void>(
              MusicFlowPageRoute<void>(
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
              left: context.musicFlowPageHorizontalPadding,
              right: context.musicFlowPageHorizontalPadding,
              top: context.musicFlowSpacing.xs,
              bottom: context.musicFlowSpacing.xxl +
                  context.musicFlowShellBottomObstruction,
            ),
            emptyTitle: '暂无歌手',
            emptyDescription: '同步音乐库后，歌手会显示在这里。',
            emptyIcon: AppIcons.profile,
            itemBuilder: (context, index, artist) => MusicFlowArtistRow(
              key: ValueKey('artist-row-${artist!.id}'),
              artist: artist,
              contentPadding: EdgeInsetsDirectional.fromSTEB(
                0,
                context.musicFlowSpacing.xs,
                0,
                context.musicFlowSpacing.xs,
              ),
              onPressed: () => Navigator.of(context).push<void>(
                MusicFlowPageRoute<void>(
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
