import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/app_visibility_provider.dart';
import 'package:musicflow_client/providers/ui/connection_beacon_provider.dart';

/// 中心点直径（8px，常亮不缩放）。
const double _dotSize = 8;

/// 心跳槽位边长（28px）。
///
/// **必须固定**：扩散环最大扩到中心点的 [_ringMaxScale] 倍（8 → 24），
/// 若槽位跟着环一起变大，整个胶囊会随动画膨胀收缩，比不动画还难看。
/// 28 给 24 的环留 2px 余量；环在槽位内部按真实尺寸扩张，
/// `clipBehavior: Clip.none` 只作兜底，胶囊的几何尺寸全程稳定。
const double _slotSize = 28;

/// 一次心跳的总周期。
const Duration _pulseDuration = Duration(milliseconds: 1600);

/// 扩散阶段占整个周期的比例（前 45% 扩散，后 55% 静默）。
///
/// 1600ms × 45% ≈ 720ms 扩散、≈ 880ms 静默 —— 肉眼是「咚……咚……」的
/// 心跳节奏，而不是连续的雷达扫描。
const double _pulseActiveFraction = 0.45;

/// 环的最大直径倍数（相对中心点直径）：8 × 3 = 24px。
///
/// 半径从 4 长到 12（+8px）才有肉眼可见的「扩出去」；原先的 2.2 倍
/// 只到 17.6px，半径仅变化 4.8px，看起来像「没在跳」。
const double _ringMaxScale = 3.0;

/// 环的起始不透明度（扩散到最大时衰减到 0）。
const double _ringMaxOpacity = 0.55;

/// 环的描边宽度。**只用描边、不填充**：实心圆放大会糊成一团，
/// 描边环才有「光圈」质感。
const double _ringBorderWidth = 1.2;

/// 冷启动连接状态心跳提示。
///
/// 一个贴顶部居中、绝不接收手势的小胶囊：
/// - 灰点 + 「连接中…」/「连接已断开，正在重连」 = 未连接；
/// - 绿点 + 「已连接」 = 已连接（[kBeaconConnectedLinger] 后自动隐藏）。
///
/// 刻意**不**复用 `music_flow_message.dart` 的 toast 通道：那是固定右上角、
/// 只收 String 的一次性提示，和常驻心跳的定位、生命周期都不一样，混用会打架。
///
/// 可见性/文案全部来自 `connectionBeaconProvider`（状态机），本组件只负责：
/// 渲染、扩散环心跳动画、减少动效与窗口不可见时停帧。
class ConnectionBeacon extends ConsumerStatefulWidget {
  const ConnectionBeacon({super.key});

  @override
  ConsumerState<ConnectionBeacon> createState() => _ConnectionBeaconState();
}

