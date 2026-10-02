import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_slider.dart';
import 'package:musicflow_client/core/design/music_flow_context.dart';
import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_volume.dart';

/// L1 覆盖面板:队列 / 音量。互斥由 `remoteControlPanelProvider`(单一枚举)
/// 保证,同一时刻最多挂载一个;显隐只走「挂载 / 不挂载」,**不许**用
/// AnimatedContainer 改高度(会破坏固定高度,§8.4)。
///
/// 两个面板都必须自己包一层 `GestureDetector(behavior: opaque, onTap: (){})`
/// 抢占命中,否则点面板内部会触发外层「点面板外空白关闭」(套路同
/// volume_button.dart:112-126)。

/// 队列面板(U-1:覆盖**整块**,不是只盖 ②+③ —— 188dp 减 header/footer 只剩
/// 1 行可见,没有实用价值)。
///
/// 直接复用 `PlayQueueSheet(panel: true)`:它已内建「直投 > 投屏 > 本机」
/// 三态路由(链路 A 走 CastQueueSheetView、链路 B 走直投快照、本机走
/// PlayQueueSheetView),**不重写**。U-2:它的「选中即关闭面板」是客户端
/// 既有行为,保留,不照 HA 的「保持打开」。
///
/// `PlayQueueSheetView` 自带 `SafeArea(top: false)` —— 嵌进块内会吃进系统
/// 底部 inset 破坏固定高度,用 `MediaQuery.removePadding` 抵消 + `ClipRect` 卡死。
class RemoteControlQueuePanel extends ConsumerWidget {
  const RemoteControlQueuePanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 抢占命中:点击面板内部不触发「点面板外关闭」。
      onTap: () {},
      child: ClipRect(
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          child: PlayQueueSheet(panel: true, onClose: onClose),
        ),
      ),
    );
  }
}

/// 音量面板:**实底覆盖整块**的面板(surfaceContainerHighest 铺满,
/// 视觉上是「一块面板盖住整块」,而不是一条横滑条飘在歌词封面上),
/// 排版为 大百分比 + 静音键/滑条一行,关闭按钮右上角。
///
/// 静音按 G-1 **分路径**实现,不一刀切降级:
/// - 直投(dlnaCast)/ 投屏(castPeer)→ **真静音**(`setMuted`,两处已存在);
/// - 本机 → `playerProvider` 没有 `setMuted`,降级为「音量置 0 + 记住原值恢复」。
class RemoteControlVolumePanel extends ConsumerStatefulWidget {
  const RemoteControlVolumePanel({
    super.key,
    required this.metrics,
    this.onClose,
  });

  final RemoteControlMetrics metrics;
  final VoidCallback? onClose;

  @override
  ConsumerState<RemoteControlVolumePanel> createState() =>
      _RemoteControlVolumePanelState();
}

class _RemoteControlVolumePanelState
    extends ConsumerState<RemoteControlVolumePanel> {
  /// 拖动节流:≤100ms 一次,松手 `reset()` 后提交最终值(C6/C7)。
  late final ThrottledVolumeSender _sender = ThrottledVolumeSender(
    onSend: (v) => setEffectiveVolume(ref, v, live: true),
  );

  /// 本机路径静音前的音量(仅本机降级路径用)。
  double? _localVolumeBeforeMute;

  @override
  void dispose() {
    _sender.dispose();
    super.dispose();
  }

  Future<void> _toggleMute() async {
    final current = ref.read(effectiveVolumeProvider);
    // 直投(链路 B)→ 真静音。
    if (ref.read(dlnaCastProvider).isCasting) {
      await ref.read(dlnaCastProvider.notifier).setMuted(current > 0);
      return;
    }
    // 投屏(链路 A)→ 真静音(设备侧记住自己的音量,恢复交给 setMuted(false))。
    if (ref.read(castPeerControllerProvider).activePeer != null) {
      await ref.read(castPeerControllerProvider.notifier).setMuted(current > 0);
      return;
    }
    // 本机:playerProvider 没有 setMuted(G-1 缺口),降级 = 音量置 0 + 记住原值。
    // TODO(链路补强,不在本次范围): 真正的统一静音需要 playerProvider 补
    // `muted` 字段 + `setEffectiveMuted` 门面(架构 §1.3 G-1),补齐后本分支
    // 应整体换成真静音。
    if (current > 0) {
      _localVolumeBeforeMute = current;
      await setEffectiveVolume(ref, 0);
    } else {
      await setEffectiveVolume(ref, _localVolumeBeforeMute ?? 0.3);
      _localVolumeBeforeMute = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final volume = ref.watch(effectiveVolumeProvider);
    final percent = (volume * 100).round();

    // 实底面板:外层 ColoredBox 铺满整块(section 的 Positioned.fill 已给定
    // 口),保持 opaque GestureDetector 抢占命中不变;不改变块高(R14)。
    // 选中/静音态与控制条同口径:只走 accent 前景色,不加底色块。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Stack(
          children: <Widget>[
            // 关闭按钮:右上角,不占主行空间。
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: MusicFlowIconButton(
                  icon: AppIcons.close,
                  label: loc.player_close,
                  iconSize: 18,
                  backgroundColor: Colors.transparent,
                  onPressed: widget.onClose,
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.musicFlowSpacing.lg,
                  vertical: context.musicFlowSpacing.md,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      loc.home_remote_volume_percent('$percent'),
                      textAlign: TextAlign.center,
                      style: context.musicFlowTypography.display.copyWith(
                        fontSize: 22,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        MusicFlowIconButton(
                          icon: volume <= 0
                              ? AppIcons.volumeMute
                              : AppIcons.volumeHigh,
                          label: loc.home_remote_volume,
                          iconSize: widget.metrics.controlIconSize,
                          selected: volume <= 0,
                          backgroundColor: Colors.transparent,
                          onPressed: _toggleMute,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: MusicFlowSlider(
                            value: volume.clamp(0.0, 1.0).toDouble(),
                            min: 0,
                            max: 1,
                            semanticLabel: loc.home_remote_volume,
                            semanticValue: '$percent%',
                            onChanged: (v) => _sender.send(v),
                            onChangeEnd: (v) {
                              // 松手:复位节流并提交最终值(落盘,不再走节流)。
                              _sender.reset();
                              setEffectiveVolume(ref, v);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
