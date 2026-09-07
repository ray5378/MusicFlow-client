import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

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
    final loc = AppLocalizations.of(context);
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
                          semanticLabel: loc.discover_cover_semantics(title),
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

