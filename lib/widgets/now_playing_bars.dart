import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/effective_playback_provider.dart';

/// 播放中封面指示器：半透明阴影遮罩 + 3 根白色随机跳动的竖直长方形
/// （网易云「每日推荐」正在播放的视觉效果——底部平整、跳动从底部往上）。
///
/// 尺寸策略（自适应封面大小）：
/// - 竖条组只占封面底部一小块（13%~23% 高度，约封面高的 1/3 不到）；
///   v3.4.61 由 20%~34% 整体压缩至 2/3，避免与下方播放按钮重叠且减少与
///   封面其它细节争抢视觉空间；
/// - 竖条底部贴齐（`CrossAxisAlignment.end`），高度变化只向上生长；
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
    // 竖条高度只占封面底部一小块（约 13%~23%），跳动方向从底部往上。
    // v3.4.61：从 20%~34%（v3.4.58）整体压缩到现在的 2/3，避免过厚。
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
            // RepaintBoundary:跳动竖条的每帧重绘隔离在竖条组内,
            // 绝不连带封面/整行列表重绘(智能按需渲染 §GPU 门控)。
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

/// 3 根独立相位随机跳动的竖条。
///
/// 播放状态门控：仅「有效播放中」才跳（暂停即冻结在当前高度），
/// 窗口不可见时由全局 TickerMode 静音（不再产生任何帧）。
class _JumpingBars extends ConsumerStatefulWidget {
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
  ConsumerState<_JumpingBars> createState() => _JumpingBarsState();
}

class _JumpingBarsState extends ConsumerState<_JumpingBars>
    with SingleTickerProviderStateMixin {
  // 方案 B：Ticker 手动限流到 ~60fps(每 16ms 才重绘一次)。相比每 vsync
  // (如 144Hz 显示器=144 帧/秒)rebuild,重绘频率减半以上,显著降低
  // 播放中常驻的 GPU/DWM 合成开销。窗口不可见时 TickerMode 自动静音。
  static const Duration _frameInterval = Duration(milliseconds: 16);
  // 跳动一圈 900ms(与原 AnimationController duration 一致),速度观感不变。
  static const int _cycleMicros = 900000;

  late final Ticker _ticker;

  /// 暂停后恢复用：保留冻结相位,续跳不跳变。
  double _baseT = 0;
  Duration _lastRender = Duration.zero;

  /// 当前驱动相位 0~1。
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastRender;
    if (delta < _frameInterval) return;
    _lastRender = elapsed;
    final raw = _baseT + elapsed.inMicroseconds / _cycleMicros;
    setState(() => _t = raw - raw.floorToDouble());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放状态门控：暂停不跳（冻结在当前高度），恢复播放从当前值续跳。
    // 放在 build 而非 didChangeDependencies：Riverpod 的 ref.watch 变化
    // 只触发 rebuild（ConsumerStatefulElement.watch → markNeedsBuild），
    // 不会触发 didChangeDependencies。
    final playing = ref.watch(effectiveIsPlayingProvider);
    if (playing) {
      if (!_ticker.isActive) {
        _baseT = _t; // 停/shut 后重启不跳变
        _lastRender = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }

    final totalWidth = widget.barWidth * 3 + widget.barGap * 2;
    return SizedBox(
      width: totalWidth,
      height: widget.maxBarHeight,
      child: CustomPaint(
        size: Size(totalWidth, widget.maxBarHeight),
        painter: JumpingBarsPainter(
          t: _t,
          barWidth: widget.barWidth,
          barGap: widget.barGap,
          radius: widget.barRadius,
          minHeight: widget.minBarHeight,
          maxHeight: widget.maxBarHeight,
          color: widget.color,
        ),
      ),
    );
  }
}

/// 3 根跳动竖条的合帧绘制器：单 CustomPainter 一次 drawRRect×3,
/// 替代原「Row + 3×Container」每帧例化多个 RenderObject + 布局 + 3 次绘制。
class JumpingBarsPainter extends CustomPainter {
  JumpingBarsPainter({
    required this.t,
    required this.barWidth,
    required this.barGap,
    required this.radius,
    required this.minHeight,
    required this.maxHeight,
    required this.color,
  });

  final double t;
  final double barWidth;
  final double barGap;
  final double radius;
  final double minHeight;
  final double maxHeight;
  final Color color;

  // 每根竖条独立相位/速度/幅度，形成「随机跳动」观感。
  static const List<double> _phases = [0.0, 1.7, 3.6];
  static const List<double> _speeds = [1.0, 1.35, 0.82];
  static const List<double> _amplitudes = [1.0, 0.72, 0.88];

  double _heightAt(int index) {
    final speed = _speeds[index];
    final phase = _phases[index];
    // 多条正弦叠加形成「不规则跳动」：主波 + 高频次波。
    final wave =
        sin(2 * pi * (t * speed + phase)) * 0.7 +
        sin(2 * pi * (t * speed * 2.7 + phase * 1.3)) * 0.3;
    // 归一化到 0~1，再按幅度系数分配高度范围，保证三根互不相同。
    final normalized = (wave + 1) / 2;
    return minHeight +
        (maxHeight - minHeight) *
            (0.35 + 0.65 * normalized) *
            _amplitudes[index];
  }

  /// 当前 3 根竖条的高度（自底向上生长，便于测试 / 合计绘制复用）。
  List<double> barHeights() => [_heightAt(0), _heightAt(1), _heightAt(2)];

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
      oldDelegate.t != t ||
      oldDelegate.color != color ||
      oldDelegate.barWidth != barWidth ||
      oldDelegate.barGap != barGap ||
      oldDelegate.radius != radius ||
      oldDelegate.minHeight != minHeight ||
      oldDelegate.maxHeight != maxHeight;
}
