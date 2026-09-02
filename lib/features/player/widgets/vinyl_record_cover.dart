import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/song.dart';
import '../../../widgets/cover_art_image.dart';

/// 黑胶唱片封面组件 - 参考箭头音乐风格。
///
/// v3.4.75：完全静态化。此前为追求「旋转」动效引入了 Ticker/Timer 持续驱动，
/// 即便降帧仍让 DWM/System 每帧对大封面区域做合成(网易云能「转且 System 低」
/// 正是因为它不持续向 DWM 提交新帧)。经用户确认,大屏采用静态封面视效,
/// 彻底移除旋转开销:黑胶以 [RepaintBoundary] 缓存为一张静态纹理,任何时刻都
/// 不产生持续动画,不再需要播放状态/窗口可见性/大屏前台等门控。
class VinylRecordCover extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final coverRadius = size * 0.35;
    final centerHoleRadius = size * 0.04;
    // Windows 走 Skia,大 blur 阴影成本高:降级为细描边 + 小模糊。
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

    // RepaintBoundary:黑胶(含阴影)是静态纹理,一次光栅化后作为独立 layer
    // 缓存,绝不参与任何每帧重绘——静态封面,零合成开销。
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 黑胶唱片背景
            if (showVinylEffect)
              Container(
                width: size,
                height: size,
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
                child: _buildCoverImage(context),
              ),
            ),
            // 中心小孔
            if (showVinylEffect)
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
    );
  }

  Widget _buildCoverImage(BuildContext context) {
    final previewCover = song.previewCoverUrl?.trim();
    if (song.isPreview && previewCover?.isNotEmpty == true) {
      return Image.network(
        previewCover!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _buildPlaceholder(context),
      );
    }

    return CoverArtImage(
      coverArtId: song.coverArt,
      size: size * 0.7,
      requestSize: 720,
      fit: BoxFit.cover,
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      color: context.musicFlowColors.raised,
      child: Center(
        child: Icon(
          AppIcons.music,
          size: size * 0.2,
          color: context.musicFlowColors.muted,
        ),
      ),
    );
  }
}
