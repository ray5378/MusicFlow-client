import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/core/design/music_flow_context.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

class MusicFlowRefreshView extends StatefulWidget {
  const MusicFlowRefreshView({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  State<MusicFlowRefreshView> createState() => _MusicFlowRefreshViewState();
}

class _MusicFlowRefreshViewState extends State<MusicFlowRefreshView> {
  _RefreshPhase _phase = _RefreshPhase.idle;
  Timer? _resultTimer;

  void _handleStatusChange(RefreshIndicatorStatus? status) {
    if (!mounted) return;

    switch (status) {
      case RefreshIndicatorStatus.drag:
        _transitionTo(_RefreshPhase.pulling);
      case RefreshIndicatorStatus.armed:
        _transitionTo(_RefreshPhase.armed);
      case RefreshIndicatorStatus.snap:
      case RefreshIndicatorStatus.refresh:
        _transitionTo(_RefreshPhase.refreshing);
      case RefreshIndicatorStatus.done:
        _showResult(
          _phase == _RefreshPhase.failed
              ? _RefreshPhase.failed
              : _RefreshPhase.completed,
        );
      case RefreshIndicatorStatus.canceled:
        _transitionTo(_RefreshPhase.idle);
      case null:
        // RefreshIndicator currently does not report its terminal null status,
        // but keep result feedback stable if a future Flutter version does.
        if (!_phase.isResult) {
          _transitionTo(_RefreshPhase.idle);
        }
    }
  }

  Future<void> _performRefresh() async {
    _transitionTo(_RefreshPhase.refreshing);
    try {
      await widget.onRefresh();
    } catch (_) {
      // RefreshIndicator treats every completed callback as `done`, including
      // failed futures. Convert the error into an explicit UI result instead
      // of reporting a false success or leaking an unhandled async error.
      _transitionTo(_RefreshPhase.failed);
    }
  }

  void _transitionTo(_RefreshPhase nextPhase) {
    if (!mounted || _phase == nextPhase) return;
    _resultTimer?.cancel();
    _resultTimer = null;
    setState(() => _phase = nextPhase);
  }

  void _showResult(_RefreshPhase resultPhase) {
    assert(resultPhase.isResult);
    if (!mounted) return;

    _resultTimer?.cancel();
    _resultTimer = null;
    if (_phase != resultPhase) {
      setState(() => _phase = resultPhase);
    }

    _resultTimer = Timer(
      context.musicFlowMotion.scene + context.musicFlowMotion.feedback,
      () => _transitionTo(_RefreshPhase.idle),
    );
  }

  @override
  void dispose() {
    _resultTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // 安卓触屏端:恢复下拉刷新手势(可整页下拉刷新),但不再弹出文字气泡,
    // 避免与正常向下滚动冲突时出现的"下拉刷新"文字提示干扰。
    final isAndroidTouch =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    final motion = context.musicFlowMotion;
    final colors = context.musicFlowColors;
    final feedback = _RefreshFeedback.from(_phase, loc);
    final visible = !isAndroidTouch && feedback != null;
    // 安卓触屏端一直是「手势有、反馈无」：RefreshIndicator.noSpinner 刻意不画
    // 转圈，文字气泡又被下面那条 `!isAndroidTouch` 整块挡掉 —— 结果下拉刷新全程
    // 零反馈，用户看不出到底刷没刷。这里只补一个**纯动画**指示器（刻意不带文字，
    // 避免重蹈文字气泡在正常向下滚动时打扰用户的老路），并且**只在 refreshing
    // 阶段插入**：空闲时它根本不进 widget 树，不会影响任何按
    // CircularProgressIndicator 计数断言既有用例。
    final showTouchRefreshing =
        isAndroidTouch && _phase == _RefreshPhase.refreshing;
    final animationsDisabled = _animationsDisabled(context);
    final emphasisColor = feedback?.kind == _RefreshFeedbackKind.failed
        ? colors.error
        : colors.accent;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: RefreshIndicator.noSpinner(
            onRefresh: _performRefresh,
            onStatusChange: _handleStatusChange,
            elevation: 0,
            semanticsLabel: loc.core_pull_to_refresh,
            child: widget.child,
          ),
        ),
        // 安卓触屏端专属：刷新进行中浮一个只有动画、没有文字的指示器。
        // IgnorePointer 保证它绝不吃手势（下拉/滚动照常）；Semantics 只报
        // 「正在刷新」给读屏，没有可见文案。
        if (showTouchRefreshing)
          PositionedDirectional(
            top: context.musicFlowSpacing.sm,
            start: 0,
            end: 0,
            child: IgnorePointer(
              child: Semantics(
                liveRegion: true,
                label: loc.core_refreshing,
                child: Center(
                  child: ExcludeSemantics(
                    child: _TouchRefreshingIndicator(
                      animationsDisabled: animationsDisabled,
                    ),
                  ),
                ),
              ),
            ),
          ),
        // 安卓触屏端不渲染文字气泡:下拉刷新可用但全程无文字提示。
        if (!isAndroidTouch)
          PositionedDirectional(
          top: context.musicFlowSpacing.sm,
          start: 0,
          end: 0,
          child: IgnorePointer(
            child: Semantics(
              hidden: !visible,
              liveRegion: feedback?.announce ?? false,
              label: feedback?.label,
              child: AnimatedSlide(
                duration: motion.resolve(context, motion.feedback),
                curve: motion.easeOut,
                offset: visible ? Offset.zero : const Offset(0, -0.35),
                child: AnimatedOpacity(
                  duration: motion.resolve(context, motion.feedback),
                  curve: motion.easeOut,
                  opacity: visible ? 1 : 0,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: feedback?.emphasized == true
                            ? Color.alphaBlend(
                                emphasisColor.withValues(alpha: 0.12),
                                colors.surface,
                              )
                            : colors.surface,
                        borderRadius: context.musicFlowRadii.pill,
                        border: Border.all(
                          color: feedback?.emphasized == true
                              ? emphasisColor
                              : colors.controlBoundary,
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.musicFlowSpacing.sm,
                          vertical: context.musicFlowSpacing.xs,
                        ),
                        child: ExcludeSemantics(
                          child: feedback == null
                              ? const SizedBox.shrink()
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    _RefreshFeedbackIcon(feedback: feedback),
                                    SizedBox(width: context.musicFlowSpacing.xs),
                                    Text(
                                      feedback.label,
                                      style: context.musicFlowTypography.label
                                          .copyWith(color: colors.ink),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _RefreshPhase { idle, pulling, armed, refreshing, completed, failed }

extension on _RefreshPhase {
  bool get isResult =>
      this == _RefreshPhase.completed || this == _RefreshPhase.failed;
}

enum _RefreshFeedbackKind { pull, release, refreshing, done, failed }

class _RefreshFeedback {
  const _RefreshFeedback({
    required this.kind,
    required this.label,
    required this.announce,
    required this.emphasized,
  });

  final _RefreshFeedbackKind kind;
  final String label;
  final bool announce;
  final bool emphasized;

  static _RefreshFeedback? from(_RefreshPhase phase, AppLocalizations loc) {
    return switch (phase) {
      _RefreshPhase.idle => null,
      _RefreshPhase.pulling => _RefreshFeedback(
        kind: _RefreshFeedbackKind.pull,
        label: loc.core_pull_to_refresh,
        announce: false,
        emphasized: false,
      ),
      _RefreshPhase.armed => _RefreshFeedback(
        kind: _RefreshFeedbackKind.release,
        label: loc.core_release_to_refresh,
        announce: true,
        emphasized: true,
      ),
      _RefreshPhase.refreshing => _RefreshFeedback(
        kind: _RefreshFeedbackKind.refreshing,
        label: loc.core_refreshing,
        announce: true,
        emphasized: true,
      ),
      _RefreshPhase.completed => _RefreshFeedback(
        kind: _RefreshFeedbackKind.done,
        label: loc.core_refresh_complete,
        announce: true,
        emphasized: true,
      ),
      _RefreshPhase.failed => _RefreshFeedback(
        kind: _RefreshFeedbackKind.failed,
        label: loc.core_refresh_failed,
        announce: true,
        emphasized: true,
      ),
    };
  }
}

class _RefreshFeedbackIcon extends StatelessWidget {
  const _RefreshFeedbackIcon({required this.feedback});

  final _RefreshFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final animationsDisabled = _animationsDisabled(context);
    return switch (feedback.kind) {
      _RefreshFeedbackKind.refreshing =>
        animationsDisabled
            ? Icon(AppIcons.refresh, size: 18, color: colors.accent)
            : SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                  backgroundColor: colors.divider,
                ),
              ),
      _RefreshFeedbackKind.pull => Icon(
        AppIcons.chevronDown,
        size: 18,
        color: colors.muted,
      ),
      _RefreshFeedbackKind.release => Icon(
        AppIcons.refresh,
        size: 18,
        color: colors.accent,
      ),
      _RefreshFeedbackKind.done => Icon(
        AppIcons.check,
        size: 18,
        color: colors.accent,
      ),
      _RefreshFeedbackKind.failed => Icon(
        AppIcons.error,
        size: 18,
        color: colors.error,
      ),
    };
  }
}

/// 系统是否要求「减少动效」。
///
/// 抽成顶层函数供两处共用（桌面文字气泡的图标、安卓纯动画指示器），保证两边
/// 对无障碍设置的判断永远一致 —— 否则会出现「气泡已经不转了、指示器还在转」
/// 这种同一手势两套节奏的割裂。
bool _animationsDisabled(BuildContext context) {
  return MediaQuery.maybeOf(context)?.disableAnimations ??
      WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .disableAnimations;
}

/// 安卓触屏端的「刷新中」指示器：**只有动画，没有文字**。
///
/// 形态与桌面端文字气泡同源（surface 底 + controlBoundary 描边 + pill 圆角），
/// 只是把文案换成 16px 转圈、体量更小，浮在内容上方且不吃手势。开启「减少动效」
/// 时退化为静态 refresh 图标，与桌面气泡的处理保持一致。
class _TouchRefreshingIndicator extends StatelessWidget {
  const _TouchRefreshingIndicator({required this.animationsDisabled});

  final bool animationsDisabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: context.musicFlowRadii.pill,
        border: Border.all(color: colors.controlBoundary),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowSpacing.sm,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: animationsDisabled
            ? Icon(AppIcons.refresh, size: 18, color: colors.accent)
            : SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                  backgroundColor: colors.divider,
                ),
              ),
      ),
    );
  }
}
