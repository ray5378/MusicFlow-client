import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/design/media/music_flow_media_color_scope.dart';
import '../../../data/models/peer.dart';
import '../../../data/models/song.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/dlna_provider.dart';
import '../../../providers/palette_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/song_list_item.dart';
import 'song_options_sheet.dart';

/// 桌面端右侧队列面板是否已打开(防止重复叠加)。
bool _queuePanelOpen = false;

/// 已打开的右侧队列面板的关闭回调(供「队列」按钮二次点击切换关闭)。
VoidCallback? _activeQueueClose;

/// 同步关闭已打开的右侧队列面板(幂等,未打开时无副作用)。
void closeRightQueuePanel() {
  final cb = _activeQueueClose;
  _activeQueueClose = null;
  cb?.call();
}

/// 桌面端「播放队列」按钮:面板已打开则关闭,否则打开。
void toggleRightQueuePanel({required BuildContext context}) {
  if (_queuePanelOpen) {
    closeRightQueuePanel();
    return;
  }
  unawaited(showRightQueuePanel(context));
}

/// 播放队列入口:
/// - 移动端(compact):沿用底部弹窗(全宽、可滑动、不遮挡顶部内容)。
/// - 桌面端(medium/expanded):改为**非模态右侧面板**,只占窗口右侧一列,
///   其余内容不被遮挡、仍然可操作(对齐主项目 web 端右侧播放列表)。
Future<void> showPlayQueueSheet({
  required BuildContext context,
  bool useRootNavigator = true,
}) {
  if (context.musicFlowWindowClass != MusicFlowWindowClass.compact) {
    return showRightQueuePanel(context);
  }
  return showMusicFlowBottomSheet<void>(
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
    _activeQueueClose = null;
    if (entry.mounted) entry.remove();
    _queuePanelOpen = false;
    if (!completer.isCompleted) completer.complete();
  }

  entry = OverlayEntry(
    builder: (panelContext) => RightQueuePanel(onClose: close),
  );
  _activeQueueClose = close;
  overlay.insert(entry);
  await completer.future;
}

/// 右侧队列面板容器:定位在窗口右侧、滑入动画、非模态。
class RightQueuePanel extends StatelessWidget {
  const RightQueuePanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    // 队列面板随窗口缩放(约 1/6 窗宽),并让最小/最大宽度进一步收窄,
    // 让面板更窄、更悬浮,避免在桌面窗口里占据过大横向空间。
    final width = MediaQuery.sizeOf(context).width * 0.17;
    final panelWidth = width.clamp(150.0, 220.0);
    final motion = context.musicFlowMotion;
    final duration = motion.resolve(context, motion.scene);

    final size = MediaQuery.sizeOf(context);
    // 上下各留固定比例空白:桌面端队列改为「中间带」形态(对齐网易云客户端),
    // 不占满整窗高度,顶部给窗口留白、底部给留白,更接近悬浮面板。
    final verticalInset = (size.height * 0.12).clamp(44.0, 152.0);

