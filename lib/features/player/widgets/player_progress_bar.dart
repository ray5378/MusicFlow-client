import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/features/player/widgets/player_scrubber.dart';

/// Buffered playback progress with a 48dp interaction target.
///
/// 从 `full_player_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）：
/// 拖动进度条 seek、缓冲二级值、loading 呼吸脉冲、冻结进度（窗口不可见时
/// 不随播放推进重建）。
class ProgressBar extends ConsumerStatefulWidget {
  const ProgressBar({super.key});

  @override
  ConsumerState<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends ConsumerState<ProgressBar>
    with SingleTickerProviderStateMixin {
  double? _dragValue;
  String? _dragSongId;
  late final AnimationController _loadingOpacityController;
  late final Animation<double> _loadingOpacity;
  bool _isLoadingPulseActive = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _loadingOpacityController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _loadingOpacity = Tween<double>(begin: 1, end: 0.52).animate(
      CurvedAnimation(
        parent: _loadingOpacityController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = context.musicFlowReduceMotion;
    if (_reduceMotion) {
      _loadingOpacityController
        ..stop()
        ..value = 0;
      _isLoadingPulseActive = false;
    }
  }

  @override
  void dispose() {
    _loadingOpacityController.dispose();
    super.dispose();
  }

  void _syncLoadingPulse(bool shouldPulse) {
    final resolved = shouldPulse && !_reduceMotion;
    if (resolved == _isLoadingPulseActive) return;
    _isLoadingPulseActive = resolved;
    if (resolved) {
      _loadingOpacityController.repeat(reverse: true);
    } else {
      _loadingOpacityController
        ..stop()
        ..value = 0;
    }
  }

  void _clearSeekSession() {
    _dragValue = null;
    _dragSongId = null;
  }

  void _cancelSeekSession() {
    if (_dragValue == null && _dragSongId == null) return;
    setState(_clearSeekSession);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    ref.listen<String?>(
      playerProvider.select((state) => state.currentSong?.id),
      (previous, next) {
        if (previous != next) _cancelSeekSession();
      },
    );
    final songAndBuffer = ref.watch(
      playerProvider.select(
        (state) => (
          songId: state.currentSong?.id,
          buffered: state.bufferedPosition,
          processing: state.processingState,
        ),
      ),
    );
    // 冻结进度：窗口不可见时进度条不再随播放推进而重建（省掉 200~500ms
    // 一次的高频重建与重绘）；可见时与真实进度完全一致。
    final effectivePosition = ref.watch(frozenPositionProvider);
    final effectiveDuration = ref.watch(effectiveDurationProvider);
    final state = (
      songId: songAndBuffer.songId,
      position: effectivePosition,
      duration: effectiveDuration,
      buffered: songAndBuffer.buffered,
      processing: songAndBuffer.processing,
    );
    final isLoading =
        state.processing == ProcessingState.loading ||
        state.processing == ProcessingState.buffering;
    _syncLoadingPulse(isLoading);

    final maxMilliseconds = state.duration.inMilliseconds > 0
        ? state.duration.inMilliseconds.toDouble()
        : 1.0;
    final activeDragValue = _dragSongId == state.songId ? _dragValue : null;
    final sliderValue =
        (activeDragValue ?? state.position.inMilliseconds.toDouble()).clamp(
          0.0,
          maxMilliseconds,
        );
    final bufferedValue = state.buffered.inMilliseconds
        .toDouble()
        .clamp(0.0, maxMilliseconds)
        .toDouble();
    final displayPosition = activeDragValue == null
        ? state.position
        : Duration(milliseconds: activeDragValue.round());
    final progressLabel =
        '${_formatDuration(displayPosition)} / ${_formatDuration(state.duration)}';
    final timeStyle = context.musicFlowTypography.metadata.copyWith(
      color: context.musicFlowColors.muted,
    );

    // 进度条与时间文本区域用 RepaintBoundary 隔离,进度高频更新不扩散整页重绘(SEC §8.2)。
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: context.musicFlowInteraction.minimumTouchTarget,
            child: AnimatedBuilder(
              animation: _loadingOpacity,
              builder: (context, child) => Opacity(
                opacity: isLoading && !_reduceMotion
                    ? _loadingOpacity.value
                    : 1,
                child: child,
              ),
              child: MusicFlowPlayerScrubber(
                key: ValueKey<String?>(state.songId),
                value: sliderValue,
                min: 0,
                max: maxMilliseconds,
                secondaryValue: bufferedValue,
                semanticStep: 10000,
                semanticLabel: loc.player_progress,
                semanticValue: progressLabel,
                semanticValueFormatter: (value) {
                  final position = Duration(milliseconds: value.round());
                  return '${_formatDuration(position)} / '
                      '${_formatDuration(state.duration)}';
                },
                activeColor: context.musicFlowColors.accent,
                secondaryColor: context.musicFlowColors.accent.withValues(
                  alpha: 0.42,
                ),
                inactiveColor: context.musicFlowColors.divider,
                thumbColor: context.musicFlowColors.ink,
                onChangeStart: state.duration <= Duration.zero
                    ? null
                    : (value) {
                        setState(() {
                          _dragSongId = state.songId;
                          _dragValue = value;
                        });
                      },
                onChanged: state.duration <= Duration.zero
                    ? null
                    : (value) {
                        if (_dragSongId != state.songId) return;
                        setState(() => _dragValue = value);
                      },
                onChangeEnd: state.duration <= Duration.zero
                    ? null
                    : (endedValue) {
                        final sessionSongId = _dragSongId;
                        // 取 scrubber 同步终值(最新),不用 _dragValue:后者经 setState
                        // 异步落盘,最后一次 dragUpdate 可能还没 flush,会偏小一帧。
                        final value = endedValue
                            .clamp(0.0, maxMilliseconds)
                            .toDouble();
                        setState(_clearSeekSession);
                        if (sessionSongId == null ||
                            sessionSongId != state.songId) {
                          return;
                        }
                        HapticFeedback.selectionClick();
                        unawaited(
                          seekEffectivePlayback(
                            ref,
                            Duration(milliseconds: value.round()),
                          ),
                        );
                      },
                onChangeCancel: state.duration <= Duration.zero
                    ? null
                    : (_) => _cancelSeekSession(),
              ),
            ),
          ),
          ExcludeSemantics(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.musicFlowSpacing.sm,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(_formatDuration(displayPosition), style: timeStyle),
                  Text(_formatDuration(state.duration), style: timeStyle),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final safe = duration.isNegative ? Duration.zero : duration;
    final minutes = safe.inMinutes;
    final seconds = safe.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
