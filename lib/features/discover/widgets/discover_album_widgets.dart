import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

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
            // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
            cacheExtent: 0,
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
    final loc = AppLocalizations.of(context);
    final artist = album.artist?.trim();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final artworkSize = scale > 1.3 ? 88.0 : 112.0;
    final songCount = loc.discover_recent_song_count('${album.songCount}');
    final semanticLabel = <String>[
      loc.discover_recent_album_semantics(album.name),
      if (artist != null && artist.isNotEmpty) artist,
      songCount,
    ].join('，');
    final metadata = <String>[
      if (artist != null && artist.isNotEmpty) artist,
      songCount,
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
                          semanticLabel: loc.discover_cover_semantics(album.name),
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
                              loc.discover_recently_played,
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
            // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
            cacheExtent: 0,
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
            // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
            cacheExtent: 0,
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

