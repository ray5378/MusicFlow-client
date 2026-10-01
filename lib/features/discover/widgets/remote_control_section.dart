import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/components/music_flow_empty_state.dart';
import 'package:musicflow_client/core/design/components/music_flow_skeleton.dart';
import 'package:musicflow_client/core/design/music_flow_context.dart';
import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_body.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/home_remote_control_provider.dart';

/// 首页「播放控制」整体块 —— **唯一被 discover_page 引用的入口**。
///
/// 结构(固定高度 + Stack 分层,对应架构 §2.2):
/// ```
/// SizedBox(height: metrics.totalHeight)   ← 恒定,任何状态都不变
///   └ ClipRRect → Stack
///       ├ L0: ① 切换器 / ② Now 区 / ③ 控制条 + 进度条   (T03 填真实内容)
///       ├ 告警条:覆盖在进度条那一槽(不改变块高)
///       └ L1: 队列 / 音量覆盖面板                        (T04 接)
/// ```
/// 加载骨架 / 空态同样是「替换 L0 内容」,盒子高度恒定 → 首页后续分区零位移。
class RemoteControlSection extends ConsumerStatefulWidget {
  const RemoteControlSection({super.key});

  @override
  ConsumerState<RemoteControlSection> createState() =>
      _RemoteControlSectionState();
}

class _RemoteControlSectionState extends ConsumerState<RemoteControlSection> {
  /// 注意:本仓 `ConsumerState` 的 `ref` 是**成员**(见 main_scaffold 的
  /// `_MainScaffoldState`),build 只收 `BuildContext` —— 不要写成
  /// `build(BuildContext, WidgetRef)`(会 invalid_override)。
  @override
  Widget build(BuildContext context) {
    final metrics = remoteControlMetricsFor(context);
    final loc = AppLocalizations.of(context);
    final horizontal = context.musicFlowPageHorizontalPadding - 5;

    final peersAsync = ref.watch(remoteControlPeersProvider);
    final targets = ref.watch(remoteControlTargetsProvider);
    final alert = ref.watch(remoteControlAlertProvider);
    final panel = ref.watch(remoteControlPanelProvider);

    // 加载中:骨架占满整块(高度 = 内容区高度,外盒仍恒定)。
    final loading = peersAsync.isLoading && targets.isEmpty;

    final Widget content;
    if (loading) {
      content = Padding(
        padding: _contentPadding(metrics, horizontal),
        child: MusicFlowSkeleton(height: metrics.bodyHeight),
      );
    } else if (targets.isEmpty) {
      // 空态 ①:一个可控制端都没有(未登录 / 服务端无 peer)。
      // 注意 Q7:只有「本机」一个端时 targets 非空,不会落到这里。
      content = Padding(
        padding: _contentPadding(metrics, horizontal),
        child: MusicFlowEmptyState(
          title: loc.home_remote_no_device,
          description: '',
          icon: AppIcons.speaker,
          actionLabel: loc.player_refresh_players,
          onAction: () => ref.invalidate(remoteControlPeersProvider),
          padding: const EdgeInsets.all(24),
        ),
      );
    } else {
      content = Padding(
        padding: _contentPadding(metrics, horizontal),
        child: RemoteControlBody(metrics: metrics),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontal),
      child: SizedBox(
        height: metrics.totalHeight,
        child: GestureDetector(
          // 「点面板外空白关闭面板」的外层命中面(T04 接上真实面板后生效:
          // 面板内部会再包一层 opaque GestureDetector 抢占命中)。
          behavior: panel == RemoteControlPanelKind.none
              ? HitTestBehavior.deferToChild
              : HitTestBehavior.opaque,
          onTap: panel == RemoteControlPanelKind.none
              ? null
              : () => ref.read(remoteControlPanelProvider.notifier).state =
                  RemoteControlPanelKind.none,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.45),
              ),
              child: ClipRect(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(child: content),
                    if (alert != RemoteControlAlert.none)
                      _alertBar(context, metrics, loc, alert, horizontal),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 内容区内边距:垂直方向照 [RemoteControlMetrics.padding],
  /// 水平方向用与 discover_page 完全同一个表达式(→ R19 左缘对齐)。
  EdgeInsets _contentPadding(RemoteControlMetrics metrics, double horizontal) =>
      EdgeInsets.fromLTRB(
        horizontal,
        metrics.padding.top,
        horizontal,
        metrics.padding.bottom,
      );

  /// 告警条:**覆盖在进度条那一槽**,不是新增一行 —— 出现/消失都不改变块高。
  /// 不可达/离线时进度本来就没有意义,让告警占掉它是最省事且零位移的做法。
  Widget _alertBar(
    BuildContext context,
    RemoteControlMetrics metrics,
    AppLocalizations loc,
    RemoteControlAlert alert,
    double horizontal,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final text = alert == RemoteControlAlert.unreachable
        ? loc.home_remote_unreachable
        : loc.home_remote_offline;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: metrics.progressHeight,
      child: ColoredBox(
        color: scheme.errorContainer,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          child: Row(
            children: <Widget>[
              Icon(
                AppIcons.warning,
                size: metrics.controlIconSize * 0.7,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
