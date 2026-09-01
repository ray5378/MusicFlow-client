import 'package:flutter/material.dart';

import '../core/design/music_flow_design.dart';
import '../core/utils/song_quality.dart';
import '../data/models/song.dart';
import 'music_flow_artwork.dart';
import 'music_flow_metadata_line.dart';
import 'now_playing_bars.dart';

enum MusicFlowSongRowVariant { albumTrack, standard, topRank }

/// A media-first song row with explicit playback and availability states.
class MusicFlowSongRow extends StatelessWidget {
  const MusicFlowSongRow({
    super.key,
    required this.song,
    this.index = 0,
    this.variant = MusicFlowSongRowVariant.standard,
    this.rank,
    this.coverArtId,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 8,
    ),
    this.onPressed,
    this.onLongPress,
    this.onMorePressed,
    this.moreSemanticLabel,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelected,
    this.isCurrent = false,
    this.isFavorite,
    this.isPreview,
    this.showMoreButton = true,
    this.titleMaxLines = 2,
    this.coverSize = 48,
    this.richMetadata = false,
  });

  static const double _numberWidth = 36;

  final Song song;
  final int index;
  final MusicFlowSongRowVariant variant;
  final int? rank;
  final String? coverArtId;
  final EdgeInsetsGeometry contentPadding;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final VoidCallback? onMorePressed;
  final String? moreSemanticLabel;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelected;
  final bool isCurrent;
  final bool? isFavorite;
  final bool? isPreview;
  final bool showMoreButton;

  /// 歌名最大行数。默认 2 行（常规列表）；首页随机歌曲传 1，
  /// 过长截断，保持行高与参考稿一致。
  final int titleMaxLines;

  /// 封面尺寸。默认 48；首页随机歌曲传 56 以匹配参考比例。
  final double coverSize;

  /// 底部信息行是否用「歌手 · 音质 · 码率 · 格式 · 大小 · 时长」的丰富格式。
  /// 默认 false（歌手 · 时长），仅首页随机歌曲开启。
  final bool richMetadata;

  bool get _favorite => isFavorite ?? song.starred;
  bool get _preview => isPreview ?? song.isPreview;

  @override
  Widget build(BuildContext context) {
    final artist = song.artist?.trim();
    final artistText = artist != null && artist.isNotEmpty ? artist : '-';
    final selectionAction = onToggleSelected ?? onPressed;
    final mainAction = selectionMode ? selectionAction : onPressed;
    final mainLongPress = selectionMode ? selectionAction : onLongPress;
    final moreAction =
        selectionMode || !showMoreButton ? null : onMorePressed ?? onLongPress;
    final semanticLabel = selectionMode
        ? <String>[
            song.title,
            artistText,
            song.durationString,
            if (selected) '已选择',
          ].join('，')
        : _buildSemanticLabel(artistText);
    final mainContent = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _buildLeading(context),
        SizedBox(width: context.musicFlowSpacing.sm),
        Expanded(child: _buildDetails(context, artistText)),
      ],
    );
    final hasMainAction = mainAction != null || mainLongPress != null;
    // 正在播放的高亮:背景淡 accent 铺底 + 一层柔和的同色阴影,让「当前播放」
    // 在播放队列与所有列表里都能一眼认出(与选中/收藏等文字状态互补)。
    final bool highlightCurrent = isCurrent && !selectionMode;
    final Color rowColor = highlightCurrent
        ? context.musicFlowColors.accent.withValues(alpha: 0.12)
        : selectionMode && selected
              ? context.musicFlowColors.accent.withValues(alpha: 0.1)
              : Colors.transparent;
    final main = hasMainAction
        ? MusicFlowPressable(
            semanticLabel: semanticLabel,
            selected: selectionMode ? selected : (isCurrent ? true : null),
            onPressed: mainAction,
            onLongPress: mainLongPress,
            minimumSize: const Size(0, 48),
            borderRadius: context.musicFlowRadii.control,
            child: mainContent,
          )
        : Semantics(
            container: true,
            selected: selectionMode ? selected : (isCurrent ? true : null),
            label: semanticLabel,
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: mainContent,
              ),
            ),
          );

    return AnimatedContainer(
      duration: context.musicFlowMotion.resolve(
        context,
        context.musicFlowMotion.feedback,
      ),
      curve: context.musicFlowMotion.easeOut,
      margin: contentPadding,
      decoration: BoxDecoration(
        color: rowColor,
        borderRadius: context.musicFlowRadii.control,
        boxShadow: highlightCurrent
            ? <BoxShadow>[
                BoxShadow(
                  color: context.musicFlowColors.accent.withValues(alpha: 0.16),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(child: main),
          if (selectionMode && selectionAction != null) ...<Widget>[
            SizedBox(width: context.musicFlowSpacing.xs),
            MusicFlowIconButton(
              icon: selected ? AppIcons.checkCircle : AppIcons.radio,
              label: selected ? '取消选择 ${song.title}' : '选择 ${song.title}',
              selected: selected,
              onPressed: selectionAction,
            ),
          ] else if (moreAction != null) ...<Widget>[
            SizedBox(width: context.musicFlowSpacing.xs),
            MusicFlowIconButton(
              icon: AppIcons.more,
              label: moreSemanticLabel ?? '${song.title}，更多操作',
              onPressed: moreAction,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetails(BuildContext context, String artistText) {
    final showFullText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final statusMarkers = <Widget>[
      if (_favorite)
        const _SongStatusMarker(icon: AppIcons.heart, label: '已收藏'),
      if (_preview) const _SongStatusMarker(icon: AppIcons.cloud, label: '试听'),
    ];

    // 标题与元信息用 Flexible 包裹:行本身处于有界高度(如首页随机歌曲的
    // 「紧凑三行带」)时,二者在有界高度内分配空间并收缩换行,超高部分被裁剪/
    // 省略,**不再触发 RenderFlex 溢出**;在常规无界高度列表里 Flexible(loose)
    // 仍取自然高度,行为与之前一致。
    // 随机歌曲（richMetadata）信息区为 3 行：歌名 / 歌手 / 刮削标签，
    // 整体高度与封面（56）等高；常规列表保持 title + metadata 两行。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: Text(
            song.title,
            maxLines: showFullText ? null : titleMaxLines,
            overflow: showFullText ? TextOverflow.visible : TextOverflow.ellipsis,
            style: context.musicFlowTypography.title.copyWith(
              color: isCurrent
                  ? context.musicFlowColors.accent
                  : context.musicFlowColors.ink,
            ),
          ),
        ),
        if (richMetadata) ...<Widget>[
          SizedBox(height: context.musicFlowSpacing.xxs),
          // 第 2 行：歌手（单行截断）。
          Flexible(
            child: Text(
              artistText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ),
        ],
        SizedBox(height: context.musicFlowSpacing.xxs),
        Flexible(
          child: richMetadata
              // 刮削标签行：FittedBox 自动缩放字号直到完整显示
              // （不硬编码更小字号，符合 SPEC 禁止写死字号的约束）。
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: MusicFlowMetadataLine(
                    items: songMetadataParts(song),
                    maxLines: 1,
                  ),
                )
              : MusicFlowMetadataLine(
                  items: <String?>[artistText, song.durationString],
                  maxLines: showFullText ? null : 2,
                ),
        ),
        if (statusMarkers.isNotEmpty) ...<Widget>[
          SizedBox(height: context.musicFlowSpacing.xxs),
          ExcludeSemantics(
            child: Wrap(
              spacing: context.musicFlowSpacing.sm,
              runSpacing: context.musicFlowSpacing.xxs,
              children: statusMarkers,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLeading(BuildContext context) {
    return switch (variant) {
      MusicFlowSongRowVariant.standard => SizedBox.square(
        dimension: coverSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: MusicFlowArtwork(
                coverArtId: coverArtId ?? song.artworkReference,
                semanticLabel: '${song.title} 封面',
                size: coverSize,
                requestSize: 192,
                borderRadius: context.musicFlowRadii.detail,
              ),
            ),
            // 正在播放：封面中央叠加半透明遮罩 + 白色跳动竖条（网易云风格）。
            // 队列等小封面直接正中间展示；大封面场景由上层组件另行处理。
            if (isCurrent)
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: context.musicFlowRadii.detail,
                  child: NowPlayingCoverOverlay(
                    size: coverSize,
                    alignment: Alignment.center,
                  ),
                ),
              ),
          ],
        ),
      ),
      MusicFlowSongRowVariant.albumTrack => _NumberLeading(
        value: song.track ?? index + 1,
        isCurrent: isCurrent,
      ),
      MusicFlowSongRowVariant.topRank => _NumberLeading(
        value: rank ?? index + 1,
        isCurrent: isCurrent,
        prominent: true,
      ),
    };
  }

  String _buildSemanticLabel(String artistText) {
    return <String>[
      if (isCurrent) '正在播放',
      song.title,
      artistText,
      song.durationString,
      if (_favorite) '已收藏',
      if (_preview) '试听',
    ].join('，');
  }
}

class _NumberLeading extends StatelessWidget {
  const _NumberLeading({
    required this.value,
    required this.isCurrent,
    this.prominent = false,
  });

  final int value;
  final bool isCurrent;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: MusicFlowSongRow._numberWidth,
      child: Center(
        child: isCurrent
            ? Icon(
                AppIcons.equalizer,
                size: 20,
                color: context.musicFlowColors.accent,
              )
            : Text(
                '$value',
                textAlign: TextAlign.center,
                style:
                    (prominent
                            ? context.musicFlowTypography.title
                            : context.musicFlowTypography.metadata)
                        .copyWith(
                          color: context.musicFlowColors.muted,
                          fontWeight: prominent ? FontWeight.w700 : null,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
              ),
      ),
    );
  }
}

class _SongStatusMarker extends StatelessWidget {
  const _SongStatusMarker({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: context.musicFlowColors.muted),
        SizedBox(width: context.musicFlowSpacing.xxs),
        Text(
          label,
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.muted,
          ),
        ),
      ],
    );
  }
}

