import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox;


/// 按参考稿对分区做整体位移：视觉上把 [child] 向上移 |top|、占位高度收缩
/// |top|+|bottom|（等价于历史「负 EdgeInsets 的 Padding」，但负 Padding 在
/// debug 下触发 RenderPadding 的 padding.isNonNegative 断言会把整块分区从
/// 树上摘除，故用自绘 RenderObject 实现）。
class SectionShift extends SingleChildRenderObjectWidget {
  const SectionShift({
    required this.top,
    required this.bottom,
    required Widget child,
  }) : super(child: child);

  /// 负值表示整体上移的像素数。
  final double top;

  /// 负值表示底部占位收缩的像素数。
  final double bottom;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSectionShift(top, bottom);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSectionShift renderObject,
  ) {
    renderObject
      ..top = top
      ..bottom = bottom;
  }
}

class _RenderSectionShift extends RenderProxyBox {
  _RenderSectionShift(this._top, this._bottom);

  double _top;
  double _bottom;

  set top(double value) {
    if (_top == value) return;
    _top = value;
    markNeedsLayout();
  }

  set bottom(double value) {
    if (_bottom == value) return;
    _bottom = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // 与 Padding 的 deflate 语义一致：负 EdgeInsets 会放宽子组件的
    // 高度上限，这里等量放宽，保证子组件按自然高度布局。
    final childConstraints = constraints.hasInfiniteHeight
        ? constraints
        : constraints.copyWith(
            maxHeight: constraints.maxHeight - (_top + _bottom),
          );
    child!.layout(childConstraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(child!.size.width, child!.size.height + _top + _bottom),
    );
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final childBaseline = child?.getDistanceToActualBaseline(baseline);
    return childBaseline == null ? null : childBaseline + _top;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return child?.hitTest(result, position: position - Offset(0, _top)) ?? false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child != null) {
      context.paintChild(child!, offset + Offset(0, _top));
    }
  }
}
