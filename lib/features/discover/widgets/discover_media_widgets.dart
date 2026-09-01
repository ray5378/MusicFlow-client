import 'package:flutter/material.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/cover_ref_security.dart';
import '../../../data/models/album.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/song.dart';
import '../../../widgets/cover_art_image.dart';
import '../../../widgets/now_playing_bars.dart';
import '../../../widgets/song_list_item.dart';
import '../../library/widgets/library_collection_components.dart';

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
        moreSemanticLabel: '${song.title} 操作',
        // 歌名只占一行,过长截断,保证随机歌曲行高与参考稿一致。
        titleMaxLines: 1,
        // 信息区 3 行：歌名 / 歌手 / 刮削标签（音质·码率·格式·大小·时长）。
        richMetadata: true,
        isCurrent: isCurrent,
      ),
    );
  }
}

class DiscoverAlbumTile extends StatelessWidget {
  const DiscoverAlbumTile({
    super.key,
    required this.album,
    required this.onPressed,
    required this.width,
    this.onLongPress,
    this.isNowPlaying = false,
  });

  final Album album;
  final VoidCallback onPressed;
  final double width;
  final VoidCallback? onLongPress;

  /// 该专辑是否正在播放：封面右下角叠加半透明遮罩 + 白色跳动竖条。
  final bool isNowPlaying;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: MusicFlowAlbumTile(
        album: album,
        onPressed: onPressed,
        onLongPress: onLongPress,
        isNowPlaying: isNowPlaying,
      ),
    );
  }
}

class DiscoverRecentAlbumRail extends StatelessWidget {
  const DiscoverRecentAlbumRail({
    super.key,
    required this.albums,
    required this.onAlbumPressed,
    this.onAlbumLongPress,
  });

  final List<Album> albums;
  final ValueChanged<Album> onAlbumPressed;
  final ValueChanged<Album>? onAlbumLongPress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(
          context,
        ).scale(1).clamp(1.0, 2.0).toDouble();
        if (scale > 1.3) {
          return Column(
            key: const Key('discover-recent-spotlight'),
            children: <Widget>[
              for (final album in albums)
                MusicFlowAlbumRow(
                  album: album,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: context.musicFlowSpacing.xs,
                  ),
                  onPressed: () => onAlbumPressed(album),
                  onLongPress: onAlbumLongPress == null
                      ? null
                      : () => onAlbumLongPress!(album),
                ),
            ],
          );
        }

        final maximumWidth = constraints.maxWidth < 360
            ? constraints.maxWidth
            : 360.0;
        final minimumWidth = constraints.maxWidth < 260
            ? constraints.maxWidth
            : constraints.maxWidth < 330
            ? 240.0
            : 280.0;
        final targetWidth = constraints.maxWidth * 0.88;
        final cardWidth = targetWidth
            .clamp(minimumWidth, maximumWidth)
            .toDouble();
        final cardHeight = 152 + (scale - 1) * 72;

        return SizedBox(
          key: const Key('discover-recent-spotlight'),
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: albums.length,
            separatorBuilder: (context, index) =>
                SizedBox(width: context.musicFlowSpacing.sm),
            itemBuilder: (context, index) {
              final album = albums[index];
              return DiscoverRecentAlbumCard(
                album: album,
                width: cardWidth,
                height: cardHeight,
                onPressed: () => onAlbumPressed(album),
                onLongPress: onAlbumLongPress == null
                    ? null
                    : () => onAlbumLongPress!(album),
              );
            },
          ),
        );
      },
    );
  }
}

class DiscoverRecentAlbumCard extends StatelessWidget {
  const DiscoverRecentAlbumCard({
    super.key,
    required this.album,
    required this.width,
    required this.height,
    required this.onPressed,
    this.onLongPress,
    this.isNowPlaying = false,
  });

  final Album album;
  final double width;
  final double height;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  /// 该专辑是否正在播放：封面右下角叠加半透明遮罩 + 白色跳动竖条。
  final bool isNowPlaying;

