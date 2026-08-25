import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/album.dart';
import '../../../data/models/artist.dart';
import '../../../widgets/cover_art_image.dart';

class MusicFlowAlbumTile extends StatelessWidget {
  const MusicFlowAlbumTile({
    super.key,
    required this.album,
    required this.onPressed,
    this.onLongPress,
    this.allowFullText = false,
  });

  final Album album;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool allowFullText;

  @override
  Widget build(BuildContext context) {
    final artist = album.artist?.trim() ?? '';
    final semanticLabel = <String>[
      '专辑 ${album.name}',
      if (artist.isNotEmpty) artist,
      if (album.starred) '已收藏',
    ].join('，');

    return MusicFlowPressable(
      semanticLabel: semanticLabel,
      onPressed: onPressed,
      onLongPress: onLongPress,
      minimumSize: const Size(96, 96),
      borderRadius: context.musicFlowRadii.control,
      child: Padding(
        padding: EdgeInsets.only(bottom: context.musicFlowSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: context.musicFlowRadii.control,
                    child: CoverArtImage(
                      coverArtId: album.coverArt,
                      requestSize: 420,
                      fit: BoxFit.cover,
                      semanticLabel: '${album.name} 封面',
                    ),
                  ),
                  if (album.starred)
                    PositionedDirectional(
                      start: context.musicFlowSpacing.xs,
                      bottom: context.musicFlowSpacing.xs,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.musicFlowColors.surface,
                          borderRadius: context.musicFlowRadii.pill,
                          border: Border.all(
                            color: context.musicFlowColors.controlBoundary,
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(context.musicFlowSpacing.xxs),
                          child: Icon(
                            AppIcons.heart,
                            size: 16,
                            color: context.musicFlowColors.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: context.musicFlowSpacing.xs),
            Text(
              album.name,
              maxLines: allowFullText ? null : 2,
              overflow: allowFullText ? null : TextOverflow.ellipsis,
              style: context.musicFlowTypography.title,
            ),
            if (artist.isNotEmpty) ...<Widget>[
              SizedBox(height: context.musicFlowSpacing.xxs),
              Text(
                artist,
                maxLines: allowFullText ? null : 2,
                overflow: allowFullText ? null : TextOverflow.ellipsis,
                style: context.musicFlowTypography.metadata.copyWith(
                  color: context.musicFlowColors.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MusicFlowAlbumRow extends StatelessWidget {
  const MusicFlowAlbumRow({
    super.key,
    required this.album,
    required this.onPressed,
    this.onLongPress,
    this.contentPadding,
    this.allowFullText = true,
  });

  final Album album;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry? contentPadding;
  final bool allowFullText;

  @override
  Widget build(BuildContext context) {
    final artist = album.artist?.trim() ?? '';
    return MusicFlowPressable(
      semanticLabel: <String>[
        '专辑 ${album.name}',
        if (artist.isNotEmpty) artist,
        if (album.starred) '已收藏',
      ].join('，'),
      onPressed: onPressed,
      onLongPress: onLongPress,
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.expandedSongRowHeight,
      ),
      borderRadius: BorderRadius.zero,
      child: Padding(
        padding:
            contentPadding ??
            EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
              vertical: context.musicFlowSpacing.xs,
            ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            ClipRRect(
              borderRadius: context.musicFlowRadii.detail,
              child: CoverArtImage(
                coverArtId: album.coverArt,
                size: 72,
                requestSize: 240,
                semanticLabel: '${album.name} 封面',
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    album.name,
                    maxLines: allowFullText ? null : 2,
                    overflow: allowFullText
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: context.musicFlowTypography.title,
                  ),
                  if (artist.isNotEmpty) ...<Widget>[
                    SizedBox(height: context.musicFlowSpacing.xxs),
                    Text(
                      artist,
                      maxLines: allowFullText ? null : 1,
                      overflow: allowFullText
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: context.musicFlowTypography.body.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.xs),
            if (album.starred)
              Icon(AppIcons.heart, size: 18, color: context.musicFlowColors.error),
            SizedBox(width: context.musicFlowSpacing.xs),
            Icon(
              AppIcons.chevronRight,
              size: 20,
              color: context.musicFlowColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class MusicFlowArtistRow extends StatelessWidget {
  const MusicFlowArtistRow({
    super.key,
    required this.artist,
    required this.onPressed,
    this.contentPadding,
  });

  final Artist artist;
  final VoidCallback onPressed;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final albumCount = artist.albumCount;
    return MusicFlowPressable(
      semanticLabel: <String>[
        '歌手 ${artist.name}',
        if (albumCount != null) '$albumCount 张专辑',
      ].join('，'),
      onPressed: onPressed,
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.expandedSongRowHeight,
      ),
      borderRadius: BorderRadius.zero,
      child: Padding(
        padding:
            contentPadding ??
            EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
              vertical: context.musicFlowSpacing.xs,
            ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            ClipOval(child: _ArtistImage(artist: artist)),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(artist.name, style: context.musicFlowTypography.title),
                  if (albumCount != null) ...<Widget>[
                    SizedBox(height: context.musicFlowSpacing.xxs),
                    Text(
                      '$albumCount 张专辑',
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.xs),
            Icon(
              AppIcons.chevronRight,
              size: 20,
              color: context.musicFlowColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistImage extends StatelessWidget {
  const _ArtistImage({required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final coverArt = artist.coverArt?.trim() ?? '';
    if (coverArt.isEmpty) {
      return ColoredBox(
        color: context.musicFlowColors.raised,
        child: SizedBox.square(
          dimension: 56,
          child: Center(
            child: Icon(
              AppIcons.profile,
              size: 24,
              color: context.musicFlowColors.muted,
            ),
          ),
        ),
      );
    }
    return CoverArtImage(
      coverArtId: coverArt,
      size: 56,
      requestSize: 192,
      semanticLabel: '${artist.name} 图片',
    );
  }
}

class MusicFlowLibrarySectionLabel extends StatelessWidget {
  const MusicFlowLibrarySectionLabel({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.musicFlowColors.canvas,
          border: Border(bottom: BorderSide(color: context.musicFlowColors.divider)),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            context.musicFlowPageHorizontalPadding,
            context.musicFlowSpacing.xs,
            44,
            context.musicFlowSpacing.xs,
          ),
          child: Text(
            label,
            style: context.musicFlowTypography.label.copyWith(
              color: context.musicFlowColors.accent,
            ),
          ),
        ),
      ),
    );
  }
}

typedef MusicFlowAzRevealBuilder =
    Widget Function(BuildContext context, double opacity, bool visible);

/// Reveals the alphabetical rail while the user scrolls or touches its edge.
///
/// The rail remains laid out while visually hidden so the first drag can jump
/// immediately instead of merely revealing the control for a second gesture.
class MusicFlowAzIndexReveal extends StatefulWidget {
  const MusicFlowAzIndexReveal({
    super.key,
    required this.builder,
    this.enabled = true,
  });

  final MusicFlowAzRevealBuilder builder;
  final bool enabled;

  @override
  State<MusicFlowAzIndexReveal> createState() => _MusicFlowAzIndexRevealState();
}

class _MusicFlowAzIndexRevealState extends State<MusicFlowAzIndexReveal> {
  static const Duration _lingerDuration = Duration(milliseconds: 1200);
  static const double _edgeActivationWidth = 40;

  Timer? _hideTimer;
  bool _visible = false;
  bool _pointerActive = false;

  @override
  void didUpdateWidget(covariant MusicFlowAzIndexReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _hideTimer?.cancel();
      _pointerActive = false;
      _visible = false;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _reveal() {
    if (!widget.enabled || !mounted) return;
    _hideTimer?.cancel();
    if (!_visible) setState(() => _visible = true);
    if (_pointerActive) return;
    _hideTimer = Timer(_lingerDuration, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _beginPointer(PointerDownEvent event, double width) {
    if (!widget.enabled ||
        event.localPosition.dx < width - _edgeActivationWidth) {
      return;
    }
    _pointerActive = true;
    _reveal();
  }

  void _endPointer() {
    if (!_pointerActive) return;
    _pointerActive = false;
    _reveal();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.builder(context, 0, false);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Listener(
          onPointerDown: (event) => _beginPointer(event, constraints.maxWidth),
          onPointerUp: (_) => _endPointer(),
          onPointerCancel: (_) => _endPointer(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification ||
                  notification is ScrollUpdateNotification ||
                  notification is UserScrollNotification) {
                _reveal();
              }
              return false;
            },
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: _visible ? 1 : 0),
              duration: context.musicFlowMotion.resolve(
                context,
                context.musicFlowMotion.feedback,
              ),
              curve: context.musicFlowMotion.easeOut,
              builder: (context, opacity, _) {
                return widget.builder(context, opacity, opacity > 0.01);
              },
            ),
          ),
        );
      },
    );
  }
}

class MusicFlowMediaListSkeleton extends StatelessWidget {
  const MusicFlowMediaListSkeleton({super.key, this.circle = false, this.count = 8});

  final bool circle;
  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      itemBuilder: (context, index) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            circle
                ? const MusicFlowSkeleton.circle(size: 56)
                : MusicFlowSkeleton(
                    width: 56,
                    height: 56,
                    borderRadius: context.musicFlowRadii.detail,
                  ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  MusicFlowSkeleton.line(width: 168 + (index % 3) * 24, height: 16),
                  SizedBox(height: context.musicFlowSpacing.xs),
                  MusicFlowSkeleton.line(width: 88 + (index % 2) * 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MusicFlowAlbumGridSkeleton extends StatelessWidget {
  const MusicFlowAlbumGridSkeleton({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final extent = textScale >= 1.6 ? 300.0 : 190.0;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.sm,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.lg,
      ),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: extent,
        childAspectRatio: 0.68,
        crossAxisSpacing: context.musicFlowSpacing.sm,
        mainAxisSpacing: context.musicFlowSpacing.sm,
      ),
      itemCount: count,
      itemBuilder: (context, index) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: MusicFlowSkeleton(
              height: double.infinity,
              borderRadius: context.musicFlowRadii.control,
            ),
          ),
          SizedBox(height: context.musicFlowSpacing.xs),
          MusicFlowSkeleton.line(width: 120 + (index % 3) * 18, height: 16),
          SizedBox(height: context.musicFlowSpacing.xs),
          MusicFlowSkeleton.line(width: 72 + (index % 2) * 24),
        ],
      ),
    );
  }
}
