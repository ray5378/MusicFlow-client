import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 迷你播放条默认进度层：由 provider（冻结进度）供数，挂在其 progressLayer 位。
///
/// 从 `mini_player.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class ProviderMiniPlayerProgress extends ConsumerWidget {
  const ProviderMiniPlayerProgress({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 冻结进度：窗口不可见时拖拽手势层的 position 不再高频重建。
    // songId 用 select 只在切歌时重建（对齐全屏页的拖动守卫）。
    final position = ref.watch(frozenPositionProvider);
    final duration = ref.watch(effectiveDurationProvider);
    final songId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    return MiniPlayerProgressSurface(
      key: ValueKey<String?>(songId),
      songId: songId,
      position: position,
      duration: duration,
      onSeek: (target) => seekEffectivePlayback(ref, target),
    );
  }
}

/// 迷你播放条进度拖拽层：底部横向手势区（拖动 seek + 气泡回显）。
///
/// 进度可视化已改为封面外圈进度环（见 [MiniPlayerProgressRing]），这里只保留
/// 拖拽手势层与气泡。切歌后旧拖动会话立即作废，防止把旧歌比例换算到新歌
/// duration 上（对齐全屏页 `_dragSongId` 守卫）。
class MiniPlayerProgressSurface extends StatefulWidget {
  const MiniPlayerProgressSurface({
    super.key,
    required this.songId,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final String? songId;
  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration target) onSeek;

  @override
  State<MiniPlayerProgressSurface> createState() =>
      _MiniPlayerProgressSurfaceState();
}

class _MiniPlayerProgressSurfaceState
    extends State<MiniPlayerProgressSurface> {
  double _scrubViewportWidth = 1;
  double? _scrubProgress;
  bool _scrubbing = false;
  // 拖动会话开始时锁定的歌曲 id：切歌后旧拖动会话立即作废，
  // 防止把旧歌的比例换算到新歌 duration 上（对齐全屏页 _dragSongId）。
  String? _scrubSongId;

  void _handleProgressDragStart(DragStartDetails details) {
    if (widget.duration <= Duration.zero) return;
    setState(() {
      _scrubbing = true;
      _scrubSongId = widget.songId;
      _scrubProgress = _progressFromDx(details.localPosition.dx);
    });
  }

  void _handleProgressDragUpdate(DragUpdateDetails details) {
    if (!_scrubbing || widget.duration <= Duration.zero) return;
    if (_scrubSongId != widget.songId) {
      _handleProgressDragCancel();
      return;
    }
    setState(() {
      _scrubProgress = _progressFromDx(details.localPosition.dx);
    });
  }

  void _handleProgressDragEnd(DragEndDetails details) {
    final progress = _scrubProgress;
    final durationMs = widget.duration.inMilliseconds;
    // 只有拖动会话锁定的歌曲与当前歌曲一致时才 seek。
    final sameSong = _scrubSongId != null && _scrubSongId == widget.songId;
    if (_scrubbing && progress != null && durationMs > 0 && sameSong) {
      HapticFeedback.selectionClick();
      unawaited(
        widget.onSeek(Duration(milliseconds: (durationMs * progress).round())),
      );
    }
    setState(() {
      _scrubbing = false;
      _scrubProgress = null;
      _scrubSongId = null;
    });
  }

  void _handleProgressDragCancel() {
    if (!_scrubbing) return;
    setState(() {
      _scrubbing = false;
      _scrubProgress = null;
      _scrubSongId = null;
    });
  }

  double _progressFromDx(double dx) {
    return (dx / _scrubViewportWidth).clamp(0.0, 1.0);
  }

  void _seekRelative(Duration delta) {
    if (widget.duration <= Duration.zero) return;
    final targetMs = (widget.position + delta).inMilliseconds
        .clamp(0, widget.duration.inMilliseconds)
        .toInt();
    HapticFeedback.selectionClick();
    unawaited(widget.onSeek(Duration(milliseconds: targetMs)));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final progress = widget.duration.inMilliseconds > 0
        ? widget.position.inMilliseconds / widget.duration.inMilliseconds
        : 0.0;
    final displayedProgress = (_scrubProgress ?? progress).clamp(0.0, 1.0);
    final displayedPosition = _scrubProgress == null
        ? widget.position
        : Duration(
            milliseconds: (widget.duration.inMilliseconds * displayedProgress)
                .round(),
          );
    final progressValue = _formatPlayerProgress(
      displayedPosition,
      widget.duration,
    );

    return Stack(
      children: <Widget>[
        PositionedDirectional(
          start: 0,
          end: 196,
          bottom: 0,
          height: 20,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _scrubViewportWidth = constraints.maxWidth;
              return Semantics(
                label: loc.player_progress,
                value: progressValue,
                increasedValue: loc.player_seek_forward,
                decreasedValue: loc.player_seek_backward,
                onIncrease: () => _seekRelative(const Duration(seconds: 10)),
                onDecrease: () => _seekRelative(const Duration(seconds: -10)),
                child: GestureDetector(
                  key: const Key('mini-player-scrubber'),
                  behavior: HitTestBehavior.translucent,
                  excludeFromSemantics: true,
                  onHorizontalDragStart: _handleProgressDragStart,
                  onHorizontalDragUpdate: _handleProgressDragUpdate,
                  onHorizontalDragEnd: _handleProgressDragEnd,
                  onHorizontalDragCancel: _handleProgressDragCancel,
                ),
              );
            },
          ),
        ),
        // 底部横向进度条已移除：进度改为封面外圈进度环（见
        // MiniPlayerProgressRing），这里只保留拖拽手势层与气泡。
        if (_scrubbing)
          PositionedDirectional(
            start: context.musicFlowSpacing.sm,
            end: 196,
            bottom: 18,
            child: MiniPlayerScrubBubble(
              progress: displayedProgress,
              duration: widget.duration,
            ),
          ),
      ],
    );
  }
}

