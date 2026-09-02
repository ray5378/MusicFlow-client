import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/song.dart';
import '../../../providers/app_visibility_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/full_player_active_provider.dart';
import '../../../widgets/cover_art_image.dart';

/// 黑胶唱片封面组件 - 参考箭头音乐风格
class VinylRecordCover extends ConsumerStatefulWidget {
  final Song song;
  final double size;
  final bool showVinylEffect;

  const VinylRecordCover({
    super.key,
    required this.song,
    required this.size,
    this.showVinylEffect = true,
  });

  @override
  ConsumerState<VinylRecordCover> createState() => _VinylRecordCoverState();
}

class _VinylRecordCoverState extends ConsumerState<VinylRecordCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  late final Animation<double> _rotationAnimation;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    _rotationAnimation = Tween<double>(begin: 0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _rotationController, curve: Curves.linear),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 三层门控（智能按需渲染）：
    //   1. 播放中（有效播放状态：投屏时设备在播同样旋转，对齐主项目行为）；
    //   2. 仅大屏播放页前台（非大屏模式不渲染旋转——用户确认需求①）；
    //   3. 窗口可见（失焦/最小化/切走时由全局 TickerMode 静音，这里再显式
    //      兜一层，保证组件自洽可测）。
    final isPlaying = ref.watch(effectiveIsPlayingProvider);
    final fullPlayerActive = ref.watch(fullPlayerActiveProvider);
    final appVisible = ref.watch(appVisibilityProvider);
    _syncRotation(
      isPlaying: isPlaying,
      fullPlayerActive: fullPlayerActive,
      appVisible: appVisible,
    );
  }

  /// 是否应旋转：播放中 且 未开启系统减少动效 且 大屏前台 且 窗口可见。
  bool _shouldSpin({
    required bool isPlaying,
    required bool fullPlayerActive,
    required bool appVisible,
  }) {
    return isPlaying &&
        !MediaQuery.disableAnimationsOf(context) &&
        fullPlayerActive &&
        appVisible;
  }

  void _syncRotation({
    required bool isPlaying,
    required bool fullPlayerActive,
    required bool appVisible,
  }) {
    final shouldSpin = _shouldSpin(
      isPlaying: isPlaying,
      fullPlayerActive: fullPlayerActive,
      appVisible: appVisible,
    );
    if (shouldSpin) {
      if (!_rotationController.isAnimating) _rotationController.repeat();
    } else if (_rotationController.isAnimating) {
      _rotationController.stop();
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverRadius = widget.size * 0.35;
    final centerHoleRadius = widget.size * 0.04;
    // Windows 走 Skia,大 blur 阴影每帧重绘成本高:降级为细描边 + 小模糊(SEC §8.1)。
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

    return AnimatedBuilder(
      animation: _rotationAnimation,
      builder: (context, child) {
        return RepaintBoundary(
          child: Transform.rotate(
            angle: _rotationAnimation.value,
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
      },
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
