import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/api_client.dart';

/// 统一封面组件：getCoverArt URL 或在线直链，占位为音符图标。
class Cover extends StatelessWidget {
  const Cover({super.key, required this.url, this.size = 48, this.radius = 8});

  final String url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.music_note, size: size * 0.5, color: cs.outline),
    );
    if (url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: (size * 2).round(),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      ),
    );
  }
}

/// 便捷构造：由 ApiClient + coverArtId。
Cover coverOf(ApiClient api, String? coverArtId, {double size = 48, double radius = 8}) =>
    Cover(url: api.coverUrl(coverArtId, size: (size * 2).round()), size: size, radius: radius);
