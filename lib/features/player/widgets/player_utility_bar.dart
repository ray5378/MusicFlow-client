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
}