String _formatPlayerProgress(Duration position, Duration duration) {
  return '${_formatPlayerDuration(position)} / ${_formatPlayerDuration(duration)}';
}

String _formatPlayerDuration(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  final minutes = safe.inMinutes;
  final seconds = safe.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 封面外圈播放进度环：替代底部横向进度条（对齐箭头音乐）。
///
/// 环色由底色明暗决定：浅底黑环、深底白环（与 [MusicFlowColors.readableOn]
/// 同规则），保证任意封面上都清晰可见。
class MiniPlayerProgressRing extends StatelessWidget {
  const MiniPlayerProgressRing({
    super.key,
    required this.progress,
    required this.color,
    required this.child,
  });

  final double progress;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // 高度核算（避免圆环被播放条裁剪）：
    //   播放条 = MiniPlayer.height(56)；内容区 = 56 - 上下 padding(4+4) = 48；
    //   环取 46（封面 44 + 两侧各 1），在 48 内容区内居中，上下各留 1px 余量，
    //   任何 1px 级的布局误差都不会触发 ClipRect(48) 裁剪。
    //   注意环描边中心画在圆周上,实际外沿还要**再超出 1px** —— 上下恰好贴着
    //   1px 余量,左右则由 track Row 的前导 2px 间隙兜住（见 MiniPlayerTrack）。
    const double ringDimension = 46;
    const double coverDimension = 44;
    final normalized = progress.clamp(0.0, 1.0).toDouble();
    return SizedBox.square(
      dimension: ringDimension,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          SizedBox.square(
            dimension: ringDimension,
            child: Semantics(
              label: loc.player_progress_percent((normalized * 100).round()),
              child: ExcludeSemantics(
                child: CircularProgressIndicator(
                  value: normalized,
                  strokeWidth: 2,
                  // 底色用同色低透明度做轨道，让环在任意底色上都可辨认。
                  backgroundColor: color.withValues(alpha: 0.18),
                  color: color,
                ),
              ),
            ),
          ),
          SizedBox.square(
            dimension: coverDimension,
            child: child,
          ),
        ],
      ),
    );
  }
}

/// 迷你播放条拖动进度时的时间气泡。
class MiniPlayerScrubBubble extends StatelessWidget {
  const MiniPlayerScrubBubble({
    super.key,
    required this.progress,
    required this.duration,
  });

  final double progress;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final position = Duration(
      milliseconds: (duration.inMilliseconds * progress).round(),
    );

    return Align(
      alignment: Alignment((progress * 2 - 1).clamp(-1.0, 1.0), 0),
      child: MusicFlowSurface(
        level: MusicFlowSurfaceLevel.floating,
        color: context.musicFlowColors.ink,
        borderRadius: context.musicFlowRadii.detail,
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowSpacing.xs,
          vertical: context.musicFlowSpacing.xxs,
        ),
        child: Text(
          _formatPlayerDuration(position),
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.canvas,
          ),
        ),
      ),
    );
  }
}
