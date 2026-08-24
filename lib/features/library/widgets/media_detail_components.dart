import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/album.dart';
import '../../../providers/palette_provider.dart';
import '../../../widgets/cover_art_image.dart';
import '../utils/library_sorting.dart';

Future<SongSortOption?> showMediaSongSortSheet({
  required BuildContext context,
  required SongSortOption current,
}) {
  return showEchoBottomSheet<SongSortOption>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => MusicFlowBottomSheet(
      title: '歌曲排序',
      subtitle: '当前：${current.label}',
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final option in selectableSongSortOptions)
              MusicFlowActionRow(
                icon: AppIcons.sort,
                title: option.label,
                selected: option == current,
                trailing: option == current
                    ? Icon(
                        AppIcons.check,
                        color: sheetContext.musicFlowColors.accent,
                      )
                    : null,
                onPressed: () => Navigator.of(sheetContext).pop(option),
              ),
          ],
        ),
      ),
    ),
  );
}

class MediaDetailHeaderSurface extends ConsumerWidget {
  const MediaDetailHeaderSurface({
    super.key,
    required this.child,
    this.coverArtId,
    this.useContentTint = true,
  });

  final Widget child;
  final String? coverArtId;
  final bool useContentTint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.musicFlowColors;
    final normalizedCoverArtId = coverArtId?.trim() ?? '';
    final palette = useContentTint && normalizedCoverArtId.isNotEmpty
        ? ref
              .watch(
                mediaPaletteProvider(
                  MediaPaletteRequest.coverReference(normalizedCoverArtId),
                ),
              )
              .valueOrNull
        : null;
    final paletteColor =
        palette?.dominantColor?.color ??
        palette?.vibrantColor?.color ??
        palette?.mutedColor?.color;
    final background = useContentTint
        ? mediaDetailHeaderBackgroundColor(context, paletteColor)
        : colors.canvas;
    final motion = context.musicFlowMotion;

    return AnimatedContainer(
      key: const ValueKey<String>('media-detail-header-surface'),
      duration: motion.resolve(context, motion.state),
      curve: motion.easeOut,
      decoration: BoxDecoration(
        color: background,
        border: Border(bottom: BorderSide(color: colors.divider)),
      ),
      child: child,
    );
  }
}

/// Builds a restrained artwork tint while keeping Echo text readable.
///
/// The fallback seed is [MusicFlowColors.contentTint], so missing artwork and
/// extraction failures retain the same stable visual identity. Tint strength
/// is reduced until both primary and secondary text meet WCAG AA.
Color mediaDetailHeaderBackgroundColor(BuildContext context, Color? seed) {
  final colors = context.musicFlowColors;
  final tint = seed ?? colors.contentTint;
  var strength = Theme.of(context).brightness == Brightness.dark ? 0.24 : 0.16;

  for (var attempt = 0; attempt < 10; attempt += 1) {
    final candidate = Color.alphaBlend(
      tint.withValues(alpha: strength),
      colors.canvas,
    );
    final inkRatio = MusicFlowColors.contrastRatio(colors.ink, candidate);
    final mutedRatio = MusicFlowColors.contrastRatio(colors.muted, candidate);
    if (inkRatio >= 4.5 && mutedRatio >= 4.5) {
      return candidate;
    }
    strength *= 0.65;
  }

  return colors.canvas;
}

class MediaDetailArtwork extends StatelessWidget {
  const MediaDetailArtwork({
    super.key,
    required this.coverArtId,
    required this.semanticLabel,
    this.heroTag,
    this.circular = false,
    this.requestSize = 720,
  });

  final String? coverArtId;
  final String semanticLabel;
  final Object? heroTag;
  final bool circular;
  final int requestSize;

  @override
  Widget build(BuildContext context) {
    Widget artwork = CoverArtImage(
      coverArtId: coverArtId,
      requestSize: requestSize,
      fit: BoxFit.cover,
      semanticLabel: semanticLabel,
    );
    artwork = circular
        ? ClipOval(child: artwork)
        : ClipRRect(borderRadius: context.musicFlowRadii.surface, child: artwork);

    if (heroTag != null) {
      artwork = Hero(tag: heroTag!, child: artwork);
    }
    return artwork;
  }
}

