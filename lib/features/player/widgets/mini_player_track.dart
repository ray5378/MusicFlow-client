import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/features/player/widgets/mini_player_progress_surface.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';

/// 迷你播放条左侧曲目区：封面（外圈进度环 + Hero）+ 歌名/歌手 + 当前歌词行。
///
/// 从 `mini_player.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class MiniPlayerTrack extends StatelessWidget {
  const MiniPlayerTrack({
    super.key,
    required this.song,
    required this.showSubtitle,
    this.lyricLine,
    required this.lyricAccent,
    required this.coverRingProgress,
    required this.coverRingColor,
  });

  final Song? song;
  final bool showSubtitle;
  final String? lyricLine;

  /// 歌词高亮色：与大屏歌词页同源自适应暖黄。
  final Color lyricAccent;

  /// 封面外圈进度环：0~1 播放进度（浅底黑环、深底白环）。
  final double coverRingProgress;
  final Color coverRingColor;

  @override
  Widget build(BuildContext context) {
    final song = this.song;
    // 未播放时展示占位轨迹(对齐主项目前端「未在播放 / 选择一首歌曲开始播放」),
    // 迷你条保持常驻显示,不随播放状态隐藏。
    if (song == null) {
      return MiniPlayerEmptyTrack(showSubtitle: showSubtitle);
    }
    final artist = song.artist?.trim() ?? '';
    final album = song.album?.trim() ?? '';
    // 歌名 - 歌手 同一行（无歌手回退专辑名），歌词另起一行。
    final artistLine = artist.isNotEmpty ? artist : album;
    final lyric = lyricLine?.trim().isNotEmpty == true
        ? lyricLine!.trim()
        : null;
    final coverInner = MiniPlayerCover(song: song);
    // Hero 只包封面本体，进度环作为外层包装不参与飞行过渡。
    final coverHero = Hero(
      tag: playerCoverHeroTag,
      createRectTween: playerCoverRectTween,
      child: coverInner,
    );
    // RepaintBoundary:进度环 200~500ms 重绘隔离在 46px 环内,不连带
    // 封面/歌名/歌词/背景等整条迷你条重绘(智能按需渲染 §GPU 门控)。
    // 封面不再承载任何入口：唤出「流转播放」专用页面走最右侧按钮
    // （封面长按旧入口已移除，2026-09-16）。
    final cover = RepaintBoundary(
      child: MiniPlayerProgressRing(
        progress: coverRingProgress,
        color: coverRingColor,
        child: coverHero,
      ),
    );
    final title = MiniPlayerTitle(
      song: song,
      showArtist: showSubtitle,
      artistText: showSubtitle ? artistLine : '',
    );

    return Row(
      children: <Widget>[
        // 前导 2px：进度环的描边中心画在 46px 圆周上,外侧还会**超出 1px**;
        // cover 是本 Row 第一个元素,紧贴外层 ClipRect(裁标题/歌词滚动溢出)
        // 的左边界 —— 不留缝的话环的左侧弧线正好被裁掉(2026-09-16 用户实测)。
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 2),
          child: cover,
        ),
        SizedBox(width: context.musicFlowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Hero(
                tag: playerTitleHeroTag,
                createRectTween: playerLinearRectTween,
                flightShuttleBuilder: playerTextFlightShuttleBuilder,
                child: title,
              ),
              // 当前歌词行：暖黄高亮，取色与大屏歌词页一致（随封面自适应）。
              // RepaintBoundary:歌词行切换的重绘只影响本行文本区域。
              if (lyric != null)
                RepaintBoundary(
                  child: MiniPlayerLyric(text: lyric, color: lyricAccent),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 未播放时的迷你条占位轨迹（圆形音符 + 「未在播放」提示）。
class MiniPlayerEmptyTrack extends StatelessWidget {
  const MiniPlayerEmptyTrack({super.key, required this.showSubtitle});

  final bool showSubtitle;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Row(
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: context.musicFlowColors.surface,
            shape: BoxShape.circle,
          ),
          child: Icon(
            AppIcons.music,
            size: 22,
            color: context.musicFlowColors.muted,
          ),
        ),
        SizedBox(width: context.musicFlowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                loc.player_not_playing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.musicFlowTypography.title,
              ),
              if (showSubtitle)
                Text(
                  loc.player_choose_song_prompt,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.musicFlowTypography.metadata.copyWith(
                    color: context.musicFlowColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 迷你播放条圆形封面（44px，ClipOval）。
class MiniPlayerCover extends StatelessWidget {
  const MiniPlayerCover({super.key, required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return SizedBox.square(
      dimension: 44,
      child: ClipOval(
        child: CoverArtImage(
          coverArtId: song.artworkReference,
          size: 44,
          requestSize: 320,
          fit: BoxFit.cover,
          semanticLabel: loc.song_cover_semantic(song.title),
        ),
      ),
    );
  }
}

/// 迷你播放条歌名 - 歌手行：歌名大、歌手小（muted），超宽省略号截断。
class MiniPlayerTitle extends StatelessWidget {
  const MiniPlayerTitle({
    super.key,
    required this.song,
    this.showArtist = false,
    this.artistText = '',
  });

  final Song song;
  final bool showArtist;
  final String artistText;

  @override
  Widget build(BuildContext context) {
    final title = song.title.trim();
    final artist = artistText.trim();
    if (!showArtist || artist.isEmpty) {
      return Material(
        type: MaterialType.transparency,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.musicFlowTypography.title,
        ),
      );
    }
    // 歌名 - 歌手 同一行：歌名大，歌手小（muted），超宽时省略号截断，
    // 歌名在前优先保留。
    return Material(
      type: MaterialType.transparency,
      child: Text.rich(
        TextSpan(
          children: <TextSpan>[
            TextSpan(text: title, style: context.musicFlowTypography.title),
            TextSpan(
              text: ' - $artist',
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 迷你播放器当前歌词行：暖黄高亮，取色与大屏歌词页同源（随封面自适应）。
class MiniPlayerLyric extends StatelessWidget {
  const MiniPlayerLyric({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(top: context.musicFlowSpacing.xxs),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 歌词用 body(13) 而非 metadata(11)：现状偏小，适当放大。
          style: context.musicFlowTypography.body.copyWith(
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
