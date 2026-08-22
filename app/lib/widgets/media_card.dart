import 'package:flutter/material.dart';

import 'cover.dart';

/// 歌单卡片（最近更新的歌单 / 专辑复用）：封面 + 名称 + `歌曲数: N`。
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.coverUrl,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.width = 132,
  });

  final String coverUrl;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Cover(url: coverUrl, size: width - 12, radius: 12),
              const SizedBox(height: 8),
              Text(title, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: tt.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
