import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/search_history.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/features/search/search_history.dart';
import 'package:musicflow_client/features/discover/widgets/search_result_blocks.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 热门搜索(本地兜底:来自收藏的艺术家/专辑名)。
class HotSearchBlock extends ConsumerWidget {
  const HotSearchBlock({required this.onTap});

  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final async = ref.watch(hotSearchTermsProvider);
    final terms = async.valueOrNull ?? const <String>[];
    if (terms.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SearchBlockHeader(title: loc.search_hot_search),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowPageHorizontalPadding,
          ),
          child: SearchTermWrap(terms: terms, onTap: onTap),
        ),
      ],
    );
  }
}

/// 搜索历史(持久化,支持单条删除与清空)。
class SearchHistoryBlock extends ConsumerWidget {
  const SearchHistoryBlock({required this.onTap});

  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final async = ref.watch(searchHistoryProvider);
    final entries = async.valueOrNull ?? const <SearchHistoryEntry>[];
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.musicFlowPageHorizontalPadding,
            context.musicFlowSpacing.xs,
            context.musicFlowPageHorizontalPadding - 5,
            context.musicFlowSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              Expanded(child: SearchBlockHeader(title: loc.search_history)),
              MusicFlowIconButton(
                icon: AppIcons.delete,
                label: loc.search_clear_history,
                iconSize: 20,
                onPressed: () =>
                    ref.read(searchHistoryProvider.notifier).clear(),
              ),
            ],
          ),
        ),
        for (final entry in entries)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  AppIcons.history,
                  size: 18,
                  color: context.musicFlowColors.muted,
                ),
                SizedBox(width: context.musicFlowSpacing.sm),
                Expanded(
                  child: MusicFlowPressable(
                    semanticLabel: loc.search_search_term_semantics(entry.query),
                    onPressed: () => onTap(entry.query),
                    minimumSize: const Size.fromHeight(44),
                    borderRadius: context.musicFlowRadii.detail,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        entry.query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.body,
                      ),
                    ),
                  ),
                ),
                MusicFlowIconButton(
                  icon: AppIcons.close,
                  label: loc.search_delete_history(entry.query),
                  iconSize: 18,
                  onPressed: () => ref
                      .read(searchHistoryProvider.notifier)
                      .remove(entry.query),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 关键词 chip 云（热门搜索）。
class SearchTermWrap extends StatelessWidget {
  const SearchTermWrap({required this.terms, required this.onTap});

  final List<String> terms;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    return Wrap(
      spacing: spacing.xs,
      runSpacing: spacing.xs,
      children: <Widget>[
        for (final term in terms)
          MusicFlowPressable(
            semanticLabel: loc.search_search_term_semantics(term),
            onPressed: () => onTap(term),
            borderRadius: context.musicFlowRadii.pill,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: context.musicFlowRadii.pill,
                border: Border.all(color: colors.controlBoundary, width: 0.5),
              ),
              child: Text(term, style: context.musicFlowTypography.body),
            ),
          ),
      ],
    );
  }
}
