import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

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
    final loc = AppLocalizations.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: MusicFlowPressable(
        semanticLabel: '${playlist.name}，'
            '${loc.discover_track_count('${playlist.songCount}')}',
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
                          semanticLabel: loc.discover_cover_semantics(playlist.name),
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
                      '${loc.discover_track_count('${playlist.songCount}')} · ${playlist.durationString}',
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
    this.alwaysFresh = false,
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

  /// 动态歌单（今日漫游/每日推荐/本地推荐/随机歌曲）封面每日变化，传 true
  /// 使封面不读不写离线缓存，冷启动每次重拉。
  final bool alwaysFresh;

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
                              alwaysFresh: alwaysFresh,
                              semanticLabel: loc.discover_cover_semantics(title),
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
    final loc = AppLocalizations.of(context);
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
              label: loc.discover_play_playlist,
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

