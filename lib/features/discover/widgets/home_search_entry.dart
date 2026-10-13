import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/discover/discover_page_support.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// 首页顶部搜索入口:点击进入搜索页(自动聚焦并浮出搜索范围)。
///
/// 只读入口,不持有输入状态:首页只负责跳转,所有输入都在搜索页完成,
/// 避免首页与搜索页两份输入状态不同步。
///
/// 从 `discover_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class HomeSearchEntry extends StatelessWidget {
  const HomeSearchEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    // Windows 无系统标题栏:右上角是窗口控制按钮(最小化/最大化/关闭),
    // 搜索条右侧留出等宽空白,避免被按钮压住。
    final rightInset = isWindowsDesktop ? kWindowsWindowControlsWidth : 0.0;
    // 与下方内容分区同一套约束(Align topCenter + maxWidth 1400):宽窗口下
    // 分区被 maxWidth 居中收窄,搜索框若留在约束盒外会贴窗口左缘,
    // 永远对不齐内容区左缘(分区标题栏)。套进同一约束后左缘恒对齐。
    // 注意:约束盒内必须用 SizedBox 撑满宽度——ConstrainedBox 是收缩包裹,
    // 若直接放 widthFactor 0.5 的 FractionallySizedBox,整条链会收缩成
    // 半宽并被外层 Align 居中,搜索框反而跑到窗口正中间。
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
          key: const ValueKey<String>('home-search-entry'),
          padding: EdgeInsets.fromLTRB(
            context.musicFlowPageHorizontalPadding - 5,
            // 整体下移 10px,让搜索条与侧边栏顶部留白节奏一致。
            spacing.sm + 10,
            context.musicFlowPageHorizontalPadding - 5 + rightInset,
            spacing.sm,
          ),
          // 首页大搜索框占满整行过于臃肿,收窄为可用宽度的一半并左对齐,
          // 保留原左侧位置(入口仅 Windows 等宽屏渲染)。
          child: FractionallySizedBox(
            widthFactor: 0.5,
            alignment: Alignment.centerLeft,
            child: MusicFlowPressable(
              semanticLabel: loc.discover_search,
              onPressed: () => openSearchPage(context),
              borderRadius: context.musicFlowRadii.pill,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: context.musicFlowRadii.pill,
                  border:
                      Border.all(color: colors.controlBoundary, width: 0.5),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(AppIcons.search, size: 20, color: colors.muted),
                    SizedBox(width: spacing.sm),
                    Expanded(
                      child: Text(
                        loc.search_hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.body.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
