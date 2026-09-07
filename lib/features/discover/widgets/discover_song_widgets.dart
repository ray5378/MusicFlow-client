import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

class DiscoverSongTile extends StatelessWidget {
  const DiscoverSongTile({
    super.key,
    required this.song,
    required this.onPressed,
    required this.onOpenActions,
    this.onLongPress,
    this.isCurrent = false,
  });

  final Song song;
  final VoidCallback onPressed;
  final VoidCallback onOpenActions;
  final VoidCallback? onLongPress;

  /// 该歌曲是否正在播放：封面中央叠加半透明遮罩 + 白色跳动竖条。
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // 行高与封面等高(56)：信息区 3 行（歌名/歌手/刮削标签）正好填满。
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: MusicFlowSongRow(
        song: song,
        coverSize: 56,
        contentPadding: EdgeInsets.zero,
        onPressed: onPressed,
        onLongPress: onLongPress ?? onOpenActions,
        onMorePressed: onOpenActions,
        moreSemanticLabel: loc.discover_song_actions_semantics(song.title),
        // 歌名只占一行,过长截断,保证随机歌曲行高与参考稿一致。
        titleMaxLines: 1,
        // 信息区 3 行：歌名 / 歌手 / 刮削标签（音质·码率·格式·大小·时长）。
        richMetadata: true,
        isCurrent: isCurrent,
      ),
    );
  }
}

class DiscoverSongLoading extends StatelessWidget {
  const DiscoverSongLoading({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final columns = textScale > 1.3 || constraints.maxWidth < 720 ? 1 : 2;
        final gap = context.musicFlowSpacing.md;
        final itemWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: context.musicFlowSpacing.xxs,
          children: <Widget>[
            for (var index = 0; index < count; index++)
              SizedBox(
                width: itemWidth,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 72),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: context.musicFlowSpacing.xxs,
                    ),
                    child: Row(
                      children: <Widget>[
                        const MusicFlowSkeleton(width: 48, height: 48),
                        SizedBox(width: context.musicFlowSpacing.sm),
                        const Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              MusicFlowSkeleton.line(height: 16),
                              SizedBox(height: 8),
                              MusicFlowSkeleton.line(width: 112, height: 12),
                            ],
                          ),
                        ),
                        SizedBox(width: context.musicFlowSpacing.sm),
                        const MusicFlowSkeleton(width: 48, height: 48),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

