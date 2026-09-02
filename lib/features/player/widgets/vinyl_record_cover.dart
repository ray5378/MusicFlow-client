import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/song.dart';
import '../../../providers/app_visibility_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../widgets/cover_art_image.dart';

/// 黑胶唱片封面组件 - 参考箭头音乐风格
class VinylRecordCover extends ConsumerStatefulWidget {
  final Song song;
  final double size;
  final bool showVinylEffect;

  /// 是否处于「大屏播放页前台」：旋转的第四层门控（见 [_VinylRecordCoverState]）。
  ///
  /// 参数化而非全局 provider：本组件仅被 FullPlayerPage 使用一次，由页面显式
  /// 传入 true；默认 false 保证任何未来复用点（如迷你条）不显式开启就不会转。
  final bool fullPlayerActive;

  const VinylRecordCover({
    super.key,
    required this.song,
    required this.size,
    this.showVinylEffect = true,
    this.fullPlayerActive = false,
  });

  @override
  ConsumerState<VinylRecordCover> createState() => _VinylRecordCoverState();
}

class _VinylRecordCoverState extends ConsumerState<VinylRecordCover> {
  // 关键帧旋转：用 Timer.periodic 低频驱动,而非 Ticker/AnimationController.
  // 为什么要摆脱 Ticker：Ticker active 会持续驱动 SchedulerBinding 的帧调度,
  // 即使 setState 被限流到低帧率,引擎仍每 vsync 跑一帧并 present → DWM/System
  // 每帧被拉去合成这个大黑胶区域,这是「限速 60fps 后 System GPU 依旧 40-70%」的
  // 真正机理。改用 Timer.periodic 后,只有每个触发点才 setState 排一帧,非触发
  // 的毫秒窗口引擎完全 idle、不再向 DWM 提交新帧——和网易云「转但 System 低」
  // 一致:人眼对匀速慢转(20s/圈)的 ~30fps 关键帧几乎无感知,却砍掉持续合成。
  static const Duration _frameInterval = Duration(
    milliseconds: 33,
  ); // ~30fps 关键帧
  // 每个触发点的角步进 = 2π × (33ms / 20s)。匀速累积,视觉连续、测试可预测。
  static const double _angleStep = 2 * math.pi * 33 / 20000;

  Timer? _rotationTimer;
  double _angle = 0;

  @override
  void dispose() {
    _rotationTimer?.cancel();
    super.dispose();
  }

  /// 是否应旋转：播放中 且 未开启系统减少动效 且 大屏前台 且 窗口可见。
  bool _shouldSpin({required bool isPlaying, required bool appVisible}) {
    return isPlaying &&
        !MediaQuery.disableAnimationsOf(context) &&
        widget.fullPlayerActive &&
        appVisible;
  }

  void _syncRotation({required bool isPlaying, required bool appVisible}) {
    final shouldSpin = _shouldSpin(
      isPlaying: isPlaying,
      appVisible: appVisible,
    );
    if (shouldSpin) {
      if (_rotationTimer == null) {
        // 从当前角位续转,暂停/停转间不跳变。
        _rotationTimer = Timer.periodic(
          _frameInterval,
          (_) => setState(() {
            _angle = (_angle + _angleStep) % (2 * math.pi);
          }),
        );
      }
    } else if (_rotationTimer != null) {
      _rotationTimer!.cancel();
      _rotationTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 三层门控（智能按需渲染）：
    //   1. 播放中（有效播放状态：投屏时设备在播同样旋转，对齐主项目行为）；
    //   2. 仅大屏播放页前台（非大屏模式不渲染旋转——用户确认需求①）；
    //   3. 窗口可见（失焦/最小化/切走时由全局 TickerMode 静音，这里再显式
    //      兜一层，保证组件自洽可测）。
    // 放在 build 而非 didChangeDependencies：Riverpod 的 ref.watch 变化只
    // 触发 rebuild（ConsumerStatefulElement.watch → markNeedsBuild），
    // 不会触发 didChangeDependencies——暂停/失焦/退出大屏必须能即时停转。
    final isPlaying = ref.watch(effectiveIsPlayingProvider);
    final appVisible = ref.watch(isRenderingActiveProvider);
    _syncRotation(isPlaying: isPlaying, appVisible: appVisible);

    final coverRadius = widget.size * 0.35;
    final centerHoleRadius = widget.size * 0.04;
    // Windows 走 Skia,大 blur 阴影每帧重绘成本高:降级为细描边 + 小模糊(SEC §8.1)。
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

    return Transform.rotate(
      angle: _angle,
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 黑胶唱片背景
              if (widget.showVinylEffect)
                Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.black87,
                        Colors.black,
                        Colors.black87,
                        Colors.black,
                        Colors.black87,
                      ],
                      stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
                    ),
                    boxShadow: isWindows
                        ? const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x40000000),
                              blurRadius: 6,
                              spreadRadius: 0,
                            ),
                          ]
                        : const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x80000000),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                  ),
                ),
              // 专辑封面 (圆形裁剪)
              ClipOval(
                child: SizedBox(
                  width: coverRadius * 2,
                  height: coverRadius * 2,
                  child: _buildCoverImage(),
                ),
              ),
              // 中心小孔
              if (widget.showVinylEffect)
                Container(
                  width: centerHoleRadius * 2,
                  height: centerHoleRadius * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.grey[800],
                    border: Border.all(color: Colors.grey[600]!, width: 2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage() {
    final previewCover = widget.song.previewCoverUrl?.trim();
    if (widget.song.isPreview && previewCover?.isNotEmpty == true) {
      return Image.network(
        previewCover!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    return CoverArtImage(
      coverArtId: widget.song.coverArt,
      size: widget.size * 0.7,
      requestSize: 720,
      fit: BoxFit.cover,
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: context.musicFlowColors.raised,
      child: Center(
        child: Icon(
          AppIcons.music,
          size: widget.size * 0.2,
          color: context.musicFlowColors.muted,
        ),
      ),
    );
  }
}