    return Positioned(
      key: const ValueKey<String>('right-queue-panel'),
      top: verticalInset,
      right: 0,
      bottom: verticalInset,
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

    // 链路 B（局域网 DLNA 直投）投屏态：展示直投队列快照(经本机镜像),
    // 与链路 A 对齐：支持点歌跳播、从队列移除、拖拽排序与「清空并停止投屏」。
    final dlnaCast = ref.watch(dlnaCastProvider);
    if (dlnaCast.isCasting) {
      // 镜像队列为完整 Song（含封面等视觉信息），与 dlnaCast.queue 下标一一对应。
      final dQueue = ref.read(playerProvider).queue;
      return CastQueueSheetView(
        queue: dQueue,
        currentIndex: dlnaCast.currentIndex,
        deviceName: dlnaCast.currentDevice?.name ?? '局域网设备',
        offline: false,
        panel: panel,
        onClose: () => _close(context),
        onSelect: (index) async {
          _close(context);
          await Future<void>.delayed(Duration.zero);
          unawaited(ref.read(dlnaCastProvider.notifier).playAt(index));
        },
        onRemove: (index) {
          ref.read(dlnaCastProvider.notifier).removeQueueItem(index);
        },
        onReorder: (from, to) {
          ref.read(dlnaCastProvider.notifier).reorderQueue(from, to);
        },
        onClear: () async {
          await ref.read(dlnaCastProvider.notifier).stopCast();
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
  final MusicFlowMediaVisuals? mediaVisuals;

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
        MusicFlowMediaVisuals.fallback(
          seed: albumColor ?? MusicFlowColors.contentTintFallback,
        );
    final borderRadius = panel
        ? BorderRadius.horizontal(left: context.musicFlowRadii.scene.topLeft)
        : BorderRadius.only(
            topLeft: context.musicFlowRadii.scene.topLeft,
            topRight: context.musicFlowRadii.scene.topRight,
          );

    Widget surface(ScrollController? scrollController) {
      // 关键修复:在 media scope 内部再包一层 Builder,以 scope 内的 context 取色。
      // 否则本方法闭包捕获的是 PlayQueueSheetView.build 的 context(位于 scope
      // 之上),`context.musicFlowColors.surface` 会解析成全局主题表面。深色封面下
      // media 文字是白色,叠加在全局白色 surface 上即为「白底白字」;反之浅色封面在
      // 深色主题下又会「黑底黑字」。改用 scope 内的 context 后,背景与文字同源一致。
      return Builder(
        builder: (scopedContext) {
          final scopedColors = scopedContext.musicFlowColors;
          final scopedTypography = scopedContext.musicFlowTypography;
          final scopedSpacing = scopedContext.musicFlowSpacing;
          final scopedRadii = scopedContext.musicFlowRadii;
          return Semantics(
            container: true,
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            label: '播放队列',
            child: MusicFlowSurface(
              level: MusicFlowSurfaceLevel.modal,
              color: scopedColors.surface,
              borderRadius: borderRadius,
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                child: Column(
                  children: <Widget>[
                    if (!panel) ...[
                      SizedBox(height: scopedSpacing.xs),
                      Center(
                        child: ExcludeSemantics(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scopedColors.divider,
                              borderRadius: scopedRadii.pill,
                            ),
                            child: const SizedBox(width: 36, height: 4),
                          ),
                        ),
                      ),
                    ],
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        scopedSpacing.md,
                        scopedSpacing.sm,
                        scopedSpacing.xs,
                        scopedSpacing.sm,
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
                                    style: scopedTypography.headline,
                                  ),
                                ),
                                SizedBox(height: scopedSpacing.xxs),
                                Text(
                                  '${queue.length} 首曲目',
                                  style: scopedTypography.metadata,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: scopedSpacing.sm),
                          MusicFlowIconButton(
                            icon: AppIcons.close,
                            label: '关闭播放队列',
                            onPressed: () {
                              if (onClose != null) {
                                onClose!();
                              } else {
                                Navigator.of(scopedContext).maybePop();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const MusicFlowDivider(),
                    Expanded(
                      child: queue.isEmpty
                          ? const MusicFlowEmptyState(
                              title: '队列为空',
                              description: '开始播放一首歌曲后，接下来的曲目会出现在这里。',
                              icon: AppIcons.queue,
                            )
                          : _AutoCenterQueueList(
                              queue: queue,
                              currentIndex: currentIndex,
                              onSelect: onSelect,
                              onOpenSongActions: onOpenSongActions,
                              // 手机端底部弹窗注入 DraggableScrollableSheet 控制器以支持拖拽调高；
                              // 桌面右侧面板不传，自建控制器并由组件负责释放。
                              scrollController:
                                  panel ? null : scrollController,
                            ),
                    ),
                    const MusicFlowDivider(),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        scopedSpacing.md,
                        scopedSpacing.xs,
                        scopedSpacing.md,
                        scopedSpacing.sm,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: MusicFlowButton.ghost(
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
        },
      );
    }

    final scope = MusicFlowMediaColorScope(
      visuals: visuals,
      role: MusicFlowMediaSurfaceRole.panel,
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
        ? BorderRadius.horizontal(left: context.musicFlowRadii.scene.topLeft)
        : BorderRadius.only(
            topLeft: context.musicFlowRadii.scene.topLeft,
            topRight: context.musicFlowRadii.scene.topRight,
          );

    return MusicFlowSurface(
      level: MusicFlowSurfaceLevel.modal,
      color: context.musicFlowColors.surface,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            if (!panel) ...[
              SizedBox(height: context.musicFlowSpacing.xs),
              Center(
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.musicFlowColors.divider,
                      borderRadius: context.musicFlowRadii.pill,
                    ),
                    child: const SizedBox(width: 36, height: 4),
                  ),
                ),
              ),
            ],
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                context.musicFlowSpacing.md,
                context.musicFlowSpacing.sm,
                context.musicFlowSpacing.xs,
                context.musicFlowSpacing.sm,
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
                            style: context.musicFlowTypography.headline,
                          ),
                        ),
                        SizedBox(height: context.musicFlowSpacing.xxs),
                        Text(
                          '${queue.length} 首曲目 · 正在投屏到「$deviceName」'
                          '${offline ? ' · 设备离线' : ''}',
                          style: context.musicFlowTypography.metadata,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.musicFlowSpacing.sm),
                  MusicFlowIconButton(
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
            const MusicFlowDivider(),
            Expanded(
              child: queue.isEmpty
                  ? const MusicFlowEmptyState(
                      title: '投屏队列为空',
                      description: '后端投屏队列暂无曲目,可在歌曲菜单中添加到投屏队列。',
                      icon: AppIcons.queue,
                    )
                  : _AutoCenterCastList(
                      queue: queue,
                      currentIndex: currentIndex,
                      onSelect: onSelect,
                      onRemove: onRemove,
                      onReorder: onReorder,
                    ),
            ),
            const MusicFlowDivider(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.musicFlowSpacing.md,
                context.musicFlowSpacing.xs,
                context.musicFlowSpacing.md,
                context.musicFlowSpacing.sm,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: MusicFlowButton.ghost(
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

/// 投屏/遥控队列列表:自动把「当前播放」滚动到视口中间(对齐上层 _AutoCenterQueueList)。
/// 复用同一套居中策略:行高不定,不依赖 itemExtent,目标行未构建时用
/// 比例法粗估(maxScrollExtent × index/last)+ 逐轮逼近,构建后
/// Scrollable.ensureVisible(alignment: 0.5) 精确居中。仍保持 ReorderableListView
/// 以支持拖拽排序。
class _AutoCenterCastList extends StatefulWidget {
  const _AutoCenterCastList({
    required this.queue,
    required this.currentIndex,
    required this.onSelect,
    required this.onRemove,
    required this.onReorder,
  });

  final List<Song> queue;
  final int currentIndex;
  final Future<void> Function(int index) onSelect;
  final void Function(int index) onRemove;
  final void Function(int from, int to) onReorder;

  @override
  State<_AutoCenterCastList> createState() => _AutoCenterCastListState();
}

class _AutoCenterCastListState extends State<_AutoCenterCastList> {
  final ScrollController _controller = ScrollController();
  final GlobalKey _currentKey = GlobalKey();

  // 比例法粗估的最多逼近轮数:目标行未实例化时逐轮向队列尾部推进。
  static const int _kMaxApproachRounds = 4;

  @override
  void initState() {
    super.initState();
    if (widget.queue.isNotEmpty && widget.currentIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnCurrent());
    }
  }

  @override
  void didUpdateWidget(_AutoCenterCastList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只响应「当前曲目下标」变化而居中;列表引用变化不触发,避免抖动。
    if (widget.currentIndex != oldWidget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnCurrent());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _centerOnCurrent() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _attemptCenter(round: 0);
    });
  }

  /// 把「当前播放行」滚动到视口中间(与 _AutoCenterQueueListState 同策略):
  /// 目标行未构建时用**比例法**粗估(maxScrollExtent × index/last),
  /// 避免固定行高在长队列下误差累积导致目标行永不实例化;未命中则逐轮
  /// 推进,命中后 Scrollable.ensureVisible(alignment: 0.5) 精确居中。
  void _attemptCenter({required int round}) {
    if (!mounted) return;
    final ctx = _currentKey.currentContext;
    if (ctx != null) {
      _revealCentered(ctx);
      return;
    }
    if (!_controller.hasClients || widget.queue.isEmpty) return;
    final last = widget.queue.length - 1;
    if (last <= 0) return;
    final index = widget.currentIndex.clamp(0, last).toInt();
    final maxExtent = _controller.position.maxScrollExtent;
    var ratio = index / last;
    if (round > 0) {
      // 上一轮未命中(行高不均致粗估偏小):向队列尾部增量推进,最多数轮。
      ratio = (ratio + 0.15 * round).clamp(0.0, 1.0);
    }
    _controller.jumpTo(maxExtent * ratio);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final refined = _currentKey.currentContext;
      if (refined != null) {
        _revealCentered(refined);
      } else if (round < _kMaxApproachRounds) {
        _attemptCenter(round: round + 1);
      }
    });
  }

  void _revealCentered(BuildContext target) {
    Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.currentIndex;
    return ReorderableListView.builder(
      scrollController: _controller,
      padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
      buildDefaultDragHandles: false,
      itemCount: widget.queue.length,
      onReorder: (from, to) {
        // onReorder 的 to 为移除后的净插入位(>from 时为原始坐标+1),
        // 与 reorderQueue 的约定一致,直接下发后端 reorder。
        if (from != to) widget.onReorder(from, to);
      },
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        elevation: 0,
        child: child,
      ),
      itemBuilder: (context, index) {
        final song = widget.queue[index];
        final isCurrent = index == current;
        final row = KeyedSubtree(
          key: ValueKey<String>('cast-queue-$index-${song.id}'),
          child: ReorderableDelayedDragStartListener(
            index: index,
            child: MusicFlowSongRow(
              index: index,
              song: song,
              variant: MusicFlowSongRowVariant.standard,
              isCurrent: isCurrent,
              contentPadding: EdgeInsetsDirectional.fromSTEB(
                context.musicFlowSpacing.md,
                context.musicFlowSpacing.xs,
                context.musicFlowSpacing.xs,
                context.musicFlowSpacing.xs,
              ),
              onPressed: () => unawaited(widget.onSelect(index)),
              onMorePressed: () => widget.onRemove(index),
              moreSemanticLabel: '${song.title}，从投屏队列移除',
              showMoreButton: false,
            ),
          ),
        );
        // 只在当前行挂 GlobalKey,供 ensureVisible 精确定位居中。
        return isCurrent ? KeyedSubtree(key: _currentKey, child: row) : row;
      },
    );
  }
}

/// 桌面右下侧队列列表:自动把「当前播放」滚动到视口中间(对齐网易云客户端)。
/// 行高不定(文本可换行),不依赖固定 itemExtent:目标行未构建时用比例法
/// 粗估(maxScrollExtent × index/last,不随 index 累积误差)+ 逐轮逼近,
/// 构建后 Scrollable.ensureVisible(alignment: 0.5) 精确居中;当前曲目变化后
/// 重新滚动到中间。
class _AutoCenterQueueList extends StatefulWidget {
  const _AutoCenterQueueList({
    required this.queue,
    required this.currentIndex,
    required this.onSelect,
    required this.onOpenSongActions,
    this.scrollController,
  });

  final List<Song> queue;
  final int currentIndex;
  final Future<void> Function(int index) onSelect;
  final QueueSongAction onOpenSongActions;

  /// 外部注入的 ScrollController（底部弹窗 DraggableScrollableSheet 的控制器，
  /// 用于支持拖拽调高度）；桌面右侧面板不传则自建内部控制器并负责释放
  final ScrollController? scrollController;

  @override
  State<_AutoCenterQueueList> createState() => _AutoCenterQueueListState();
}

class _AutoCenterQueueListState extends State<_AutoCenterQueueList> {
  // 外部注入时复用外部控制器(底部弹窗拖拽调高需要);自建时才负责 dispose。
  late final bool _ownsController = widget.scrollController == null;
  late final ScrollController _controller =
      widget.scrollController ?? ScrollController();
  final GlobalKey _currentKey = GlobalKey();

  // 比例法粗估的最多逼近轮数:目标行未实例化时逐轮向队列尾部推进。
  static const int _kMaxApproachRounds = 4;

  @override
  void initState() {
    super.initState();
    if (widget.queue.isNotEmpty && widget.currentIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnCurrent());
    }
  }

  @override
  void didUpdateWidget(_AutoCenterQueueList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只响应「当前选中曲目下标」变化而居中(点选未在播的曲目也会切换下标,
    // 故无论是否在播都居中对齐;列表引用变化不触发,避免抖动)。
    if (widget.currentIndex != oldWidget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnCurrent());
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _centerOnCurrent() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _attemptCenter(round: 0);
    });
  }

  /// 把「当前播放行」滚动到视口中间。
  ///
  /// 目标行尚未构建时(ListView 懒加载)先用**比例法**粗估偏移——
  /// 按当前行在队列中的位置比例乘以 maxScrollExtent,而非固定行高:
  /// 固定行高在长队列(如随机模式 100+ 首)下误差随 index 线性累积,
  /// 粗估位置偏出可视区后目标行始终不实例化,居中彻底失效。
  /// 比例法误差仅来自行高不均,且每轮按比例推进兜底,直到目标行被构建,
  /// 再由 Scrollable.ensureVisible(alignment: 0.5) 精确定位居中。
  void _attemptCenter({required int round}) {
    if (!mounted) return;
    final ctx = _currentKey.currentContext;
    if (ctx != null) {
      _revealCentered(ctx);
      return;
    }
    if (!_controller.hasClients || widget.queue.isEmpty) return;
    final last = widget.queue.length - 1;
    if (last <= 0) return;
    final index = widget.currentIndex.clamp(0, last).toInt();
    final maxExtent = _controller.position.maxScrollExtent;
    var ratio = index / last;
    if (round > 0) {
      // 上一轮未命中(行高不均致粗估偏小):向队列尾部增量推进,最多数轮。
      ratio = (ratio + 0.15 * round).clamp(0.0, 1.0);
    }
    _controller.jumpTo(maxExtent * ratio);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final refined = _currentKey.currentContext;
      if (refined != null) {
        _revealCentered(refined);
      } else if (round < _kMaxApproachRounds) {
        _attemptCenter(round: round + 1);
      }
    });
  }

  void _revealCentered(BuildContext target) {
    Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.currentIndex;
    return ListView.separated(
      controller: _controller,
      padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
      itemCount: widget.queue.length,
      separatorBuilder: (context, index) =>
          SizedBox(height: context.musicFlowSpacing.xxs),
      itemBuilder: (context, i) {
        final song = widget.queue[i];
        final isCurrent = i == current;
        final row = MusicFlowSongRow(
          index: i,
          song: song,
          variant: MusicFlowSongRowVariant.standard,
          isCurrent: isCurrent,
          contentPadding: EdgeInsetsDirectional.fromSTEB(
            context.musicFlowSpacing.md,
            context.musicFlowSpacing.xs,
            context.musicFlowSpacing.xs,
            context.musicFlowSpacing.xs,
          ),
          onPressed: () => unawaited(widget.onSelect(i)),
          onLongPress: () => unawaited(
            widget.onOpenSongActions(context, i, song),
          ),
          onMorePressed: () => unawaited(
            widget.onOpenSongActions(context, i, song),
          ),
          moreSemanticLabel: '${song.title}，更多操作',
          showMoreButton: false,
        );
        // 只在当前行挂 GlobalKey,供 ensureVisible 精确定位居中。
        return isCurrent ? KeyedSubtree(key: _currentKey, child: row) : row;
      },
    );
  }
}
