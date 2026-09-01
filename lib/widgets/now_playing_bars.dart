import 'dart:math';

import 'package:flutter/material.dart';

/// 播放中封面指示器：半透明阴影遮罩 + 3 根白色随机跳动的竖直长方形
/// （网易云「每日推荐」正在播放的视觉效果）。
///
/// 尺寸策略（自适应封面大小）：
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
    // 竖条高度在 0.38~0.62 封面高之间随机跳动，保证始终在封面内。
    final minBarHeight = size * 0.38;
    final maxBarHeight = size * 0.62;
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
    );
  }
}

/// 3 根独立相位随机跳动的竖条。
class _JumpingBars extends StatefulWidget {
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
  State<_JumpingBars> createState() => _JumpingBarsState();
}

class _JumpingBarsState extends State<_JumpingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  // 每根竖条独立相位/速度/幅度，形成「随机跳动」观感。
  static const List<double> _phases = [0.0, 1.7, 3.6];
  static const List<double> _speeds = [1.0, 1.35, 0.82];
  static const List<double> _amplitudes = [1.0, 0.72, 0.88];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final heightSpan = widget.maxBarHeight - widget.minBarHeight;
        final bars = <Widget>[
          for (var i = 0; i < 3; i++)
            _buildBar(
              t,
              phase: _phases[i],
              speed: _speeds[i],
              amplitude: _amplitudes[i],
              heightSpan: heightSpan,
            ),
        ];
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (var i = 0; i < bars.length; i++) ...<Widget>[
              if (i > 0) SizedBox(width: widget.barGap),
              bars[i],
            ],
          ],
        );
      },
    );
  }

  Widget _buildBar(
    double t, {
    required double phase,
    required double speed,
    required double amplitude,
    required double heightSpan,
  }) {
    // 多条正弦叠加形成「不规则跳动」：主波 + 高频次波。
    final wave = sin(2 * pi * (t * speed + phase)) * 0.7 +
        sin(2 * pi * (t * speed * 2.7 + phase * 1.3)) * 0.3;
    // 归一化到 0~1，再按幅度系数分配高度范围，保证三根互不相同。
    final normalized = (wave + 1) / 2;
    final height = widget.minBarHeight +
        heightSpan * (0.35 + 0.65 * normalized) * amplitude;
    return Container(
      width: widget.barWidth,
      height: height,
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(widget.barRadius),
      ),
    );
  }
}
