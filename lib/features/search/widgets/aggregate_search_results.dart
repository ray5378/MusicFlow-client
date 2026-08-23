import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/search.dart';
import '../../../providers/search_provider.dart';
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
        SliverToBoxAdapter(child: _SectionHeader(title: '本地结果')),
        SliverToBoxAdapter(child: localBlock),
        const SliverToBoxAdapter(child: Divider(height: 28)),
        const SliverToBoxAdapter(
          child: _SectionHeader(
            title: '全网结果',
            subtitle: '已启用插件的合并搜索，卡片带插件·平台标签',
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
    return results.when(
      loading: () => const <Widget>[
        SliverToBoxAdapter(child: EchoMediaListSkeleton(count: 6)),
      ],
      error: (e, _) => <Widget>[
        SliverToBoxAdapter(
          child: EchoErrorState(
            title: '全网搜索失败',
            description: '$e',
            actionLabel: '重试',
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
          return const <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: EchoEmptyState(
                  title: '全网暂无结果',
                  description: '换个关键词试试。',
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
                bottom: context.echoSpacing.xxl +
                    context.echoShellBottomObstruction,
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

  /// 构建本地匹配项；[width] 为网格单元宽度（非网格布局时传 0，忽略）。
  final Widget Function(BuildContext context, T item, double width)
      itemBuilder;
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
            child: EchoMediaListSkeleton(count: 3),
          );
        }
        final items = snapshot.data?.items ?? <T>[];
        if (items.isEmpty) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              context.echoPageHorizontalPadding,
              context.echoSpacing.xxs,
              context.echoPageHorizontalPadding,
              context.echoSpacing.xs,
            ),
            child: Text(
              emptyText,
              style: context.echoTypography.metadata.copyWith(
                color: context.echoColors.muted,
              ),
            ),
          );
        }
        final shown = items.take(limit).toList();
        if (!grid) {
          return Column(
            children: <Widget>[
              for (final item in shown) itemBuilder(context, item, 0),
            ],
          );
        }
        // 卡片网格：与全网结果的网格观感一致（宽屏 3 列，窄屏 2 列）。
        return LayoutBuilder(
          builder: (context, constraints) {
            final gap = context.echoSpacing.sm;
            final columns = constraints.maxWidth >= 900 ? 3 : 2;
            final itemWidth =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.echoPageHorizontalPadding,
              ),
              child: Wrap(
                spacing: gap,
                runSpacing: context.echoSpacing.sm,
                children: <Widget>[
                  for (final item in shown)
                    SizedBox(
                      width: itemWidth,
                      child: itemBuilder(context, item, itemWidth),
                    ),
                ],
              ),
            );
          },
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
        context.echoPageHorizontalPadding,
        context.echoSpacing.sm,
        context.echoPageHorizontalPadding,
        context.echoSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: context.echoTypography.label.copyWith(
              color: context.echoColors.accent,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: context.echoTypography.metadata.copyWith(
                  color: context.echoColors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