class MediaDetailSectionSwitcher extends StatelessWidget {
  const MediaDetailSectionSwitcher({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.musicFlowColors.canvas,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowSpacing.md,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            for (var index = 0; index < labels.length; index++) ...<Widget>[
              if (index > 0) SizedBox(width: context.musicFlowSpacing.xs),
              Expanded(
                child: MusicFlowPressable(
                  semanticLabel: labels[index],
                  selected: index == selectedIndex,
                  onPressed: () => onSelected(index),
                  minimumSize: const Size(double.infinity, 48),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: index == selectedIndex
                          ? context.musicFlowColors.accent.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: context.musicFlowRadii.control,
                    ),
                    child: Center(
                      child: Text(
                        labels[index],
                        style: context.musicFlowTypography.label.copyWith(
                          color: index == selectedIndex
                              ? context.musicFlowColors.accent
                              : context.musicFlowColors.ink,
                          fontWeight: index == selectedIndex
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MediaDetailAlbumTile extends StatelessWidget {
  const MediaDetailAlbumTile({
    super.key,
    required this.album,
    required this.onPressed,
    required this.onLongPress,
  });

  final Album album;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final metadata = <String>[
      if (album.year != null) '${album.year}',
      '${album.songCount} 首',
    ].join(' · ');

    return MusicFlowPressable(
      semanticLabel: '${album.name}，$metadata',
      onPressed: onPressed,
      onLongPress: onLongPress,
      minimumSize: const Size(double.infinity, 64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 1,
            child: MediaDetailArtwork(
              coverArtId: album.coverArt,
              semanticLabel: '${album.name} 封面',
              heroTag: 'album-cover-${album.id}',
              requestSize: 480,
            ),
          ),
          SizedBox(height: context.musicFlowSpacing.xs),
          Text(album.name, style: context.musicFlowTypography.title, maxLines: 2),
          SizedBox(height: context.musicFlowSpacing.xxs),
          Text(
            metadata,
            style: context.musicFlowTypography.metadata.copyWith(
              color: context.musicFlowColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class MediaDetailLoadingView extends StatelessWidget {
  const MediaDetailLoadingView({super.key, this.circularArtwork = false});

  final bool circularArtwork;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.all(context.musicFlowSpacing.md),
      children: <Widget>[
        Center(
          child: circularArtwork
              ? const MusicFlowSkeleton.circle(size: 160)
              : const SizedBox.square(
                  dimension: 220,
                  child: MusicFlowSkeleton(
                    height: 220,
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
        ),
        SizedBox(height: context.musicFlowSpacing.lg),
        const MusicFlowSkeleton.line(width: 220, height: 28),
        SizedBox(height: context.musicFlowSpacing.sm),
        const MusicFlowSkeleton.line(width: 160),
        SizedBox(height: context.musicFlowSpacing.lg),
        for (var index = 0; index < 6; index++) ...<Widget>[
          Row(
            children: <Widget>[
              const MusicFlowSkeleton.circle(),
              SizedBox(width: context.musicFlowSpacing.sm),
              const Expanded(child: MusicFlowSkeleton.line(height: 18)),
            ],
          ),
          SizedBox(height: context.musicFlowSpacing.md),
        ],
      ],
    );
  }
}

class MediaLoadNotice extends StatelessWidget {
  const MediaLoadNotice({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: message,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.musicFlowColors.raised,
          borderRadius: context.musicFlowRadii.control,
          border: Border.all(color: context.musicFlowColors.controlBoundary),
        ),
        child: Padding(
          padding: EdgeInsets.all(context.musicFlowSpacing.sm),
          child: Row(
            children: <Widget>[
              Icon(
                AppIcons.wifiOff,
                size: 20,
                color: context.musicFlowColors.warning,
              ),
              SizedBox(width: context.musicFlowSpacing.xs),
              Expanded(
                child: Text(message, style: context.musicFlowTypography.body),
              ),
              SizedBox(width: context.musicFlowSpacing.xs),
              MusicFlowButton.ghost(label: '重试', onPressed: onRetry),
            ],
          ),
        ),
      ),
    );
  }
}
