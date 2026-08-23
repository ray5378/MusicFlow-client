import 'package:flutter/material.dart';

import '../../../core/design/echo_design.dart';
import 'windowed_paginated_list.dart';

/// 全库统一的「窗口化 + 视口渐进式加载」列表渲染层。
///
/// 配合 [WindowedPaginatedList] 使用:
/// - `SliverList.builder` 只为可见+cacheExtent 的行调用 builder —— 虚拟滚动;
/// - builder 内按行触发 [WindowedPaginatedList.ensureRange],滚动到哪拉到哪
///   (按 page/pageSize 分块),未到达的槽位渲染占位骨架 —— 视口渐进式加载;
/// - 窗口外的旧块由 controller 剪枝置 null,内存峰值恒定 —— 窗口化渲染。
class WindowedListView<T> extends StatefulWidget {
  const WindowedListView({
    super.key,
    required this.controller,
    required this.itemBuilder,
    this.placeholderExtent = 72,
    this.padding,
    this.emptyTitle = '暂无内容',
    this.emptyDescription = '',
    this.emptyIcon,
    this.gridDelegate,
  });

  final WindowedPaginatedList<T> controller;

  /// [item] 为 null 表示该槽位尚未加载(占位)。
  final Widget Function(BuildContext context, int index, T? item) itemBuilder;

  /// 占位骨架的估算高度。
  final double placeholderExtent;

  final EdgeInsetsGeometry? padding;
  final String emptyTitle;
  final String emptyDescription;
  final IconData? emptyIcon;

  /// 提供时用 SliverGrid 渲染(卡片网格),否则 SliverList。
  final SliverGridDelegate? gridDelegate;

  @override
  State<WindowedListView<T>> createState() => _WindowedListViewState<T>();
}

class _WindowedListViewState<T> extends State<WindowedListView<T>> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    if (widget.controller.total <= 0 && !widget.controller.loading) {
      widget.controller.load('');
    }
  }

  @override
  void didUpdateWidget(covariant WindowedListView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      if (widget.controller.total <= 0 && !widget.controller.loading) {
        widget.controller.load('');
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 渐进式核心:builder 只会为可见/缓存行调用,
  /// 每次触达都推进分块预取窗口;未加载槽位渲染占位骨架。
  Widget _buildItem(BuildContext context, int index) {
    final controller = widget.controller;
    // builder 运行于 build/layout 阶段:预取必须延后到帧末,
    // 否则 notifyListeners 会在同帧触发 "element dirty" 断言。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller.ensureRange(index, index),
    );
    final item = controller[index];
    if (item != null) {
      return widget.itemBuilder(context, index, item);
    }
    if (widget.gridDelegate != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: EchoSkeleton(
          width: double.infinity,
          height: double.infinity,
          borderRadius: context.echoRadii.surface,
        ),
      );
    }
    return SizedBox(
      height: widget.placeholderExtent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: EchoSkeleton(
          width: double.infinity,
          height: widget.placeholderExtent - 16,
          borderRadius: context.echoRadii.detail,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    if (controller.hasError && controller.total == 0) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${controller.error}',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: controller.retry,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (controller.total == 0 &&
        !controller.loading &&
        controller.slots.isEmpty) {
      return Center(
        child: EchoEmptyState(
          title: widget.emptyTitle,
          description: widget.emptyDescription,
          icon: widget.emptyIcon ?? AppIcons.music,
        ),
      );
    }

    final total = controller.total > 0
        ? controller.total
        : controller.pageSize; // 首块在途:先铺一页占位

    return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: widget.padding ?? EdgeInsets.zero,
            sliver: widget.gridDelegate == null
                ? SliverList.builder(
                    itemCount: total,
                    itemBuilder: _buildItem,
                  )
                : SliverGrid.builder(
                    gridDelegate: widget.gridDelegate!,
                    itemCount: total,
                    itemBuilder: _buildItem,
                  ),
          ),
          if (controller.loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: context.echoShellBottomObstruction),
          ),
        ],
    );
  }
}
