import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/features/player/widgets/synced_lyrics_view.dart';

/// 全屏播放器歌词页窗格：加载中 / 空歌词 / 失败重试 / 同步歌词列表。
///
/// 从 `full_player_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class PlayerLyricsPane extends ConsumerWidget {
  const PlayerLyricsPane({super.key, this.activeColor});

  final Color? activeColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(currentLyricsProvider);
    final loc = AppLocalizations.of(context);
    // 高亮颜色跟随当前主题强调色；未显式指定时不再使用硬编码黄色。
    final lyricActiveColor = activeColor ?? context.musicFlowColors.accent;
    // RepaintBoundary：歌词列表即便发生重建/滚动，也只重绘本窗格，不扩散整页。
    return RepaintBoundary(
      child: lyricsAsync.when(
        data: (lyrics) {
          if (lyrics == null || lyrics.isEmpty) {
            return PlayerLyricsMessage(
              icon: AppIcons.lyrics,
              title: loc.player_no_lyrics_title,
              description: loc.player_no_lyrics_desc,
            );
          }
          final bestLyrics = lyrics.getBest();
          if (bestLyrics == null) {
            return PlayerLyricsMessage(
              icon: AppIcons.lyrics,
              title: loc.player_no_lyrics_title,
              description: loc.player_no_lyrics_desc,
            );
          }
          return SyncedLyricsView(
            lyrics: bestLyrics,
            // 大屏前台门控参数化：本页即大屏，显式开启歌词渲染。
            fullPlayerActive: true,
            activePrimaryColor: lyricActiveColor,
            activeSecondaryColor: lyricActiveColor,
            inactivePrimaryColor: context.musicFlowColors.muted,
            inactiveSecondaryColor: context.musicFlowColors.muted,
          );
        },
        loading: () => const PlayerLyricsLoading(),
        error: (error, stackTrace) => PlayerLyricsMessage(
          icon: AppIcons.error,
          title: loc.player_lyrics_load_failed_title,
          description: loc.player_lyrics_load_failed_desc,
          actionLabel: loc.widgets_retry,
          onAction: () => ref.invalidate(currentLyricsProvider),
        ),
      ),
    );
  }
}

/// 首屏的当前歌词行：歌名-歌手下方，1–2 行居中，muted 色（参考截图样式）。
/// 无歌词或未同步时整体隐藏，不占位。
class CurrentLyricLine extends ConsumerWidget {
  const CurrentLyricLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(currentLyricsProvider);
    // 用冻结进度：窗口不可见时当前歌词行不再随播放推进而重建。
    final position = ref.watch(frozenPositionProvider);
    // RepaintBoundary：首屏歌词行虽随进度 200~500ms 重建，但重绘隔离在本行内，
    // 不连带整页（含黑胶/背景）重绘。
    return RepaintBoundary(
      child: lyricsAsync.when(
        data: (lyrics) {
          if (lyrics == null || lyrics.isEmpty) {
            return const SizedBox.shrink();
          }
          final best = lyrics.getBest();
          if (best == null || !best.synced || best.lines.isEmpty) {
            return const SizedBox.shrink();
          }
          final index = syncedLyricIndexFor(best, position);
          final (primary, secondary) = lyricLineParts(best.lines[index].value);
          if (primary.isEmpty && (secondary?.isEmpty ?? true)) {
            return const SizedBox.shrink();
          }
          final muted = context.musicFlowColors.muted;
          final typography = context.musicFlowTypography;
          final duration = context.musicFlowMotion.resolve(
            context,
            context.musicFlowMotion.state,
          );
          return AnimatedSwitcher(
            duration: duration,
            child: Column(
              key: ValueKey<int>(index),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (primary.isNotEmpty)
                  Text(
                    primary,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.body.copyWith(
                      fontSize: typography.title.fontSize ?? 15,
                      color: muted,
                    ),
                  ),
                if (secondary != null && secondary.isNotEmpty) ...<Widget>[
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(
                    secondary,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.body.copyWith(
                      fontSize: typography.body.fontSize ?? 13,
                      color: muted.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        loading: () => const SizedBox.shrink(),
        error: (Object error, StackTrace stackTrace) => const SizedBox.shrink(),
      ),
    );
  }
}

/// 歌词页的空态 / 失败态消息块（图标 + 标题 + 描述 + 可选重试按钮）。
class PlayerLyricsMessage extends StatelessWidget {
  const PlayerLyricsMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.musicFlowSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              liveRegion: true,
              label: '$title，$description',
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 32, color: context.musicFlowColors.ink),
                    SizedBox(height: context.musicFlowSpacing.sm),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: context.musicFlowTypography.title.copyWith(
                        color: context.musicFlowColors.ink,
                      ),
                    ),
                    SizedBox(height: context.musicFlowSpacing.xs),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: context.musicFlowTypography.body.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              SizedBox(height: context.musicFlowSpacing.lg),
              MusicFlowButton.secondary(
                label: actionLabel!,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 歌词页加载中的骨架占位（四行宽度不一的灰条）。
class PlayerLyricsLoading extends StatelessWidget {
  const PlayerLyricsLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      label: loc.player_lyrics_loading,
      child: ExcludeSemantics(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final width in <double>[220, 280, 196, 250]) ...<Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.musicFlowColors.ink.withValues(alpha: 0.18),
                    borderRadius: context.musicFlowRadii.detail,
                  ),
                  child: SizedBox(width: width, height: 16),
                ),
                SizedBox(height: context.musicFlowSpacing.md),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
