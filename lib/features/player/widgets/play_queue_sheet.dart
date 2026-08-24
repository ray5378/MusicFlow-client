import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/peer.dart';
import '../../../data/models/song.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/palette_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/song_list_item.dart';
import 'song_options_sheet.dart';

/// 桌面端右侧队列面板是否已打开(防止重复叠加)。
bool _queuePanelOpen = false;

/// 播放队列入口:
/// - 移动端(compact):沿用底部弹窗(全宽、可滑动、不遮挡顶部内容)。
/// - 桌面端(medium/expanded):改为**非模态右侧面板**,只占窗口右侧一列,
///   其余内容不被遮挡、仍然可操作(对齐主项目 web 端右侧播放列表)。
Future<void> showPlayQueueSheet({
  required BuildContext context,
  bool useRootNavigator = true,
}) {
  if (context.echoWindowClass != EchoWindowClass.compact) {
    return showRightQueuePanel(context);
  }
  return showEchoBottomSheet<void>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    builder: (_) => const PlayQueueSheet(),
  );
}

/// 在根 Overlay 上插入一个非模态的右侧面板:
/// 面板自身仅占据右侧固定宽度,其余屏幕区域不覆盖任何 widget,
/// 点击/滚轮等交互会穿透到下层内容,保证「其他内容仍然可操作」。
Future<void> showRightQueuePanel(BuildContext context) async {
  if (_queuePanelOpen) return;
  _queuePanelOpen = true;
  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<void>();
  late OverlayEntry entry;
  void close() {
    if (entry.mounted) entry.remove();
    _queuePanelOpen = false;
    if (!completer.isCompleted) completer.complete();
  }

  entry = OverlayEntry(
    builder: (panelContext) => RightQueuePanel(onClose: close),
  );
  overlay.insert(entry);
  await completer.future;
}

/// 右侧队列面板容器:定位在窗口右侧、滑入动画、非模态。
class RightQueuePanel extends StatelessWidget {
  const RightQueuePanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final spacing = context.echoSpacing;
    final width = MediaQuery.sizeOf(context).width * 0.38;
    final panelWidth = width.clamp(320.0, 420.0);
    final motion = context.echoMotion;
    final duration = motion.resolve(context, motion.scene);

    return Positioned(
      key: const ValueKey<String>('right-queue-panel'),
      top: 0,
      right: 0,
      bottom: 0,
      width: panelWidth,
      child: Material(
        type: MaterialType.transparency,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 1, end: 0),
          duration: duration == Duration.zero
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: motion.easeOut,
          builder: (context, value, child) {
            return Transform.translate(
              offset: Offset(value * (spacing.lg + spacing.sm), 0),
              child: Opacity(opacity: 1 - value, child: child),
            );
          },
          child: PlayQueueSheet(panel: true, onClose: onClose),
        ),
      ),
    );
  }
}

/// Playback queue bound to the production player provider.
class PlayQueueSheet extends ConsumerWidget {
  const PlayQueueSheet({super.key, this.panel = false, this.onClose});

  /// 是否为右侧面板布局(桌面端)。false 时为底部弹窗布局。
  final bool panel;

  /// 面板关闭回调(非模态面板不依赖 Navigator,由 OverlayEntry 移除)。
  final VoidCallback? onClose;

  void _close(BuildContext context) {
    if (onClose != null) {
      onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cast = ref.watch(castPeerControllerProvider);
    // 投屏态:队列权威在后端,展示投屏队列快照并把操作路由到后端。
    if (cast.activePeer != null) {
      final castQueue = cast.castQueue.map(castQueueItemToSong).toList();
      return CastQueueSheetView(
        queue: castQueue,
        currentIndex: cast.castIndex,
        deviceName: cast.activePeer!.name,
        offline: cast.offline,
        panel: panel,
        onClose: () => _close(context),
        onSelect: (index) async {
          _close(context);
          await Future<void>.delayed(Duration.zero);
          unawaited(
            ref.read(castPeerControllerProvider.notifier).jumpTo(index),
          );
        },
        onRemove: (index) {
          ref.read(castPeerControllerProvider.notifier).removeQueueItem(index);
        },
        onReorder: (from, to) {
          ref.read(castPeerControllerProvider.notifier).reorderQueue(from, to);
        },
        onClear: () async {
          await ref.read(castPeerControllerProvider.notifier).clearCastQueue();
          if (context.mounted) _close(context);
        },
      );
    }

    final queueSnapshot = ref.watch(
      playerProvider.select(
        (state) => (
          currentSong: state.currentSong,
          queue: state.queue,
          currentIndex: state.currentIndex,
        ),
      ),
    );
    final visuals = ref.watch(resolvedCurrentSongMediaVisualsProvider);
    final playerState = PlayerState(
      currentSong: queueSnapshot.currentSong,
      queue: queueSnapshot.queue,
      currentIndex: queueSnapshot.currentIndex,
    );

    return PlayQueueSheetView(
      playerState: playerState,
      mediaVisuals: visuals,
      panel: panel,
      onClose: () => _close(context),
      onSelect: (index) async {
        final player = ref.read(playerProvider.notifier);
        _close(context);
        await Future<void>.delayed(Duration.zero);
        unawaited(player.skipToQueueItem(index));
      },
      onClear: () async {
        await ref.read(playerProvider.notifier).clearQueue();
        if (context.mounted) _close(context);
      },
      onOpenSongActions: (rowContext, index, song) {
        return showSongOptionsSheet(
          context: rowContext,
          song: song,
          mediaVisuals: visuals,
          extraActions: <SongOptionsExtraAction>[
            SongOptionsExtraAction(
              icon: AppIcons.removeCircle,
              title: '从队列移除',
              isDestructive: true,
              onPressed: () {
                ref.read(playerProvider.notifier).removeFromQueue(index);
              },
            ),
          ],
        );
      },
    );
  }
}

typedef QueueSongAction =
    Future<void> Function(BuildContext context, int index, Song song);

/// Provider-free queue surface for deterministic gesture and a11y tests.
@visibleForTesting
class PlayQueueSheetView extends StatelessWidget {
  const PlayQueueSheetView({
    super.key,
    required this.playerState,
    required this.onSelect,
    required this.onClear,
    required this.onOpenSongActions,
    this.mediaVisuals,
    this.albumColor,
    this.panel = false,
    this.onClose,
  });

