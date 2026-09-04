import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/search.dart';
import '../../../providers/search_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../library/widgets/library_collection_components.dart';
import 'search_result_card.dart';

/// 聚合搜索结果：分块展示「本地结果」+「全网结果」。
///
/// 需求：去掉「聚合 / 本地 / 插件」来源切换，全部强制聚合搜索。
/// - 本地结果：本地库按关键词匹配（由各页面提供 [localBlock]）；
/// - 全网结果：已启用插件的合并搜索（卡片带插件·平台标签），
///   走 searchResultsProvider(SearchMode.aggregate)。
class AggregateSearchResults extends ConsumerWidget {
  const AggregateSearchResults({
    super.key,
    required this.kind,
    required this.query,
    required this.localBlock,
  });

  final SearchEntityKind kind;
  final String query;

  /// 「本地结果」块内容（本地库匹配项，非滚动）。
  final Widget localBlock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final request = SearchRequest(
      kind: kind,
      mode: SearchMode.aggregate,
      query: query,
      providerId: '',
    );
    final results = ref.watch(searchResultsProvider(request));

    return CustomScrollView(
      key: ValueKey<String>('aggregate-search-$kind-$query'),
      slivers: <Widget>[
        SliverToBoxAdapter(child: _SectionHeader(title: loc.search_local_results)),
        SliverToBoxAdapter(child: localBlock),
        const SliverToBoxAdapter(child: Divider(height: 28)),
        SliverToBoxAdapter(
          child: _SectionHeader(
            title: loc.search_network_results,
            subtitle: loc.search_network_results_subtitle,
          ),
        ),
        ..._networkSlivers(context, ref, request, results),
      ],
    );
  }

  List<Widget> _networkSlivers(
    BuildContext context,
    WidgetRef ref,
    SearchRequest request,
    AsyncValue<SearchOutcome> results,
  ) {
    final loc = AppLocalizations.of(context);
    return results.when(

      loading: () => const <Widget>[
        SliverToBoxAdapter(child: MusicFlowMediaListSkeleton(count: 6)),
      ],
      error: (e, _) => <Widget>[
        SliverToBoxAdapter(
          child: MusicFlowErrorState(
            title: loc.search_network_search_failed,
            description: '$e',
            actionLabel: loc.widgets_retry,
            onAction: () =>
                ref.invalidate(searchResultsProvider(request)),
          ),
        ),
      ],
      data: (outcome) {
        final empty = outcome.songs.isEmpty &&
            outcome.albums.isEmpty &&
            outcome.artists.isEmpty &&
            outcome.playlists.isEmpty;
        if (empty) {
          return <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: MusicFlowEmptyState(
                  title: loc.search_network_no_results,
                  description: loc.search_try_another_keyword,
                  icon: AppIcons.search,
                ),
              ),
            ),
          ];
        }
        return <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: context.musicFlowSpacing.xxl +
                    context.musicFlowShellBottomObstruction,
              ),
              child: SearchResultList(kind: kind, outcome: outcome),
            ),
          ),
        ];
      },
    );
  }
}

/// 「本地结果」块：按关键词拉取本地库匹配项。
/// [grid] 为 true 时渲染卡片网格（对齐全网结果的卡片网格，专辑/歌单）；
/// 为 false 时渲染纵向行（歌曲/歌手）。
class AggregateLocalBlock<T> extends StatelessWidget {
  const AggregateLocalBlock({
    super.key,
    required this.fetcher,
    required this.itemBuilder,
    required this.emptyText,
    this.grid = false,
    this.limit = 12,
  });

  final Future<({List<T> items, int total})> Function() fetcher;

  /// 构建本地匹配项；[index] 为该匹配项在展示列表中的序号，
  /// 调用方可据此做「点哪首播哪首」等行内操作。
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final String emptyText;
  final bool grid;
  final int limit;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({List<T> items, int total})>(
      future: fetcher(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: MusicFlowMediaListSkeleton(count: 3),
          );
        }
        final items = snapshot.data?.items ?? <T>[];
        if (items.isEmpty) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowPageHorizontalPadding,
              context.musicFlowSpacing.xxs,
              context.musicFlowPageHorizontalPadding,
              context.musicFlowSpacing.xs,
            ),
            child: Text(
              emptyText,
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          );
        }
        final shown = items.take(limit).toList();
        if (!grid) {
          return Column(
            children: <Widget>[
              for (final (i, item) in shown.indexed)
                itemBuilder(context, item, i),
            ],
          );
        }
        // 卡片网格:与全网结果的 SearchResultList._cardGrid 完全一致
        // (桌面端自适应列数 / 移动端三列 / childAspectRatio 0.8 / 同间距),
        // 保证本地结果与全网结果排列方式一致。
        final padding = EdgeInsets.only(
          left: context.musicFlowPageHorizontalPadding,
          right: context.musicFlowPageHorizontalPadding,
          top: context.musicFlowSpacing.xs,
          bottom: context.musicFlowSpacing.sm,
        );
        if (context.musicFlowWindowClass != MusicFlowWindowClass.compact) {
          return GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: padding,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 158,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.8,
            ),
            children: <Widget>[
              for (final (i, item) in shown.indexed)
                itemBuilder(context, item, i),
            ],
          );
        }
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          childAspectRatio: 0.8,
          padding: padding,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          children: <Widget>[
            for (final (i, item) in shown.indexed)
              itemBuilder(context, item, i),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.sm,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: context.musicFlowTypography.label.copyWith(
              color: context.musicFlowColors.accent,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: context.musicFlowTypography.metadata.copyWith(
                  color: context.musicFlowColors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
