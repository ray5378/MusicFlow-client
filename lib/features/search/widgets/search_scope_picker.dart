import 'package:flutter/material.dart';

import '../../../core/design/music_flow_design.dart';
import '../search_scope.dart';

/// 搜索范围切换器(五档 pill):所有 / 歌单 / 音乐 / 艺术家 / 专辑。
///
/// 与 [SearchScopePanel] 使用同一组枚举与文案,保证「浮层里选的」和
/// 「pill 上显示的」永远一致。
class SearchScopeTabs extends StatelessWidget {
  const SearchScopeTabs({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final SearchScope value;
  final ValueChanged<SearchScope> onChanged;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    return Semantics(
      container: true,
      label: '搜索范围',
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowPageHorizontalPadding,
          ),
          itemCount: SearchScope.values.length,
          separatorBuilder: (_, _) => SizedBox(width: spacing.xs),
          itemBuilder: (context, index) {
            final scope = SearchScope.values[index];
            return _ScopePill(
              label: scope.label,
              selected: scope == value,
              onPressed: () => onChanged(scope),
            );
          },
        ),
      ),
    );
  }
}

class _ScopePill extends StatelessWidget {
  const _ScopePill({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final radii = context.musicFlowRadii;
    return MusicFlowPressable(
      semanticLabel: label,
      selected: selected,
      onPressed: onPressed,
      borderRadius: radii.pill,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? colors.accent : colors.surface,
          borderRadius: radii.pill,
          border: Border.all(
            color: selected ? colors.accent : colors.controlBoundary,
            width: 0.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: context.musicFlowTypography.label.copyWith(
              color: selected ? colors.onAccent : colors.muted,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索范围浮层:输入框聚焦时在其下方浮出,列出五档范围及说明。
///
/// 交互(方案 A):浮层浮出时输入框**仍然可输入**,用户可以直接打字;
/// 一旦输入了关键词,由页面收起浮层让位给结果,无需先选范围。
class SearchScopePanel extends StatelessWidget {
  const SearchScopePanel({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final SearchScope value;
  final ValueChanged<SearchScope> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    return Semantics(
      container: true,
      label: '选择搜索范围',
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: context.musicFlowRadii.surface,
          border: Border.all(color: colors.controlBoundary, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                spacing.md,
                spacing.sm,
                spacing.md,
                spacing.xxs,
              ),
              child: Text(
                '搜索范围',
                style: context.musicFlowTypography.metadata.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
            for (final scope in SearchScope.values)
              _ScopeRow(
                scope: scope,
                selected: scope == value,
                onPressed: () => onChanged(scope),
              ),
            SizedBox(height: spacing.xxs),
          ],
        ),
      ),
    );
  }
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
    required this.scope,
    required this.selected,
    required this.onPressed,
  });

  final SearchScope scope;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    return MusicFlowPressable(
      semanticLabel: scope.label,
      selected: selected,
      onPressed: onPressed,
      borderRadius: context.musicFlowRadii.detail,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.md,
          vertical: spacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: context.musicFlowTypography.body.copyWith(
                    color: selected ? colors.accent : colors.ink,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  ),
                  children: <TextSpan>[
                    TextSpan(text: scope.label),
                    TextSpan(
                      text: '  ${scope.description}',
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: colors.muted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (selected) ...<Widget>[
              SizedBox(width: spacing.xs),
              Icon(Icons.check_rounded, size: 20, color: colors.accent),
            ],
          ],
        ),
      ),
    );
  }
}
