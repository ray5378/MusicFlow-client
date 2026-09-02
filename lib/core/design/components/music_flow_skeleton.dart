import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_visibility_provider.dart';
import '../music_flow_context.dart';

class MusicFlowSkeleton extends ConsumerStatefulWidget {
  const MusicFlowSkeleton({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.borderRadius,
  });

  const MusicFlowSkeleton.line({
    super.key,
    this.width = double.infinity,
    this.height = 12,
  }) : borderRadius = const BorderRadius.all(Radius.circular(4));

  const MusicFlowSkeleton.circle({super.key, double size = 48})
    : width = size,
      height = size,
      borderRadius = const BorderRadius.all(Radius.circular(999));

  final double width;
  final double height;
  final BorderRadiusGeometry? borderRadius;

  @override
  ConsumerState<MusicFlowSkeleton> createState() => _MusicFlowSkeletonState();
}

class _MusicFlowSkeletonState extends ConsumerState<MusicFlowSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _animationsDisabled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 门控：系统减少动效 或 窗口不可见(失焦/最小化/切走) → 停止 shimmer，
    // 避免不可见区域持续空转重绘（智能按需渲染；窗口不可见同时被根
    // TickerMode 全局静音，这里再显式兜一层保证组件自洽可测）。
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final appVisible = ref.watch(appVisibilityProvider);
    final shouldAnimate = !disabled && appVisible;
    if (shouldAnimate) {
      _animationsDisabled = false;
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _animationsDisabled = true;
      _controller
        ..stop()
        ..value = 0.35;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final radius = widget.borderRadius ?? context.musicFlowRadii.detail;
    final base = colors.raised;
    final highlight = Color.alphaBlend(
      colors.ink.withValues(alpha: 0.08),
      base,
    );

    Widget block;
    if (_animationsDisabled) {
      block = DecoratedBox(
        decoration: BoxDecoration(color: base, borderRadius: radius),
      );
    } else {
      block = AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final progress = _controller.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment(-1.8 + progress * 3.6, 0),
                end: Alignment(-0.8 + progress * 3.6, 0),
                colors: <Color>[base, highlight, base],
                stops: const <double>[0, 0.5, 1],
              ),
            ),
          );
        },
      );
    }

    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: block,
        ),
      ),
    );
  }
}