  final PlayerState playerState;
  final EchoMediaVisuals? mediaVisuals;

  /// Compatibility seed for provider-free tests and older call sites.
  final Color? albumColor;
  final Future<void> Function(int index) onSelect;
  final Future<void> Function() onClear;
  final QueueSongAction onOpenSongActions;

  /// 是否为右侧面板布局(桌面端);false 时为底部弹窗布局。
  final bool panel;

  /// 面板关闭回调(非模态面板由 OverlayEntry 移除)。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final queue = playerState.queue;
    final currentIndex = playerState.currentIndex;
    final visuals =
        mediaVisuals ??
        EchoMediaVisuals.fallback(
          seed: albumColor ?? EchoColors.contentTintFallback,
        );
    final borderRadius = panel
        ? BorderRadius.horizontal(left: context.echoRadii.scene.topLeft)
        : BorderRadius.only(
            topLeft: context.echoRadii.scene.topLeft,
            topRight: context.echoRadii.scene.topRight,
          );

    Widget surface(ScrollController? scrollController) {
      return Semantics(
        container: true,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: '播放队列',
        child: EchoSurface(
          level: EchoSurfaceLevel.modal,
          color: context.echoColors.surface,
          borderRadius: borderRadius,
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              children: <Widget>[
                if (!panel) ...[
                  SizedBox(height: context.echoSpacing.xs),
                  Center(
                    child: ExcludeSemantics(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.echoColors.divider,
                          borderRadius: context.echoRadii.pill,
                        ),
                        child: const SizedBox(width: 36, height: 4),
                      ),
                    ),
                  ),
                ],
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    context.echoSpacing.md,
                    context.echoSpacing.sm,
                    context.echoSpacing.xs,
                    context.echoSpacing.sm,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Semantics(
                              header: true,
                              child: Text(
                                '播放队列',
                                style: context.echoTypography.headline,
                              ),
                            ),
                            SizedBox(height: context.echoSpacing.xxs),
                            Text(
                              '${queue.length} 首曲目',
                              style: context.echoTypography.metadata,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: context.echoSpacing.sm),
                      EchoIconButton(
                        icon: AppIcons.close,
                        label: '关闭播放队列',
                        onPressed: () {
                          if (onClose != null) {
                            onClose!();
                          } else {
                            Navigator.of(context).maybePop();
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const EchoDivider(),
                Expanded(
                  child: queue.isEmpty
                      ? const EchoEmptyState(
                          title: '队列为空',
                          description: '开始播放一首歌曲后，接下来的曲目会出现在这里。',
                          icon: AppIcons.queue,
                        )
                      : ListView.separated(
                          controller: scrollController,
                          padding: EdgeInsets.symmetric(
                            vertical: context.echoSpacing.xs,
                          ),
                          itemCount: queue.length,
                          separatorBuilder: (context, index) =>
                              SizedBox(height: context.echoSpacing.xxs),
                          itemBuilder: (context, index) {
                            final song = queue[index];
                            return EchoSongRow(
                              index: index,
                              song: song,
                              variant: EchoSongRowVariant.standard,
                              isCurrent: index == currentIndex,
                              contentPadding: EdgeInsetsDirectional.fromSTEB(
                                context.echoSpacing.md,
                                context.echoSpacing.xs,
                                context.echoSpacing.xs,
                                context.echoSpacing.xs,
                              ),
                              onPressed: () => unawaited(onSelect(index)),
                              onLongPress: () => unawaited(
                                onOpenSongActions(context, index, song),
                              ),
                              onMorePressed: () => unawaited(
                                onOpenSongActions(context, index, song),
                              ),
                              moreSemanticLabel: '${song.title}，更多操作',
                            );
                          },
                        ),
                ),
                const EchoDivider(),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    context.echoSpacing.md,
                    context.echoSpacing.xs,
                    context.echoSpacing.md,
                    context.echoSpacing.sm,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: EchoButton.ghost(
                      label: '清空后续队列',
                      semanticLabel: '清空后续播放队列，保留当前曲目',
                      leadingIcon: AppIcons.clearAll,
                      onPressed: queue.isEmpty
                          ? null
                          : () => unawaited(onClear()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final scope = EchoMediaColorScope(
      visuals: visuals,
      role: EchoMediaSurfaceRole.panel,
      child: panel
          ? surface(null)
          : DraggableScrollableSheet(
              initialChildSize: 0.72,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) => surface(scrollController),
            ),
    );
    return scope;
  }
}

/// 投屏队列面板(provider-free,便于确定性测试)——
/// 展示后端权威队列快照,操作经回调路由到后端 queue API。
@visibleForTesting
class CastQueueSheetView extends StatelessWidget {
  const CastQueueSheetView({
    super.key,
    required this.queue,
    required this.currentIndex,
    required this.deviceName,
    required this.onSelect,
    required this.onRemove,
    required this.onReorder,
    required this.onClear,
    this.offline = false,
    this.panel = false,
    this.onClose,
  });

  final List<Song> queue;
  final int currentIndex;
  final String deviceName;
  final bool offline;
  final Future<void> Function(int index) onSelect;
  final void Function(int index) onRemove;
  final void Function(int from, int to) onReorder;
  final Future<void> Function() onClear;

  /// 是否为右侧面板布局(桌面端);false 时为底部弹窗布局。
  final bool panel;

  /// 面板关闭回调(非模态面板由 OverlayEntry 移除)。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final borderRadius = panel
        ? BorderRadius.horizontal(left: context.echoRadii.scene.topLeft)
        : BorderRadius.only(
            topLeft: context.echoRadii.scene.topLeft,
            topRight: context.echoRadii.scene.topRight,
          );

    return EchoSurface(
      level: EchoSurfaceLevel.modal,
      color: context.echoColors.surface,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            if (!panel) ...[
              SizedBox(height: context.echoSpacing.xs),
              Center(
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.echoColors.divider,
                      borderRadius: context.echoRadii.pill,
                    ),
                    child: const SizedBox(width: 36, height: 4),
                  ),
                ),
              ),
            ],
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                context.echoSpacing.md,
                context.echoSpacing.sm,
                context.echoSpacing.xs,
                context.echoSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Semantics(
                          header: true,
                          child: Text(
                            '投屏队列',
                            style: context.echoTypography.headline,
                          ),
                        ),
                        SizedBox(height: context.echoSpacing.xxs),
                        Text(
                          '${queue.length} 首曲目 · 正在投屏到「$deviceName」'
                          '${offline ? ' · 设备离线' : ''}',
                          style: context.echoTypography.metadata,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.echoSpacing.sm),
                  EchoIconButton(
                    icon: AppIcons.close,
                    label: '关闭投屏队列',
                    onPressed: () {
                      if (onClose != null) {
                        onClose!();
                      } else {
                        Navigator.of(context).maybePop();
                      }
                    },
                  ),
                ],
              ),
            ),
            const EchoDivider(),
            Expanded(
              child: queue.isEmpty
                  ? const EchoEmptyState(
                      title: '投屏队列为空',
                      description: '后端投屏队列暂无曲目,可在歌曲菜单中添加到投屏队列。',
                      icon: AppIcons.queue,
                    )
                  : ReorderableListView.builder(
                      padding: EdgeInsets.symmetric(
                        vertical: context.echoSpacing.xs,
                      ),
                      buildDefaultDragHandles: false,
                      itemCount: queue.length,
                      onReorderItem: (from, to) {
                        // onReorderItem 的 to 已是移除后插入位置,直接下发后端 reorder。
                        if (from != to) onReorder(from, to);
                      },
                      proxyDecorator: (child, index, animation) => Material(
                        color: Colors.transparent,
                        elevation: 0,
                        child: child,
                      ),
                      itemBuilder: (context, index) {
                        final song = queue[index];
                        return KeyedSubtree(
                          key: ValueKey<String>('cast-queue-$index-${song.id}'),
                          child: ReorderableDelayedDragStartListener(
                            index: index,
                            child: EchoSongRow(
                              index: index,
                              song: song,
                              variant: EchoSongRowVariant.standard,
                              isCurrent: index == currentIndex,
                              contentPadding: EdgeInsetsDirectional.fromSTEB(
                                context.echoSpacing.md,
                                context.echoSpacing.xs,
                                context.echoSpacing.xs,
                                context.echoSpacing.xs,
                              ),
                              onPressed: () => unawaited(onSelect(index)),
                              onMorePressed: () => onRemove(index),
                              moreSemanticLabel: '${song.title}，从投屏队列移除',
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const EchoDivider(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.echoSpacing.md,
                context.echoSpacing.xs,
                context.echoSpacing.md,
                context.echoSpacing.sm,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: EchoButton.ghost(
                  label: '清空并停止投屏',
                  semanticLabel: '清空投屏队列并停止投屏',
                  leadingIcon: AppIcons.clearAll,
                  onPressed: queue.isEmpty ? null : () => unawaited(onClear()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
