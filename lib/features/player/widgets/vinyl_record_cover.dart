import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/song.dart';
import '../../../providers/effective_playback_provider.dart';
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
    _rotationAnimation = Tween<double>(
      begin: 0,
      end: 2 * math.pi,
    ).animate(CurvedAnimation(
      parent: _rotationController,
      curve: Curves.linear,
    ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 使用「有效播放状态」:投屏时设备在播,黑胶同样旋转(对齐主项目行为)。
    final isPlaying = ref.watch(effectiveIsPlayingProvider);
    // 尊重系统「减少动态效果」/测试禁用动画,避免无限动画阻塞 pumpAndSettle。
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (isPlaying && !reduceMotion) {
      _rotationController.repeat();
    } else {
      _rotationController.stop(canceled: true);
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

    return AnimatedBuilder(
      animation: _rotationAnimation,
      builder: (context, child) {
        return Transform.rotate(
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
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
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
                      border: Border.all(
                        color: Colors.grey[600]!,
                        width: 2,
                      ),
                    ),
                  ),
              ],
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
      color: context.echoColors.raised,
      child: Center(
        child: Icon(
          AppIcons.music,
          size: widget.size * 0.2,
          color: context.echoColors.muted,
        ),
      ),
    );
  }
}
