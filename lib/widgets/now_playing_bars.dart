import 'package:flutter/material.dart';

/// 播放中封面指示器：半透明阴影遮罩 + 3 根白色竖直长方形的静态标志
/// （网易云「每日推荐」正在播放的视觉效果——底部平整，竖条从底部往上生长）。
///
/// v3.4.75：由「随机跳动」改为「静态标志」。此前 3 根竖条持续随机跳动，
/// 即便降帧/合并绘制仍是常驻动画，每帧触发绘制合成；经用户确认,改为纯静态
/// 标志——3 根固定高度的竖条一次渲染,不产生任何持续动画与合成开销。
///
/// 尺寸策略（自适应封面大小）：
/// - 竖条组只占封面底部一小块（13%~23% 高度，约封面高的 1/3 不到）；
/// - 竖条底部贴齐（`CrossAxisAlignment.end`），高度只向上生长；
/// - 竖条宽度/间距/圆角/遮罩内边距全部按 [size] 等比缩放；
/// - [alignment] 为 [Alignment.bottomRight] 时（大封面/首页卡片）竖条组
///   落在封面右下角；[Alignment.center] 时（队列小封面）竖条组正中间；
/// - 遮罩为半透明黑色圆角矩形，只包裹竖条组，不覆盖整张封面。
class NowPlayingCoverOverlay extends StatelessWidget {
  const NowPlayingCoverOverlay({
    super.key,
    required this.size,
    this.alignment = Alignment.bottomRight,
    this.barColor = Colors.white,
    this.scrim = Colors.black45,
  });

  /// 封面边长（逻辑像素），用于等比计算竖条与遮罩尺寸。
  final double size;

  /// 竖条组对齐方式：大封面右下角 / 小封面正中间。
  final Alignment alignment;

  /// 竖条颜色（默认白色）。
  final Color barColor;

  /// 遮罩颜色（默认半透明黑）。
  final Color scrim;

  @override
  Widget build(BuildContext context) {
    // 等比比例基准：以 160px 封面为设计基准；小封面（队列 48~56）不低于
    // 0.55，保证竖条清晰可辨。
    final k = (size / 160).clamp(0.55, 3.0);
    // 竖条宽 6、间距 4.5、圆角 2（160 基准），随封面缩放。
    final barWidth = 6.0 * k;
    final barGap = 4.5 * k;
    final barRadius = 2.0 * k;
    // 竖条高度只占封面底部一小块（约 13%~23%）。
    final minBarHeight = size * 0.13;
    final maxBarHeight = size * 0.23;
    // 遮罩内边距（竖条组四周）与竖条宽相当。
    final scrimPadding = 7.0 * k;

    return Align(
      alignment: alignment,
      child: Padding(
        // 距封面边缘的偏移：与遮罩内边距一致，避免竖条贴边。
        padding: EdgeInsets.all(scrimPadding),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scrim,
            borderRadius: BorderRadius.circular(barRadius + scrimPadding),
          ),
          child: Padding(
            padding: EdgeInsets.all(scrimPadding),
            // RepaintBoundary:静态竖条一次光栅化后作为独立 layer 缓存。
            child: RepaintBoundary(
              child: _JumpingBars(
                barWidth: barWidth,
                barGap: barGap,
                barRadius: barRadius,
                minBarHeight: minBarHeight,
                maxBarHeight: maxBarHeight,
                color: barColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 3 根固定高度的静态竖条标志（名称沿用 `_JumpingBars` 以最小化改动，
/// 实际已不跳动）。
class _JumpingBars extends StatelessWidget {
  const _JumpingBars({
    required this.barWidth,
    required this.barGap,
    required this.barRadius,
    required this.minBarHeight,
    required this.maxBarHeight,
    required this.color,
  });

  final double barWidth;
  final double barGap;
  final double barRadius;
  final double minBarHeight;
  final double maxBarHeight;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final totalWidth = barWidth * 3 + barGap * 2;
    return SizedBox(
      width: totalWidth,
      height: maxBarHeight,
      child: CustomPaint(
        size: Size(totalWidth, maxBarHeight),
        painter: JumpingBarsPainter(
          barWidth: barWidth,
          barGap: barGap,
          radius: barRadius,
          minHeight: minBarHeight,
          maxHeight: maxBarHeight,
          color: color,
        ),
      ),
    );
  }
}

/// 3 根静态竖条的合帧绘制器：单 CustomPainter 一次 drawRRect×3,
/// 高度固定、不随时间变化——一次绘制后即静止，零持续合成。
class JumpingBarsPainter extends CustomPainter {
  JumpingBarsPainter({
    required this.barWidth,
    required this.barGap,
    required this.radius,
    required this.minHeight,
    required this.maxHeight,
    required this.color,
  });

  final double barWidth;
  final double barGap;
  final double radius;
  final double minHeight;
  final double maxHeight;
  final Color color;

  // 固定高度系数（0~1，乘高度区间得到每根高度）：静态均衡器形状，
  // 三根互不相同、永不变化，作为「正在播放」的纯静态标志。
  static const List<double> _staticLevels = [0.55, 0.92, 0.68];

  /// 当前 3 根竖条的高度（自底向上生长，便于测试复用）。
  List<double> barHeights() => [
    for (final level in _staticLevels)
      minHeight + (maxHeight - minHeight) * level,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final heights = barHeights();
    for (var i = 0; i < 3; i++) {
      final x = i * (barWidth + barGap);
      final h = heights[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barWidth, h),
          Radius.circular(radius),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(JumpingBarsPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.barWidth != barWidth ||
      oldDelegate.barGap != barGap ||
      oldDelegate.radius != radius ||
      oldDelegate.minHeight != minHeight ||
      oldDelegate.maxHeight != maxHeight;
}