/// Backwards-compatible variants used by existing library pages.
enum SongListItemVariant { albumTrack, standard }

/// Compatibility wrapper for call sites that still use [SongListItem].
class SongListItem extends StatelessWidget {
  const SongListItem({
    super.key,
    required this.song,
    required this.index,
    required this.variant,
    this.coverArtId,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 8,
    ),
    this.onTap,
    this.onLongPress,
    this.onMorePressed,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelected,
    this.isCurrent = false,
    this.isFavorite,
    this.isPreview,
  });

  final Song song;
  final int index;
  final SongListItemVariant variant;
  final String? coverArtId;
  final EdgeInsetsGeometry contentPadding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMorePressed;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelected;
  final bool isCurrent;
  final bool? isFavorite;
  final bool? isPreview;

  @override
  Widget build(BuildContext context) {
    return MusicFlowSongRow(
      song: song,
      index: index,
      variant: switch (variant) {
        SongListItemVariant.albumTrack => MusicFlowSongRowVariant.albumTrack,
        SongListItemVariant.standard => MusicFlowSongRowVariant.standard,
      },
      coverArtId: coverArtId,
      contentPadding: contentPadding,
      onPressed: onTap,
      onLongPress: onLongPress,
      onMorePressed: onMorePressed,
      selectionMode: selectionMode,
      selected: selected,
      onToggleSelected: onToggleSelected,
      isCurrent: isCurrent,
      isFavorite: isFavorite,
      isPreview: isPreview,
    );
  }
}
