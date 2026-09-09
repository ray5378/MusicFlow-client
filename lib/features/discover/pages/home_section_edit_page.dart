import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/components/music_flow_app_bar.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/features/discover/home_section_registry.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/home_section_layout_provider.dart';

/// 首页分区编辑页（客户端自治）：
/// - 拖拽行把手调整分区顺序（保存后首页按用户顺序渲染）；
/// - 每行开关控制分区显隐（隐藏后首页不渲染该分区，也不再拉取其服务端数据）；
/// - 「完成」保存进 SharedPreferences 并返回，首页经 [homeSectionLayoutProvider]
///   即时重建，无需重启。
class HomeSectionEditPage extends ConsumerStatefulWidget {
  const HomeSectionEditPage({super.key});

  @override
  ConsumerState<HomeSectionEditPage> createState() =>
      _HomeSectionEditPageState();
}

class _HomeSectionEditPageState extends ConsumerState<HomeSectionEditPage> {
  /// 编辑中的分区顺序（含用户隐藏的分区，编辑页始终展示全部模块）。
  late List<String> _order;

  /// 编辑中被隐藏的分区 key。
  late Set<String> _hidden;

  @override
  void initState() {
    super.initState();
    final layout = ref.read(homeSectionLayoutProvider).valueOrNull ??
        HomeSectionLayout.empty;
    _order = buildHomeSectionEditOrder(layout);
    _hidden = Set<String>.of(layout.hidden);
  }

  void _handleReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      _order.insert(newIndex, _order.removeAt(oldIndex));
    });
  }

  void _toggleVisible(String key, bool visible) {
    setState(() {
      if (visible) {
        _hidden.remove(key);
      } else {
        _hidden.add(key);
      }
    });
  }

  Future<void> _saveAndClose() async {
    final layout = HomeSectionLayout(
      order: List<String>.of(_order),
      hidden: _hidden.toList(growable: false),
    );
    await ref.read(homeSectionLayoutProvider.notifier).save(layout);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final typography = context.musicFlowTypography;

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: MusicFlowAppBar(
        title: Text(loc.home_section_customize),
        // 完成按钮走 MusicFlowPressable 体系(CI 守卫禁止裸用 TextButton)。
        actions: <Widget>[
          Padding(
            padding: EdgeInsetsDirectional.only(end: spacing.xs),
            child: Center(
              child: MusicFlowButton.ghost(
                label: loc.home_section_customize_done,
                onPressed: _saveAndClose,
                height: 36,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.musicFlowPageHorizontalPadding - 5,
                spacing.sm,
                context.musicFlowPageHorizontalPadding - 5,
                spacing.xs,
              ),
              child: Text(
                loc.home_section_customize_hint,
                style: typography.metadata.copyWith(color: colors.muted),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                // 自定义把手(buildDefaultDragHandles=false):拖拽仅经行尾把手
                // 触发,避免与 Switch 手势冲突;把手用立即拖拽语义,桌面端
                // 鼠标与移动端长按体验一致。
                buildDefaultDragHandles: false,
                padding: EdgeInsets.fromLTRB(
                  context.musicFlowPageHorizontalPadding - 5,
                  0,
                  context.musicFlowPageHorizontalPadding - 5,
                  context.musicFlowSpacing.xxl +
                      context.musicFlowShellBottomObstruction,
                ),
                itemCount: _order.length,
                onReorder: _handleReorder,
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, child) {
                      final t = Curves.easeInOut.transform(animation.value);
                      return Material(
                        color: colors.raised,
                        borderRadius: context.musicFlowRadii.surface,
                        elevation: lerpDouble(0, 8, t)!,
                        shadowColor: colors.scrim,
                        child: child,
                      );
                    },
                    child: child,
                  );
                },
                itemBuilder: (context, index) {
                  final key = _order[index];
                  return _buildSectionRow(
                    context,
                    key: key,
                    index: index,
                    // 唯一 key:分区顺序变化时行状态不串位。
                    rowKey: ValueKey<String>('home-section-edit-$key'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionRow(
    BuildContext context, {
    required String key,
    required int index,
    required Key rowKey,
  }) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final typography = context.musicFlowTypography;
    final spacing = context.musicFlowSpacing;
    final visible = !_hidden.contains(key);

    return Material(
      key: rowKey,
      color: colors.surface,
      borderRadius: context.musicFlowRadii.surface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(spacing.md, spacing.xs, spacing.xs,
            spacing.xs),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                homeSectionDisplayName(loc, key),
                style: typography.body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 显隐开关:关闭后首页不渲染该分区,也不再拉取其服务端数据。
            Switch(
              value: visible,
              onChanged: (value) => _toggleVisible(key, value),
            ),
            // 拖拽把手:立即拖拽语义(非延迟),桌面端鼠标按住即拖。
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: EdgeInsets.all(spacing.sm),
                child: Icon(AppIcons.drag, size: 20, color: colors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
