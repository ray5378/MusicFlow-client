import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/features/player/widgets/full_player_chrome.dart';

/// 主播放控件行:循环/上一首/播放暂停/下一首/队列,对齐参考截图——
/// 播放模式与队列分列两侧,主按钮居中。
/// 投屏时该控件直接控制 DLNA 设备(切歌 = 把队列相邻曲目重新投射并同步游标)。
///
/// 从 `full_player_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({super.key, this.compact = false, this.onOpenQueue});

  // The Remix play glyph has a centered advance box, but its triangular ink
  // mass sits to the left of that center. Shift it by the measured optical
  // correction so it reads centered inside the circular transport control.
  static const double _playIconOpticalCorrection = 0.09;

  final bool compact;
  final VoidCallback? onOpenQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final isPlaying = ref.watch(effectiveIsPlayingProvider);
    final playbackMode = ref.watch(
      playerProvider.select((state) => state.playbackMode),
    );
    final cast = ref.watch(castPeerControllerProvider);
    final isCastMode = cast.activePeer != null;
    // 链路 B（局域网 DLNA 直投）投屏态，独立于链路 A 的 cast。
    final dlnaCast = ref.watch(dlnaCastProvider);
    // 投屏态:播放模式以后端 playMode 为准(order|one|all|shuffle);
    // 链路 B 投屏态:以 dlnaCast.playMode 为准(本机为遥控器);
    // 本机:以本地三态为准。
    final mode = isCastMode
        ? cast.playMode
        : (dlnaCast.isCasting
              ? dlnaCast.playMode
              : playbackMode.name); // 本机:四态权威值(order/all/one/shuffle)
    final modeIcon = switch (mode) {
      'shuffle' => AppIcons.shuffle,
      'one' => AppIcons.repeatOne,
      'order' => AppIcons.orderPlayback,
      _ => AppIcons.repeat,
    };
    final modeLabel = switch (mode) {
      'shuffle' => loc.player_mode_shuffle,
      'one' => loc.player_mode_loop_one,
      'order' => loc.player_mode_order,
      _ => loc.player_mode_list,
    };

    // 播放按钮尺寸随可用宽度自适应:5 个按钮(模式48 + 上一首48 + 播放 + 下一首
    // 48 + 队列48)在窄屏/高文字缩放下可能超出可用宽度(RenderFlex overflow,
    // 实测 320dp 时溢出 16px)。用 LayoutBuilder 感知约束,把播放按钮在
    // [48, 64] 区间内收缩,保证总宽恰好放得下;视觉上主按钮仍≥48(触控标准)。
    return LayoutBuilder(
      builder: (context, constraints) {
        const sideButton = 48.0;
        const minPlay = 48.0;
        final maxPlay = compact ? 56.0 : 64.0;
        // 可用宽度 - 4 个 48px 侧按钮 = 主播放按钮可分配宽度。
        final available = constraints.maxWidth;
        final playDimension = (available - sideButton * 4).clamp(
          minPlay,
          maxPlay,
        );
        final playIconSize = (playDimension - 24).clamp(26.0, 32.0);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                PlayerIconButton(
                  icon: modeIcon,
                  label: modeLabel,
                  // 白名单(同 mini):黑名单碰到意外值会判成 true ⇒ 永远高亮。
                  selected: mode == 'one' || mode == 'shuffle',
                  onPressed: () {
                    // 链路 B 投屏态:指挥 DLNA 设备;链路 A 投屏态下发后端 play-mode;
                    // 本机走本地三态。
                    if (dlnaCast.isCasting) {
                      ref.read(dlnaCastProvider.notifier).cyclePlayMode();
                    } else if (isCastMode) {
                      ref
                          .read(castPeerControllerProvider.notifier)
                          .cyclePlayMode();
                    } else {
                      ref.read(playerProvider.notifier).cyclePlaybackMode();
                    }
                  },
                ),
                PlayerIconButton(
                  icon: AppIcons.previous,
                  label: loc.player_previous,
                  onPressed: () => unawaited(previousEffectivePlayback(ref)),
                ),
                PlayerIconButton(
                  icon: isPlaying ? AppIcons.pause : AppIcons.play,
                  label: isPlaying ? loc.player_pause : loc.widgets_play,
                  emphasized: true,
                  dimension: playDimension,
                  iconSize: playIconSize,
                  iconOffset: isPlaying
                      ? Offset.zero
                      : Offset(playIconSize * _playIconOpticalCorrection, 0),
                  onPressed: () => unawaited(toggleEffectivePlayback(ref)),
                ),
                PlayerIconButton(
                  icon: AppIcons.next,
                  label: loc.player_next,
                  onPressed: () => unawaited(nextEffectivePlayback(ref)),
                ),
                PlayerIconButton(
                  icon: AppIcons.queue,
                  label: loc.player_queue,
                  onPressed: onOpenQueue,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