  @override
  Widget build(BuildContext context) {
    final artist = album.artist?.trim();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final artworkSize = scale > 1.3 ? 88.0 : 112.0;
    final semanticLabel = <String>[
      '最近播放专辑 ${album.name}',
      if (artist != null && artist.isNotEmpty) artist,
      '${album.songCount} 首歌曲',
    ].join('，');
    final metadata = <String>[
      if (artist != null && artist.isNotEmpty) artist,
      '${album.songCount} 首歌曲',
    ].join('，');

    return SizedBox(
      width: width,
      height: height,
      child: MusicFlowPressable(
        semanticLabel: semanticLabel,
        onPressed: onPressed,
        onLongPress: onLongPress,
        minimumSize: Size(width, height),
        borderRadius: context.musicFlowRadii.surface,
        child: Ink(
          decoration: BoxDecoration(
            color: context.musicFlowColors.surface,
            borderRadius: context.musicFlowRadii.surface,
            border: Border.all(color: context.musicFlowColors.divider),
          ),
          child: Padding(
            padding: EdgeInsets.all(context.musicFlowSpacing.sm),
              child: Row(
                children: <Widget>[
                  Stack(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: context.musicFlowRadii.surface,
                        child: CoverArtImage(
                          coverArtId: album.coverArt,
                          size: artworkSize,
                          requestSize: 320,
                          fit: BoxFit.cover,
                          semanticLabel: '${album.name} 封面',
                        ),
                      ),
                      // 正在播放：封面右下角半透明遮罩 + 白色跳动竖条。
                      if (isNowPlaying)
                        SizedBox.square(
                          dimension: artworkSize,
                          child: NowPlayingCoverOverlay(size: artworkSize),
                        ),
                    ],
                  ),
                SizedBox(width: context.musicFlowSpacing.sm),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            AppIcons.history,
                            size: 16,
                            color: context.musicFlowColors.accent,
                          ),
                          SizedBox(width: context.musicFlowSpacing.xxs),
                          Expanded(
                            child: Text(
                              '最近听过',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.musicFlowTypography.label.copyWith(
                                color: context.musicFlowColors.accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: context.musicFlowSpacing.xs),
                      Text(
                        album.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.title,
                      ),
                      SizedBox(height: context.musicFlowSpacing.xxs),
                      Text(
                        metadata,
                        maxLines: scale > 1.3 ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.metadata.copyWith(
                          color: context.musicFlowColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DiscoverAlbumRail extends StatelessWidget {
  const DiscoverAlbumRail({
    super.key,
    required this.albums,
    required this.onAlbumPressed,
    this.onAlbumLongPress,
  });

  final List<Album> albums;
  final ValueChanged<Album> onAlbumPressed;
  final ValueChanged<Album>? onAlbumLongPress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(
          context,
        ).scale(1).clamp(1.0, 2.0).toDouble();
        if (scale > 1.3) {
          return Column(
            key: const Key('discover-newest-rail'),
            children: <Widget>[
              for (final album in albums)
                MusicFlowAlbumRow(
                  album: album,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: context.musicFlowSpacing.xs,
                  ),
                  onPressed: () => onAlbumPressed(album),
                  onLongPress: onAlbumLongPress == null
                      ? null
                      : () => onAlbumLongPress!(album),
                ),
            ],
          );
        }

        final tileWidth = constraints.maxWidth < 400 ? 132.0 : 148.0;
        final tileHeight = tileWidth + 104 + (scale - 1) * 112;

        return SizedBox(
          key: const Key('discover-newest-rail'),
          height: tileHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: albums.length,
            separatorBuilder: (context, index) =>
                SizedBox(width: context.musicFlowSpacing.sm),
            itemBuilder: (context, index) {
              final album = albums[index];
              return DiscoverAlbumTile(
                album: album,
                width: tileWidth,
                onPressed: () => onAlbumPressed(album),
                onLongPress: onAlbumLongPress == null
                    ? null
                    : () => onAlbumLongPress!(album),
              );
            },
          ),
        );
      },
    );
  }
}

class DiscoverFrequentAlbumShelf extends StatelessWidget {
  const DiscoverFrequentAlbumShelf({
    super.key,
    required this.albums,
    required this.onAlbumPressed,
    this.onAlbumLongPress,
  });

  final List<Album> albums;
  final ValueChanged<Album> onAlbumPressed;
  final ValueChanged<Album>? onAlbumLongPress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(
          context,
        ).scale(1).clamp(1.0, 2.0).toDouble();
        final useAccessibleList = scale >= 1.3 || constraints.maxWidth < 280;

        if (useAccessibleList) {
          return Column(
            key: const Key('discover-frequent-shelf'),
            children: <Widget>[
              for (final album in albums)
                MusicFlowAlbumRow(
                  album: album,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: context.musicFlowSpacing.xs,
                  ),
                  onPressed: () => onAlbumPressed(album),
                  onLongPress: onAlbumLongPress == null
                      ? null
                      : () => onAlbumLongPress!(album),
                ),
            ],
          );
        }

        final maximumWidth = constraints.maxWidth < 340
            ? constraints.maxWidth
            : 340.0;
        final minimumWidth = constraints.maxWidth < 280
            ? constraints.maxWidth
            : 280.0;
        final tileWidth = (constraints.maxWidth * 0.86)
            .clamp(minimumWidth, maximumWidth)
            .toDouble();
        final itemHeight = 104 + (scale - 1) * 80;
        final groupCount = (albums.length + 1) ~/ 2;

        return SizedBox(
          key: const Key('discover-frequent-shelf'),
          height: itemHeight * 2 + context.musicFlowSpacing.sm,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: groupCount,
            separatorBuilder: (context, index) =>
                SizedBox(width: context.musicFlowSpacing.md),
            itemBuilder: (context, groupIndex) {
              final start = groupIndex * 2;
              final end = (start + 2).clamp(0, albums.length);
              return _DiscoverFrequentAlbumGroup(
                key: ValueKey<String>('discover-frequent-group-$groupIndex'),
                albums: albums.sublist(start, end),
                width: tileWidth,
                onAlbumPressed: onAlbumPressed,
                onAlbumLongPress: onAlbumLongPress,
              );
            },
          ),
        );
      },
    );
  }
}