class _ConnectionBeaconState extends ConsumerState<ConnectionBeacon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _pulseDuration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 减少动效开关随 MediaQuery 变化会走这里；同步一次心跳状态。
    _syncBreathing();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 按「是否需要跳动」启停 [AnimationController]。
  ///
  /// 只做 start/stop，**不写** `controller.value`：本方法会从
  /// `didChangeDependencies`（构建期）被调用，写 value 会通知已经在树上的
  /// `AnimatedBuilder` 触发 `markNeedsBuild`，踩「setState during build」。
  /// 静止时的圆点形态由 build 直接渲染（见 [_buildDot]），不依赖动画值。
  ///
  /// 用 `repeat()` 而**不是** `repeat(reverse: true)`：扩散是单向的（由内向外
  /// 边扩边淡），反向播放会变成「缩回来」，那就不是心跳了。
  void _syncBreathing() {
    if (!mounted) return;
    final phase = ref.read(connectionBeaconProvider).phase;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final renderingActive = ref.read(isRenderingActiveProvider);
    final shouldBreathe =
        phase != ConnectionBeaconPhase.hidden &&
        !reduceMotion &&
        renderingActive;
    if (shouldBreathe) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
      return;
    }
    if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(connectionBeaconProvider);
    // 窗口不可见（最小化 / 隐藏到托盘）时只停动画，**不**隐藏组件本身：
    // 恢复前台要立刻可见，不该再走一次进出场。启停落在 _syncBreathing。
    ref.watch(isRenderingActiveProvider);

    // 窗口不可见 / 连通性变化都来自 provider，用 listen 触发副作用
    // （build 里读到的值只用于渲染，不承担启停控制器的职责）。
    ref.listen<ConnectionBeaconState>(connectionBeaconProvider, (previous, next) {
      if (previous == next) return;
      _syncBreathing();
    });
    ref.listen<bool>(isRenderingActiveProvider, (previous, next) {
      if (previous == next) return;
      _syncBreathing();
    });

    final loc = AppLocalizations.of(context);
    final motion = context.musicFlowMotion;
    final duration = motion.resolve(context, motion.state);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final label = _labelFor(loc, state);
    final visible = state.isVisible;

    // 绝不吃手势：心跳提示永远不参与命中测试。
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: motion.easeOut,
        switchOutCurve: motion.easeOut,
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(opacity: animation, child: child);
        },
        child: visible
            // b43a 最终结论（真机 v5.16.1，2026-10）：即使去掉 `liveRegion`，
            // 双黄线仍在 —— 线不是自动播报的产物，而是系统侧服务（识屏/朗读/
            // 自动跳过类无障碍服务）对「文本节点内容在变化」这一事实本身的
            // 视觉高亮，直接画在 Semantics 文本节点上。心跳胶囊是启动阶段
            // 唯一频繁变化的文本节点（连接中→已连接→隐藏），因此成了稳定的
            // 高亮目标。
            //
            // 胶囊是纯视觉的瞬时状态指示器：文字瞬时变化、不可交互、也不
            // 承载唯一信息入口（连接状态在设置页/诊断日志里另有稳定入口）。
            // 因此把它**整体从无障碍树摘除**（ExcludeSemantics）：读屏用户
            // 不再听到这条瞬时提示，但系统服务也没有了可标注的节点，双黄线
            // 从根上消失。若未来需要向视障用户提供连接状态，正确做法是走
            // 系统通知渠道，而不是恢复这个会被厂商服务标注的 Semantics
            // 文本节点。
            ? ExcludeSemantics(
                key: ValueKey<ConnectionBeaconPhase>(state.phase),
                child: _buildPill(
                  context: context,
                  state: state,
                  label: label,
                  reduceMotion: reduceMotion,
                ),
              )
            : const SizedBox.shrink(
                key: ValueKey<String>('connection-beacon-hidden'),
              ),
      ),
    );
  }

  /// 胶囊本体：20px 心跳槽位（扩散环 + 8px 圆点）+ 一行 metadata 文案。
  Widget _buildPill({
    required BuildContext context,
    required ConnectionBeaconState state,
    required String label,
    required bool reduceMotion,
  }) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final radii = context.musicFlowRadii;
    final typography = context.musicFlowTypography;

    // 未连接一律灰色（刻意不用 colors.error：用户明确要求不出现红色）。
    final dotColor = state.isConnected ? colors.accent : colors.muted;

    return MusicFlowSurface(
      level: MusicFlowSurfaceLevel.floating,
      borderRadius: radii.pill,
      padding: EdgeInsets.symmetric(
        horizontal: spacing.sm,
        vertical: spacing.xxs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _buildDot(color: dotColor, animate: !reduceMotion),
          SizedBox(width: spacing.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.metadata.copyWith(color: colors.muted),
            ),
          ),
        ],
      ),
    );
  }

  /// 心跳槽位：固定 28x28 的 `Stack`，中心是常亮 8px 圆点，外围是扩散环。
  ///
  /// [animate] 为 false（减少动效）时**环整个不渲染**，只留静态中心点 ——
  /// 不是把环的不透明度设成 1.0 让它静止：静止的环看起来像个脏点。
  Widget _buildDot({required Color color, required bool animate}) {
    final Widget dot = SizedBox.square(
      dimension: _dotSize,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
    // RepaintBoundary 隔离：扩散环每帧重绘只发生在本边界内，
    // 不连带胶囊文字与父级（gpu_guard_scan 防线要求）。
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: _slotSize,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[
            if (animate) _PulseRing(controller: _controller, color: color),
            // 中心点常亮、**不缩放**：让环去表达跳动，点保持稳定，
            // 否则两者一起动会互相抢注意力。
            dot,
          ],
        ),
      ),
    );
  }

  /// 三个 phase 对应的文案（灰色态按 reason 分两句）。
  static String _labelFor(AppLocalizations loc, ConnectionBeaconState state) {
    return switch (state.phase) {
      ConnectionBeaconPhase.hidden => '',
      ConnectionBeaconPhase.connected => loc.connection_beacon_connected,
      ConnectionBeaconPhase.waiting =>
        state.reason == ConnectionBeaconReason.coldStart
            ? loc.connection_beacon_connecting
            : loc.connection_beacon_reconnecting,
    };
  }
}

/// 由内向外扩散、边扩边淡的「光圈」。
///
/// 一个 [_pulseDuration] 周期内：
/// | 进度 t | 表现 |
/// |---|---|
/// | `0 → _pulseActiveFraction` | 直径 8 → 24，opacity [_ringMaxOpacity] → 0，进度经 `Curves.easeOutCubic`（先快后慢，像脉搏） |
/// | `_pulseActiveFraction → 1.0` | opacity 0（完全不可见），只剩中心点 |
///
/// 颜色跟随中心点（灰/绿），只用描边不填充。
///
/// **刻意不用 `Transform.scale`**：那会把 `Border.all` 的 1.2px 描边一起
/// 放大（3 倍时变 3.6px），扩散到最大反而成了「粗重的甜甜圈」；真实心跳
/// 光环是**越往外越细、越淡**。所以这里每帧算一次真实直径，边框宽度恒定，
/// 淡出全部交给 `Opacity`。28px 级别的容器每帧重排的开销可以忽略。
class _PulseRing extends StatelessWidget {
  const _PulseRing({required this.controller, required this.color});

  /// 单向推进的驱动源（调用方用 `repeat()`，**不是** `repeat(reverse: true)`）。
  final AnimationController controller;

  /// 与中心点同色。
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final double t = controller.value;
        final bool pulsing = t < _pulseActiveFraction;
        // 静默段把进度钉在终点（opacity 0 / 直径最大），一次性算完，
        // 避免在 45%~100% 之间反复插值。
        final double progress = pulsing
            ? Curves.easeOutCubic.transform(t / _pulseActiveFraction)
            : 1;
        final double opacity = pulsing
            ? _ringMaxOpacity * (1 - progress)
            : 0;
        // 用**真实直径**扩散，不用 Transform.scale：后者会把 Border 的
        // 1.2px 一起放大（3 倍时变 3.6px），扩散到最大时成了一个粗重的
        // 甜甜圈，而不是越往外越淡的光弧。
        final double diameter = _dotSize * (1 + (_ringMaxScale - 1) * progress);
        return Opacity(
          opacity: opacity,
          child: SizedBox.square(
            dimension: diameter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: _ringBorderWidth),
              ),
            ),
          ),
        );
      },
    );
  }
}
