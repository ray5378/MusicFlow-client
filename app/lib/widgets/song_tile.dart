import 'package:flutter/material.dart';

import '../core/format.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import 'cover.dart';

/// 首页「随机歌曲」行 / 通用歌曲条目：
/// 封面 + 标题 + 歌手 + 音质行 + 红心（对齐箭头音乐）。
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.api,
    required this.song,
    required this.onPlay,
    this.onToggleStar,
    this.trailing,
    this.subtitleOverride,
  });

  final ApiClient api;
  final Song song;
  final VoidCallback onPlay;
  final VoidCallback? onToggleStar;
  final Widget? trailing;
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final quality = Fmt.qualityLine(
      suffix: song.suffix,
      bitRateKbps: song.bitRateKbps,
      size: song.sizeBytes,
      durationSeconds: song.durationSeconds,
    );
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            coverOf(api, song.coverArt, size: 52, radius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(song.title, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    subtitleOverride ??
                        <String>[
                      if (song.artist != null && song.artist!.isNotEmpty)
                        song.artist!,
                      if (quality.isNotEmpty) quality,
                    ].join('\n'),
                    style: tt.labelSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (onToggleStar != null)
              IconButton(
                icon: Icon(
                  song.starred ? Icons.favorite : Icons.favorite_border,
                  color: song.starred ? cs.primary : cs.outline,
                  size: 20,
                ),
                onPressed: onToggleStar,
              )
            else ...<Widget>[
              ?trailing,
            ],
          ],
        ),
      ),
    );
  }
}