class _DiscoverFrequentAlbumGroup extends StatelessWidget {
  const _DiscoverFrequentAlbumGroup({
    super.key,
    required this.albums,
    required this.width,
    required this.onAlbumPressed,
    this.onAlbumLongPress,
  });

  final List<Album> albums;
  final double width;
  final ValueChanged<Album> onAlbumPressed;
  final ValueChanged<Album>? onAlbumLongPress;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final radius = context.musicFlowRadii.surface;
    return SizedBox(
      width: width,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.musicFlowColors.surface,
              borderRadius: radius,
              border: Border.all(color: context.musicFlowColors.divider),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.sm,
                vertical: spacing.xxs,
              ),
              child: Column(
                children: <Widget>[
                  for (
                    var index = 0;
                    index < albums.length;
                    index++
                  ) ...<Widget>[
                    if (index > 0)
                      MusicFlowDivider(color: context.musicFlowColors.divider),
                    Expanded(
                      child: MusicFlowAlbumRow(
                        album: albums[index],
                        allowFullText: false,
                        contentPadding: EdgeInsets.symmetric(
                          vertical: spacing.xs,
                        ),
                        onPressed: () => onAlbumPressed(albums[index]),
                        onLongPress: onAlbumLongPress == null
                            ? null
                            : () => onAlbumLongPress!(albums[index]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DiscoverSectionMessage extends StatelessWidget {
  const DiscoverSectionMessage({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    this.onRetry,
  });

  final String title;
  final String description;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '$title，$description',
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ExcludeSemantics(
              child: SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: Center(
                  child: Icon(icon, size: 24, color: context.musicFlowColors.muted),
                ),
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(title, style: context.musicFlowTypography.title),
                        SizedBox(height: context.musicFlowSpacing.xxs),
                        Text(
                          description,
                          style: context.musicFlowTypography.body.copyWith(
                            color: context.musicFlowColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onRetry != null) ...<Widget>[
                    SizedBox(height: context.musicFlowSpacing.xs),
                    MusicFlowButton.ghost(
                      label: '重试',
                      leadingIcon: AppIcons.refresh,
                      onPressed: onRetry,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
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

class DiscoverRecentAlbumLoading extends StatelessWidget {
  const DiscoverRecentAlbumLoading({super.key, this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(
          context,
        ).scale(1).clamp(1.0, 2.0).toDouble();
        if (scale > 1.3) {
          return Column(
            children: <Widget>[
              for (var index = 0; index < count; index++)
                const _DiscoverAlbumRowSkeleton(),
            ],
          );
        }

        final maximumWidth = constraints.maxWidth < 360
            ? constraints.maxWidth
            : 360.0;
        final minimumWidth = constraints.maxWidth < 260
            ? constraints.maxWidth
            : constraints.maxWidth < 330
            ? 240.0
            : 280.0;
        final targetWidth = constraints.maxWidth * 0.88;
        final cardWidth = targetWidth
            .clamp(minimumWidth, maximumWidth)
            .toDouble();
        final cardHeight = 152 + (scale - 1) * 72;
        final artworkSize = scale > 1.3 ? 88.0 : 112.0;

        return SizedBox(
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: count,
            separatorBuilder: (context, index) =>
                SizedBox(width: context.musicFlowSpacing.sm),
            itemBuilder: (context, index) => SizedBox(
              width: cardWidth,
              height: cardHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.musicFlowColors.surface,
                  borderRadius: context.musicFlowRadii.surface,
                  border: Border.all(color: context.musicFlowColors.divider),
                ),
                child: Padding(
                  padding: EdgeInsets.all(context.musicFlowSpacing.sm),
                  child: Row(
                    children: <Widget>[
                      MusicFlowSkeleton(
                        width: artworkSize,
                        height: artworkSize,
                        borderRadius: context.musicFlowRadii.surface,
                      ),
                      SizedBox(width: context.musicFlowSpacing.sm),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            MusicFlowSkeleton.line(width: 92, height: 12 * scale),
                            SizedBox(height: context.musicFlowSpacing.sm),
                            MusicFlowSkeleton.line(height: 16 * scale),
                            SizedBox(height: context.musicFlowSpacing.xs),
                            MusicFlowSkeleton.line(width: 112, height: 12 * scale),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class DiscoverAlbumLoading extends StatelessWidget {
  const DiscoverAlbumLoading({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(
          context,
        ).scale(1).clamp(1.0, 2.0).toDouble();
        if (scale > 1.3) {
          return Column(
            children: <Widget>[
              for (var index = 0; index < count; index++)
                const _DiscoverAlbumRowSkeleton(),
            ],
          );
        }

        final width = constraints.maxWidth < 400 ? 132.0 : 148.0;
        final height = width + 104 + (scale - 1) * 112;

        return SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: count,
            separatorBuilder: (context, index) =>
                SizedBox(width: context.musicFlowSpacing.sm),
            itemBuilder: (context, index) => SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  MusicFlowSkeleton(
                    width: width,
                    height: width,
                    borderRadius: context.musicFlowRadii.control,
                  ),
                  SizedBox(height: context.musicFlowSpacing.xs),
                  MusicFlowSkeleton.line(height: 16 * scale),
                  SizedBox(height: context.musicFlowSpacing.xs),
                  MusicFlowSkeleton.line(width: 88, height: 12 * scale),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class DiscoverFrequentAlbumLoading extends StatelessWidget {
  const DiscoverFrequentAlbumLoading({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(
          context,
        ).scale(1).clamp(1.0, 2.0).toDouble();
        final useAccessibleList = scale >= 1.3 || constraints.maxWidth < 280;

        if (useAccessibleList) {
          return Column(
            children: <Widget>[
              for (var index = 0; index < count; index++)
                const _DiscoverAlbumRowSkeleton(),
            ],
          );
        }

        final itemHeight = 104 + (scale - 1) * 80;

        final maximumWidth = constraints.maxWidth < 340
            ? constraints.maxWidth
            : 340.0;
        final minimumWidth = constraints.maxWidth < 280
            ? constraints.maxWidth
            : 280.0;
        final tileWidth = (constraints.maxWidth * 0.86)
            .clamp(minimumWidth, maximumWidth)
            .toDouble();
        final groupCount = (count + 1) ~/ 2;

        return SizedBox(
          height: itemHeight * 2 + context.musicFlowSpacing.sm,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: groupCount,
            separatorBuilder: (context, index) =>
                SizedBox(width: context.musicFlowSpacing.md),
            itemBuilder: (context, groupIndex) {
              final start = groupIndex * 2;
              final groupItemCount = (count - start).clamp(0, 2);
              return SizedBox(
                width: tileWidth,
                child: ClipRRect(
                  borderRadius: context.musicFlowRadii.surface,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.musicFlowColors.surface,
                      borderRadius: context.musicFlowRadii.surface,
                      border: Border.all(color: context.musicFlowColors.divider),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.musicFlowSpacing.sm,
                        vertical: context.musicFlowSpacing.xxs,
                      ),
                      child: Column(
                        children: <Widget>[
                          for (
                            var itemIndex = 0;
                            itemIndex < groupItemCount;
                            itemIndex++
                          ) ...<Widget>[
                            if (itemIndex > 0)
                              MusicFlowDivider(color: context.musicFlowColors.divider),
                            const Expanded(child: _DiscoverAlbumRowSkeleton()),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _DiscoverAlbumRowSkeleton extends StatelessWidget {
  const _DiscoverAlbumRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
      child: Row(
        children: <Widget>[
          MusicFlowSkeleton(
            width: 72,
            height: 72,
            borderRadius: context.musicFlowRadii.detail,
          ),
          SizedBox(width: context.musicFlowSpacing.sm),
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                MusicFlowSkeleton.line(height: 16),
                SizedBox(height: 8),
                MusicFlowSkeleton.line(width: 104, height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DiscoverPlaylistTile extends StatelessWidget {
  const DiscoverPlaylistTile({
    super.key,
    required this.playlist,
    required this.onPressed,
    this.onLongPress,
  });

  final Playlist playlist;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: MusicFlowPressable(
        semanticLabel: '${playlist.name}，${playlist.songCount} 首',
        onPressed: onPressed,
        onLongPress: onLongPress,
        minimumSize: const Size(double.infinity, 72),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowSpacing.xs,
            vertical: context.musicFlowSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: ClipRRect(
                  borderRadius: context.musicFlowRadii.control,
                  // 与其它库一致使用 CoverArtImage 封面加载规范：
                  // coverArt 非空(如 pl-<id>)显示封面，否则回退歌单图标。
                  child: playlist.coverArt != null &&
                          playlist.coverArt!.isNotEmpty
                      ? CoverArtImage(
                          coverArtId: playlist.coverArt,
                          size: context.musicFlowInteraction.minimumTouchTarget,
                          requestSize: 160,
                          fit: BoxFit.cover,
                          semanticLabel: '${playlist.name} 封面',
                        )
                      : Center(
                          child: Icon(
                            AppIcons.playlist,
                            size: 24,
                            color: context.musicFlowColors.accent,
                          ),
                        ),
                ),
              ),
              SizedBox(width: context.musicFlowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      style: context.musicFlowTypography.title,
                    ),
                    SizedBox(height: context.musicFlowSpacing.xxs),
                    Text(
                      '${playlist.songCount} 首 · ${playlist.durationString}',
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DiscoverPlaylistLoading extends StatelessWidget {
  const DiscoverPlaylistLoading({super.key, this.count = 3});

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

/// 带封面的推荐歌单条目(固定推荐卡与平台推荐歌单共用)。
/// 封面优先用 [coverArtId](pl- 前缀 id 走 getCoverArt),否则用 [coverUrl](远程地址,
/// 经 trusted-url 前缀放行)。
class DiscoverRecommendTile extends StatelessWidget {
  const DiscoverRecommendTile({
    super.key,
    required this.title,
    this.subtitle,
    this.coverArtId,
    this.coverUrl,
    required this.onPressed,
    this.onLongPress,
  });

  final String title;
  final String? subtitle;
  final String? coverArtId;
  final String? coverUrl;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  String? get _effectiveCoverRef {
    if (coverArtId != null && coverArtId!.isNotEmpty) return coverArtId;
    if (coverUrl != null && coverUrl!.isNotEmpty) {
      return tryToTrustedCoverUrlRef(coverUrl);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final coverRef = _effectiveCoverRef;
    final artworkSize = MediaQuery.textScalerOf(context).scale(1) > 1.3
        ? 80.0
        : 56.0;
    final semanticLabel = <String>[
      title,
      if (subtitle != null && subtitle!.isNotEmpty) subtitle!,
    ].join('，');

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: MusicFlowPressable(
        semanticLabel: semanticLabel,
        onPressed: onPressed,
        onLongPress: onLongPress,
        minimumSize: const Size(double.infinity, 72),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowSpacing.xs,
            vertical: context.musicFlowSpacing.xxs,
          ),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: artworkSize,
                child: ClipRRect(
                  borderRadius: context.musicFlowRadii.surface,
                  child: coverRef != null
                      ? CoverArtImage(
                          coverArtId: coverRef,
                          size: artworkSize,
                          requestSize: 160,
                          fit: BoxFit.cover,
                          semanticLabel: '$title 封面',
                        )
                      : Container(
                          color: context.musicFlowColors.surface,
                          child: Center(
                            child: Icon(
                              AppIcons.playlist,
                              size: 24,
                              color: context.musicFlowColors.accent,
                            ),
                          ),
                        ),
                ),
              ),
              SizedBox(width: context.musicFlowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: context.musicFlowTypography.title,
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                      SizedBox(height: context.musicFlowSpacing.xxs),
                      Text(
                        subtitle!,
                        style: context.musicFlowTypography.metadata.copyWith(
                          color: context.musicFlowColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DiscoverRecommendLoading extends StatelessWidget {
  const DiscoverRecommendLoading({super.key, this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) {
    final artworkSize = MediaQuery.textScalerOf(context).scale(1) > 1.3
        ? 80.0
        : 56.0;
    return Wrap(
      spacing: context.musicFlowSpacing.md,
      runSpacing: context.musicFlowSpacing.xxs,
      children: <Widget>[
        for (var index = 0; index < count; index++)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xxs),
              child: Row(
                children: <Widget>[
                  MusicFlowSkeleton(
                    width: artworkSize,
                    height: artworkSize,
                    borderRadius: context.musicFlowRadii.surface,
                  ),
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
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 封面在上的歌单卡片(标题在下、歌曲数在底),与相册卡片同款样式。
/// [coverArtId] 走 getCoverArt(pl- 前缀的 id),[coverUrl] 为远程封面(经 trusted-url 放行)。
class DiscoverPlaylistCard extends StatelessWidget {
  const DiscoverPlaylistCard({
    super.key,
    required this.title,
    this.subtitle,
    this.coverArtId,
    this.coverUrl,
    required this.onPressed,
    this.onLongPress,
    this.onPlay,
    this.loading = false,
    this.width = 160,
    this.isNowPlaying = false,
  });

  final String title;
  final String? subtitle;
  final String? coverArtId;
  final String? coverUrl;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  /// 封面右下角半透明播放按钮：点击直接播放该歌单。
  /// 移动端（compact）常驻显示，桌面端鼠标悬停封面时才显示。
  final VoidCallback? onPlay;

  final bool loading;
  final double width;

  /// 该歌单是否正在播放：封面右下角叠加半透明遮罩 + 白色跳动竖条。
  final bool isNowPlaying;

  String? get _effectiveCoverRef {
    if (coverArtId != null && coverArtId!.isNotEmpty) return coverArtId;
    if (coverUrl != null && coverUrl!.isNotEmpty) {
      return tryToTrustedCoverUrlRef(coverUrl);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final coverRef = _effectiveCoverRef;
    final semanticLabel = <String>[
      title,
      if (subtitle != null && subtitle!.isNotEmpty) subtitle!,
    ].join('，');

    return SizedBox(
      width: width,
      child: Semantics(
        label: semanticLabel,
        child: MusicFlowPressable(
          onPressed: onPressed,
          onLongPress: onLongPress,
          minimumSize: Size(width, width),
          borderRadius: context.musicFlowRadii.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: context.musicFlowRadii.surface,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      coverRef != null
                          ? CoverArtImage(
                              coverArtId: coverRef,
                              size: width,
                              requestSize: 320,
                              fit: BoxFit.cover,
                              semanticLabel: '$title 封面',
                            )
                          : Container(
                              color: context.musicFlowColors.surface,
                              child: Center(
                                child: Icon(
                                  AppIcons.playlist,
                                  size: width * 0.3,
                                  color: context.musicFlowColors.accent,
                                ),
                              ),
                            ),
                      if (loading)
                        Container(
                          color: Colors.black45,
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        ),
                      // 正在播放：封面右下角半透明遮罩 + 白色跳动竖条。
                      if (isNowPlaying)
                        NowPlayingCoverOverlay(size: width),
                      // 封面右下角半透明播放按钮。
                      // 正在播放时自动隐藏,避免与 NowPlayingCoverOverlay 重叠
                      // (两者都锚定在右下角)。播放中已有跳动竖条指示,不需要再
                      // 显示「播放」入口(v3.4.61)。
                      if (onPlay != null && !isNowPlaying)
                        _PlaylistCoverPlayButton(
                          coverSize: width,
                          onPlay: onPlay!,
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.xs),
              Text(
                title,
                // 歌单名只显示一行,过长截断。
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.musicFlowTypography.title,
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                SizedBox(height: context.musicFlowSpacing.xxs),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.musicFlowTypography.metadata.copyWith(
                    color: context.musicFlowColors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DiscoverPlaylistCardLoading extends StatelessWidget {
  const DiscoverPlaylistCardLoading({super.key, this.width = 160});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          MusicFlowSkeleton(
            width: width,
            height: width,
            borderRadius: context.musicFlowRadii.surface,
          ),
          SizedBox(height: context.musicFlowSpacing.xs),
          MusicFlowSkeleton.line(height: 14),
          SizedBox(height: context.musicFlowSpacing.xxs),
          MusicFlowSkeleton.line(width: width * 0.6, height: 12),
        ],
      ),
    );
  }
}

/// 封面右下角半透明播放按钮：
/// - 移动端（compact）常驻显示；
/// - 桌面端平时隐藏，鼠标悬停封面时才显示。
class _PlaylistCoverPlayButton extends StatefulWidget {
  const _PlaylistCoverPlayButton({
    required this.coverSize,
    required this.onPlay,
  });

  final double coverSize;
  final VoidCallback onPlay;

  @override
  State<_PlaylistCoverPlayButton> createState() =>
      _PlaylistCoverPlayButtonState();
}

class _PlaylistCoverPlayButtonState extends State<_PlaylistCoverPlayButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final compact =
        context.musicFlowWindowClass == MusicFlowWindowClass.compact;
    // 移动端常驻；桌面端 hover 才显示。
    final visible = compact || _hovered;

    // 按钮直径随封面等比缩放（160 基准：44）。
    final buttonSize = (widget.coverSize * 0.275).clamp(32.0, 64.0);
    final iconSize = buttonSize * 0.5;

    return Positioned(
      right: widget.coverSize * 0.055,
      bottom: widget.coverSize * 0.055,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: visible ? 1 : 0,
          child: IgnorePointer(
            ignoring: !visible,
            child: MusicFlowIconButton(
              label: '播放歌单',
              onPressed: widget.onPlay,
              icon: AppIcons.play,
              iconSize: iconSize,
              backgroundColor: Colors.black45,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
