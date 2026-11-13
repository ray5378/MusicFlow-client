import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';
import 'package:musicflow_client/features/player/widgets/full_player_chrome.dart';
import 'package:musicflow_client/features/player/widgets/local_dlna_cast_sheet.dart';
import 'package:musicflow_client/features/player/widgets/player_switcher.dart';
import 'package:musicflow_client/features/player/widgets/sleep_timer_sheet.dart';
import 'package:musicflow_client/features/player/widgets/volume_button.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// 全屏播放器工具条：DLNA 直投 / 喜欢 / 音量 / 定时暂停 / 流转播放。
///
/// 从 `full_player_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class PlayerUtilityBar extends ConsumerWidget {
  const PlayerUtilityBar({super.key, required this.currentSong});

  final Song currentSong;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final state = ref.watch(
      playerProvider.select(
        (state) => (starred: state.currentSong?.starred ?? currentSong.starred),
      ),
    );
    final cast = ref.watch(castPeerControllerProvider);
    // 链路 B（局域网 DLNA 直投）投屏态，独立于链路 A 的 cast。
    final dlnaCast = ref.watch(dlnaCastProvider);
    final sleepRemaining = ref.watch(sleepTimerProvider);
    final sleepActive = sleepRemaining != null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        // [D-046] 缺陷：宽 > 高但宽度 < 600 时仍进大屏分栏，左栏算出 186px，
        //   这个 Row（5 个 48dp 按钮）右侧溢出 54px（594x400 下实测红框）。
        //   建议：给 utility bar 加 Flexible/FittedBox，或在窄左栏下退化成 icon-only。
        //   守卫用例：test/features/player/b30c_full_player_page_cov_test.dart 窄宽布局用例。
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            // 链路 B（局域网 DLNA 直投）独立按钮：置于最左，与「流转播放」拉开距离，
            // 避免与链路 A（后端投屏）靠得太近而混淆。
            PlayerIconButton(
              icon: AppIcons.dlnaLocal,
              label: dlnaCast.isCasting
                  ? loc.player_dlna_local_casting(dlnaCast.currentDevice?.name ?? '')
                  : loc.player_dlna_local,
              selected: dlnaCast.isCasting,
              onPressed: () => unawaited(_openLocalDlnaCastSheet(context, ref)),
            ),
            PlayerIconButton(
              icon: state.starred ? AppIcons.heart : AppIcons.heartOutline,
              label: state.starred ? loc.player_unfavorite : loc.player_favorite,
              selected: state.starred,
              onPressed: () {
                ref.read(playerProvider.notifier).toggleFavorite();
              },
            ),
            // 音量：弹出式音量调节弹窗，与「喜欢」「流转播放」并排。
            const VolumeButton(),
            // 定时暂停:预设倒计时弹窗,到点后自动暂停(停止)播放。
            PlayerIconButton(
              icon: AppIcons.timer,
              label: sleepActive
                  ? _formatSleepRemaining(sleepRemaining, loc)
                  : loc.player_sleep_timer,
              selected: sleepActive,
              onPressed: () => unawaited(_openSleepTimerSheet(context, ref)),
            ),
            // 播放倍速(仅学习音频):位于「定时」与「流转播放」之间。
            // 与网页端一致 —— 只作用于学习音频，普通音乐恒 1.0 不显示该按钮。
            if (currentSong.isStudy)
              _PlaybackSpeedButton(
                speed: ref.watch(
                  playerProvider.select((s) => s.playbackSpeed),
                ),
                onPressed: () => unawaited(_openSpeedSheet(context, ref)),
              ),
            // 「流转播放」：使用 infinity(∞) 图标（2026-10-02 由信号塔换为 ∞），
            // 置于最右，与最左的 DLNA 直投拉开距离。
            PlayerIconButton(
              icon: AppIcons.transferInfinity,
              label: loc.player_transfer_playback_current(currentPlayerName(cast)),
              selected: cast.isCasting,
              onPressed: () => unawaited(_openPlayerSwitcher(context, ref)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSleepTimerSheet(BuildContext context, WidgetRef ref) async {
    final sleep = ref.read(sleepTimerProvider);
    final timerSet = sleep != null;
    // 结果：null=取消；SleepTimerOffSentinel=关闭已有定时；SleepTimerStartChoice=开始定时。
    final selected = await showDialog<Object?>(
      context: context,
      builder: (dialogContext) => SleepTimerSheet(
        hasExisting: timerSet,
        // 已有定时时把当前实际剩余分钟(向上取整,至少 1 分钟)回显到自定义步进器。
        initialMinutes: sleep != null ? sleep.inMinutes.clamp(1, 180) : 0,
      ),
    );
    if (!context.mounted) return;
    if (selected is SleepTimerStartChoice) {
      await ref.read(sleepTimerProvider.notifier).start(selected.duration);
    } else if (selected is SleepTimerOffSentinel) {
      await ref.read(sleepTimerProvider.notifier).cancel();
    }
  }

  static String _formatSleepRemaining(Duration? remaining, AppLocalizations loc) {
    if (remaining == null) return '';
    final minutes = remaining.inMinutes.ceil();
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours > 0) {
      if (mins == 0) return loc.player_sleep_timer_hours(hours);
      return '${loc.player_sleep_timer_hours(hours)} ${loc.player_sleep_timer_minutes(mins)}';
    }
    return loc.player_sleep_timer_minutes(mins);
  }

  Future<void> _openPlayerSwitcher(BuildContext context, WidgetRef ref) async {
    final loc = AppLocalizations.of(context);
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => const PlayerSwitcherSheet(),
    );
    if (!context.mounted) return;
    final cast = ref.read(castPeerControllerProvider);
    showMusicFlowToast(
      context,
      cast.activePeer != null
          ? loc.player_casting_to(currentPlayerName(cast))
          : loc.player_switched_local,
      kind: MusicFlowMessageKind.success,
    );
  }

  Future<void> _openLocalDlnaCastSheet(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final loc = AppLocalizations.of(context);
    // Windows 桌面端用「窗户」样式对话框（独立标题栏 + 等圆角），
    // 与安卓底部抽屉区分（对齐更新检测/设置页的平台样式策略）。
    if (isWindowsDesktop) {
      await showMusicFlowDesktopDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => MusicFlowDesktopDialog(
          icon: AppIcons.dlnaLocal,
          title: loc.player_dlna_local,
          subtitle: loc.player_dlna_dialog_subtitle,
          child: LocalDlnaCastSheet(),
        ),
      );
      return;
    }
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (dialogContext) => const LocalDlnaCastSheet(),
    );
  }

  /// 学习音频倍速选择面板（0.75x ~ 2x，与网页端同一档位）。
  Future<void> _openSpeedSheet(BuildContext context, WidgetRef ref) async {
    final loc = AppLocalizations.of(context);
    final current = ref.read(playerProvider).playbackSpeed;
    final selected = await showMusicFlowBottomSheet<double>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final colors = sheetContext.musicFlowColors;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    loc.player_speed,
                    style: sheetContext.musicFlowTypography.title,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    loc.player_speed_study_only,
                    style: sheetContext.musicFlowTypography.metadata.copyWith(
                      color: colors.muted,
                    ),
                  ),
                ),
                for (final rate in _playbackRates)
                  MusicFlowPressable(
                    onPressed: () => Navigator.of(sheetContext).pop(rate),
                    borderRadius: sheetContext.musicFlowRadii.surface,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${_formatRate(rate)}x',
                              style: sheetContext.musicFlowTypography.body,
                            ),
                          ),
                          if ((current - rate).abs() < 0.001)
                            Icon(
                              AppIcons.check,
                              size: 18,
                              color: colors.accent,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null || !context.mounted) return;
    await ref.read(playerProvider.notifier).setPlaybackSpeed(selected);
  }

  /// 与网页端 studyRate 一致的档位。
  static const List<double> _playbackRates = <double>[
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  static String _formatRate(double rate) {
    final text = rate.toStringAsFixed(2);
    return text.endsWith('0') ? text.substring(0, text.length - 1) : text;
  }
}

/// 倍速按钮：直接以当前倍速文案（如 `1.5x`）呈现，视觉规格与
/// [PlayerIconButton] 对齐（48dp 圆形可点区），便于与工具条其余按钮并排。
class _PlaybackSpeedButton extends StatelessWidget {
  const _PlaybackSpeedButton({required this.speed, required this.onPressed});

  final double speed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final active = (speed - 1.0).abs() > 0.001;
    return Tooltip(
      message: loc.player_speed,
      waitDuration: const Duration(milliseconds: 400),
      child: MusicFlowPressable(
        semanticLabel: loc.player_speed,
        selected: active,
        onPressed: onPressed,
        enableHaptics: true,
        minimumSize: const Size.square(48),
        borderRadius: context.musicFlowRadii.pill,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: Text(
              '${PlayerUtilityBar._formatRate(speed)}x',
              style: context.musicFlowTypography.metadata.copyWith(
                color: active ? colors.accent : colors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
