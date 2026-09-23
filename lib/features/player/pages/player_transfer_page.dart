import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/player/widgets/player_backdrop.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

/// 圆形直径与行/列间距 —— 这是**专用页面**，不挤在 mini 条上方，所以给足尺寸。
const double _kRingSize = 78;
const double _kRingGap = 24;

/// 单个格子的最小宽度（圆 78 + 间距 12 + 文案至少 ~150）。
/// 网格按「可用宽度 ÷ 此值」自动算列数：宽窗口多列、窄窗口少列、
/// 手机竖屏 1 列 —— 一行排满才换行，格子恒等宽对齐。
const double _kCellMinWidth = 240;

/// 单个格子的宽度上限：玩家少时不把格子拉满整行，整组水平居中。
const double _kCellMaxWidth = 320;

/// 「流转播放队列」专用页面。
///
/// 一个圆 = 一个播放端：圆内是该端**此刻在播**的封面（没在播则显示设备图标），
/// 下方是**完整名称**（页面空间充足，不压缩成短名）。**本机占第一个圆。**
///
/// 交互有两个，各管各的：
/// - **单击** = 切换遥控目标（与 mini 播放器右下角「流转播放」小弹窗里点某行
///   完全同义）：走 `switchTo` / `backToLocal`，不推队列不投屏，客户端此后就是
///   那个播放端的遥控器；切换成功弹 Toast 并自动关页。当前正在遥控的圆带
///   动态高亮（呼吸光环）。
/// - **拖拽**：按住任意一个圆拖到另一个圆 —— 拖动方向就是「源 → 目标」，
///   把源的队列流转给目标。**流转完成后控制目标自动跟到目的地**
///   （A→B 后自动遥控 B；回到本机则切回本机并续播）。
///
/// ⚠️ 拖拽 feedback 会被插进**根 Overlay**，那里只给【无界(loose)约束】——
/// feedback 子树里不能出现依赖紧约束/无限宽的布局（Expanded/Spacer/Unbounded
/// Row 等），必须用 `SizedBox(width: cellWidth)` 先给出有界宽度
/// （player_switcher.dart 的 Overlay 注释是同一个坑，2026-09-16 拖动卡死实锤）。
///
/// 视觉：整页沿用大屏播放页那套「封面取色」体系（MusicFlowMediaColorScope +
/// MusicFlowPlayerBackdrop），不是一块白板；文字/图标色由 scope 重映射，
/// 深浅封面下都保证对比度。点空白处即可关闭（不放关闭按钮）。
class PlayerTransferPage extends ConsumerStatefulWidget {
  const PlayerTransferPage({super.key, required this.onTransfer});

  /// 执行流转：从 [from] 搬到 [to]；返回是否成功。
  final Future<bool> Function(PeerInfo from, PeerInfo to) onTransfer;

  /// 从任意入口打开本页面。
  static Future<void> open(
    BuildContext context, {
    required Future<bool> Function(PeerInfo from, PeerInfo to) onTransfer,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => PlayerTransferPage(onTransfer: onTransfer),
      ),
    );
  }

  @override
  ConsumerState<PlayerTransferPage> createState() => _PlayerTransferPageState();
}

class _PlayerTransferPageState extends ConsumerState<PlayerTransferPage> {
  /// null = 还在拉取。用普通 State 而不是 FutureProvider：
  /// 与已验证可用的「流转播放」弹窗（player_switcher）走同一套 loadPeers 调用方式，
  /// 避免 provider 依赖链上的加载态卡死（实测过：用 FutureProvider 时页面一直转圈）。
  List<PeerInfo>? _peers;
  bool _busy = false;

  /// 被选中的群组(点群组圆 → 选中,再点取消):选中后每个设备圆下方出现
  /// +/− 按钮(组内 − / 组外 +),点击即加入/退出该组。
  String? _selectedGroupId;
  String? _selectedGroupName;
  Set<String> _selectedMembers = const <String>{};
  bool _groupBusy = false;

  @override
  void initState() {
    super.initState();
    // **必须等首帧之后再拉**：loadPeers() 内部会写 castPeerController 的 state
    // (loadingPeers 标记)，而在 initState 这种 widget 生命周期里改 provider 会被
    // Riverpod 拒绝并抛「Tried to modify a provider while the widget tree was building」，
    // 整个页面直接崩掉 —— 表现就是一直转圈、一个圆都不出现。
    // player_switcher(流转播放弹窗)同样用 postFrameCallback，这里保持一致。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  /// 拉取可流转的播放端：本机排第一，其余为**在线**、非 Web 的端。
  ///
  /// 过滤口径与「流转播放」一致：离线端不展示（避免拖到一台已下线的端上才失败）；
  /// Web 端不出声，本就不是流转目标。
  Future<void> _load() async {
    final controller = ref.read(castPeerControllerProvider.notifier);
    final all = await controller.loadPeers();
    if (!mounted) return;
    PeerInfo? self;
    final others = <PeerInfo>[];
    for (final p in all) {
      if (p.isLocal && p.self) {
        self = p;
        continue;
      }
      if (p.available && p.platform != 'web') others.add(p);
    }
    others.sort(_peerDisplayCompare);
    setState(() => _peers = <PeerInfo>[if (self != null) self, ...others]);
  }

  /// 播放端展示序:**正在播的排前面**;同为在播/同为闲置时按
  /// **客户端本机 > 群组 > 独立播放器**排(用户定稿 2026-09-23)。
  ///
  /// 「正在播」取服务端 `queue.isActive`(PeerInfo.queueActive),不再额外请求;
  /// 群组排在独立播放器之前 —— 多台设备一起响时,组是更上层的控制目标。
  static int _peerDisplayCompare(PeerInfo a, PeerInfo b) {
    final pa = a.queueActive ? 0 : 1;
    final pb = b.queueActive ? 0 : 1;
    if (pa != pb) return pa - pb;
    final ka = _peerKindRank(a);
    final kb = _peerKindRank(b);
    if (ka != kb) return ka - kb;
    return a.name.compareTo(b.name);
  }

  /// 类别权重:客户端本机(含同账号其它端)0 < 群组 1 < 独立播放器 2。
  static int _peerKindRank(PeerInfo p) {
    if (p.isLocal) return 0;
    if (p.kind == 'group') return 1;
    return 2;
  }

  Future<void> _handleDrop(PeerInfo from, PeerInfo to) async {
    if (_busy || from.peerId == to.peerId) return;
    setState(() => _busy = true);
    final ok = await widget.onTransfer(from, to);
    if (!mounted) return;
    if (ok) {
      // 流转到哪，遥控就跟到哪：控制目标自动切到目的地。
      // 目的地是本机 → backToLocal(续播快照)；是远端 → switchTo(纯切目标)。
      final controller = ref.read(castPeerControllerProvider.notifier);
      if (to.isLocal && to.self) {
        await controller.backToLocal(resumeLocal: true);
      } else {
        await controller.switchTo(to);
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // 流转完成即关页：这是一次性动作，停在这里只会让人以为还要再点一下。
    if (ok) Navigator.of(context).maybePop();
  }

  /// 单击圆 = 切换遥控目标，语义与「流转播放」小弹窗里点某一行完全一致：
  /// - 点远端 → `switchTo(peer)`（纯 UI 控制目标切换，不推队列/不投屏）；
  /// - 点本机且正在遥控远端 → `backToLocal(resumeLocal: true)`（切回本机并续播快照）;
  /// - 点的就是当前遥控目标 → 无操作，仅关页。
  /// 成功弹 Toast 并自动关页；失败弹错误提示并留在页面。
  Future<void> _handleTap(PeerInfo peer, bool isSelf) async {
    if (_busy) return;
    // 点群组 = 选中/取消选中(加减成员模式),不走切遥控;
    // 遥控组的入口仍在「流转播放」小弹窗(点行即遥控)。
    if (peer.kind == 'group') {
      await _toggleGroupSelection(peer);
      return;
    }
    final controller = ref.read(castPeerControllerProvider.notifier);
    final cast = ref.read(castPeerControllerProvider);
    final loc = AppLocalizations.of(context);
    final isCurrentTarget = isSelf
        ? cast.activePeer == null
        : cast.activePeer?.peerId == peer.peerId;
    if (isCurrentTarget) {
      // 已经在遥控它了：无事发生，关页即可。
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _busy = true);
    if (isSelf) {
      await controller.backToLocal(resumeLocal: true);
      if (!mounted) return;
      setState(() => _busy = false);
      showMusicFlowMessage(
        context,
        loc.player_switched_local,
        kind: MusicFlowMessageKind.success,
      );
      Navigator.of(context).maybePop();
      return;
    }
    final ok = await controller.switchTo(peer);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showMusicFlowMessage(
        context,
        loc.player_remote_control(peer.name),
        kind: MusicFlowMessageKind.success,
      );
      Navigator.of(context).maybePop();
    } else {
      showMusicFlowMessage(
        context,
        loc.player_cast_failed(peer.name),
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  /// 选中/取消选中一个群组。选中时拉取该组成员列表,供勾选圈判定「组内/组外」。
  ///
  /// 选中同时把**遥控目标切到该群组**(MINI 播放器栏跟着变成群组),与 Web 流转
  /// 列表一致;退出管理模式(再点一次 / 点空白关闭本页)后仍保持遥控该群组 ——
  /// 用户定稿:「点击空白区域仍然是遥控群组」。
  Future<void> _toggleGroupSelection(PeerInfo group) async {
    if (_groupBusy) return;
    if (_selectedGroupId == group.peerId) {
      setState(() {
        _selectedGroupId = null;
        _selectedGroupName = null;
        _selectedMembers = const <String>{};
      });
      return;
    }
    // 先切遥控(静默:不弹 toast、不关页 —— 还要留在本页勾选成员)。
    final castNow = ref.read(castPeerControllerProvider);
    if (castNow.activePeer?.peerId != group.peerId) {
      await ref.read(castPeerControllerProvider.notifier).switchTo(group);
      if (!mounted) return;
    }
    final gid = group.peerId.startsWith('group:')
        ? group.peerId.substring('group:'.length)
        : group.peerId;
    setState(() => _groupBusy = true);
    final groups = await ref
        .read(castPeerControllerProvider.notifier)
        .fetchGroups();
    if (!mounted) return;
    setState(() => _groupBusy = false);
    Map<String, dynamic>? hit;
    for (final g in groups ?? const <dynamic>[]) {
      if (g is Map<String, dynamic> &&
          (g['id']?.toString() ?? '') == gid) {
        hit = g;
        break;
      }
    }
    final loc = AppLocalizations.of(context);
    if (hit == null) {
      showMusicFlowMessage(
        context,
        loc.player_group_op_failed,
        kind: MusicFlowMessageKind.error,
      );
      return;
    }
    final ids = (hit['memberIds'] as List?)
            ?.map((e) => e.toString())
            .toSet() ??
        const <String>{};
    final hitName = hit['name']?.toString() ?? group.name;
    if (!mounted) return;
    setState(() {
      _selectedGroupId = group.peerId;
      _selectedGroupName = hitName;
      _selectedMembers = ids;
    });
  }

  /// 服务端成员命名空间写法:sendspin = `sendspin:<clientId>`(与 peerId 同形);
  /// DLNA = 裸设备 id(历史数据约定,去掉 peerId 的 `dlna:` 前缀)。
  String _memberKeyFor(PeerInfo p) =>
      p.kind == 'sendspin'
          ? p.peerId
          : p.peerId.replaceFirst(RegExp('^dlna:'), '');

  bool _isMember(PeerInfo p) =>
      _selectedMembers.contains(_memberKeyFor(p)) ||
      _selectedMembers.contains(p.peerId);

  /// 点 +/−:加入/退出选中的群组。成功用返回的 memberIds 就地刷新,失败提示并保留原状。
  Future<void> _toggleMembership(PeerInfo peer) async {
    if (_groupBusy || _selectedGroupId == null) return;
    final gid = _selectedGroupId!.startsWith('group:')
        ? _selectedGroupId!.substring('group:'.length)
        : _selectedGroupId!;
    final join = !_isMember(peer);
    setState(() => _groupBusy = true);
    final ids = await ref
        .read(castPeerControllerProvider.notifier)
        .setGroupMembership(gid, _memberKeyFor(peer), join: join);
    if (!mounted) return;
    setState(() => _groupBusy = false);
    final loc = AppLocalizations.of(context);
    if (ids == null) {
      showMusicFlowMessage(
        context,
        loc.player_group_op_failed,
        kind: MusicFlowMessageKind.error,
      );
      return;
    }
    setState(() => _selectedMembers = ids.toSet());
    showMusicFlowMessage(
      context,
      join
          ? loc.player_group_joined(_selectedGroupName ?? '')
          : loc.player_group_left(_selectedGroupName ?? ''),
      kind: MusicFlowMessageKind.success,
    );
  }

  /// 回收站落点：销毁播放端（停止 + 清空其队列；本机 = 内存会话一并抛弃）。
  /// 成功弹 Toast **不关页**（可继续销毁别的播放器）；失败弹错也留页。
  Future<void> _handleDestroy(PeerInfo peer) async {
    if (_busy) return;
    setState(() => _busy = true);
    final controller = ref.read(castPeerControllerProvider.notifier);
    final loc = AppLocalizations.of(context);
    final ok = await controller.destroyPeer(peer);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!(peer.isLocal && peer.self)) {
      ref.invalidate(peerNowPlayingProvider(peer.peerId));
    }
    showMusicFlowMessage(
      context,
      ok
          ? loc.player_destroy_success(peer.name)
          : loc.player_destroy_failed(peer.name),
      kind: ok ? MusicFlowMessageKind.success : MusicFlowMessageKind.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // 与大屏播放页同一套封面取色（深浅封面自适应）。
    final visuals = ref.watch(resolvedCurrentSongMediaVisualsProvider);
    final peers = _peers;
    // 当前遥控目标（对齐小弹窗的 selected 判据）：null = 正在控制本机，
    // 此时第一个圆（本机）带动态高亮；非空 = 对应圆带高亮。
    final activePeerId = ref.watch(
      castPeerControllerProvider.select((s) => s.activePeer?.peerId),
    );

    return MusicFlowMediaColorScope(
      visuals: visuals,
      role: MusicFlowMediaSurfaceRole.stage,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: MusicFlowPlayerBackdrop(
                visuals: visuals,
                mode: MusicFlowPlayerBackdropMode.stage,
              ),
            ),
            // 点空白即关（不放关闭按钮）。
            // 注意：这里必须包在**内容层外面** —— Scrollable 内部是
            // HitTestBehavior.opaque，会把指针事件吃掉，放在 Stack 下层的那层
            // "空白点击层"根本不在 hit test 链里，几乎触发不到（实测如此）。
            // 作为 Scrollable 的祖先才在链里：点圆 → 圆自己的 GestureDetector 吸收；
            // 点其余任何地方（圆之间的空隙、标题、上下留白）→ 落到这里关闭。
            SafeArea(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Column(
                  children: <Widget>[
                    const SizedBox(height: 20),
                    Text(
                      loc.player_transfer_title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      loc.player_transfer_hint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_selectedGroupId != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, left: 24, right: 24),
                        child: Text(
                          loc.player_group_selected_hint(
                            _selectedGroupName ?? '',
                          ),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color:
                                    Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ),
                    Expanded(
                      child: switch (peers) {
                        null => const Center(
                          child: CircularProgressIndicator(),
                        ),
                        [] => Center(child: Text(loc.player_transfer_empty)),
                        final list => SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                          // 自适应网格：按可用宽度自动算列数，一行排满才换行；
                          // 单格宽度有上限（320），玩家少时不拉满整行 ——
                          // 整组水平居中，桌面宽窗口多列、手机 1 列。
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final columns = (constraints.maxWidth /
                                      (_kCellMinWidth + _kRingGap))
                                  .floor()
                                  .clamp(1, 99);
                              final cellWidth = math.min(
                                (constraints.maxWidth -
                                        (columns - 1) * _kRingGap) /
                                    columns,
                                _kCellMaxWidth,
                              );
                              return Column(
                                children: <Widget>[
                                  for (var i = 0; i < list.length; i += columns)
                                    Padding(
                                      padding: EdgeInsets.only(
                                        bottom: i + columns < list.length
                                            ? _kRingGap
                                            : 0,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: <Widget>[
                                          for (
                                            var j = i;
                                            j < i + columns && j < list.length;
                                            j++
                                          )
                                            SizedBox(
                                              width: cellWidth,
                                              child: _RingNode(
                                                peer: list[j],
                                                cellWidth: cellWidth,
                                                isSelf:
                                                    list[j].isLocal &&
                                                    list[j].self,
                                                isActive:
                                                    (list[j].isLocal &&
                                                        list[j].self)
                                                    ? activePeerId == null
                                                    : activePeerId ==
                                                          list[j].peerId,
                                                selectedGroup:
                                                    _selectedGroupId,
                                                isMemberOfSelected:
                                                    _isMember(list[j]),
                                                onToggleMembership:
                                                    _groupBusy
                                                    ? null
                                                    : () =>
                                                          _toggleMembership(
                                                            list[j],
                                                          ),
                                                onTap: () => _handleTap(
                                                  list[j],
                                                  list[j].isLocal &&
                                                      list[j].self,
                                                ),
                                                onDragStateChanged: (_) {},
                                                onDropFrom: _handleDrop,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      },
                    ),
                    // 底部回收站：拖任意播放器圆进来 = 停止该端并清空其队列。
                    // 放在滚动区外的页面底部，常驻可见；不参与滚动。
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 18),
                      child: _TrashZone(onDestroy: _handleDestroy),
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

/// 单个播放端圆：**单击 = 切换遥控目标**；既是拖拽源（按住它拖走 = 把它的
/// 队列给别人），也是落点（别的圆拖进来 = 把别人的队列给它）。
class _RingNode extends ConsumerWidget {
  const _RingNode({
    required this.peer,
    required this.cellWidth,
    required this.isSelf,
    required this.isActive,
    required this.onTap,
    required this.onDragStateChanged,
    required this.onDropFrom,
    this.selectedGroup,
    this.isMemberOfSelected = false,
    this.onToggleMembership,
  });

  final PeerInfo peer;

  /// 选中的群组 peerId(null = 没选中任何群组):非空且本圆是设备型成员时,
  /// 信息列下方显示 +/− 按钮(组内 − / 组外 +)。
  final String? selectedGroup;
  final bool isMemberOfSelected;
  final VoidCallback? onToggleMembership;

  /// 该格宽度：既作 feedback 的有界宽度（见类注释的 Overlay 坑），也保证
  /// 拖起来的影子与原格一样大。
  final double cellWidth;

  /// 本机那个圆（列表第一位）：封面取本地播放态，不走 /status 轮询。
  final bool isSelf;

  /// 当前遥控目标就是这个圆（对齐小弹窗 selected 判据）→ 呼吸光环高亮。
  final bool isActive;
  final VoidCallback onTap;
  final ValueChanged<PeerInfo?> onDragStateChanged;
  final Future<void> Function(PeerInfo from, PeerInfo to) onDropFrom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 吸收点击：在圆上按下不该被当成「点空白」而关页；onTap 交给
    // [_handleTap]（切遥控目标），拖拽交给 Draggable（流转队列）。
    // 落点仍是**整行**(拖到名称区也能接住,手势容错更大);拖拽源只包封面圆。
    return GestureDetector(
      onTap: onTap,
      child: DragTarget<PeerInfo>(
        onWillAcceptWithDetails: (details) =>
            details.data.peerId != peer.peerId,
        onAcceptWithDetails: (details) => onDropFrom(details.data, peer),
        builder: (context, candidates, rejected) {
          // 群组被选中:accent 常亮(与落点高亮同通道,但无拖拽候选也亮)。
          final groupSelected =
              peer.kind == 'group' && selectedGroup == peer.peerId;
          // 选中群组后,设备型成员(dlna/sendspin)信息列下方出现加入/退出勾选圈;
          // 本机/群组/airplay 不参与(服务端组成员只有 dlna/sendspin 命名空间)。
          Widget? action;
          if (selectedGroup != null &&
              peer.kind != 'group' &&
              (peer.kind == 'dlna' || peer.kind == 'sendspin')) {
            action = _MemberToggleButton(
              isMember: isMemberOfSelected,
              onTap: onToggleMembership,
            );
          }
          return _RingBubble(
            peer: peer,
            isSelf: isSelf,
            isActive: isActive,
            highlighted: candidates.isNotEmpty || groupSelected,
            actionBelow: action,
            // 只有封面圆可拖起:从播放器名/歌名位置按下不会起拖,只响应点击。
            circleWrapper: (circle) => Draggable<PeerInfo>(
              data: peer,
              onDragStarted: () => onDragStateChanged(peer),
              onDragEnd: (_) => onDragStateChanged(null),
              onDraggableCanceled: (_, _) => onDragStateChanged(null),
              // feedback 被插进根 Overlay,那里只给【无界约束】—— 必须先用
              // SizedBox 给出有界宽度,否则内部 Row+Expanded 布局崩掉
              //(size: MISSING → hit test 连环异常 → 拖动时整个画面卡死)。
              feedback: SizedBox(
                width: cellWidth,
                child: Material(
                  color: Colors.transparent,
                  child: _RingBubble(peer: peer, isSelf: isSelf, lifted: true),
                ),
              ),
              // 拖起后只剩封面圆变淡,右侧名称/歌名保持可读。
              childWhenDragging: Opacity(opacity: 0.25, child: circle),
              child: circle,
            ),
          );
        },
      ),
    );
  }
}

/// 圆的视觉：圆内是当前曲封面，无封面时落回设备图标；**右侧信息列**上行是
/// 播放端完整名，下行是该端此刻在播的「歌名 - 歌手」。当前遥控目标的圆
/// 带**动态高亮**（accent 描边 + 呼吸光环）。
class _RingBubble extends ConsumerWidget {
  const _RingBubble({
    required this.peer,
    this.isSelf = false,
    this.isActive = false,
    this.highlighted = false,
    this.lifted = false,
    this.actionBelow,
    this.circleWrapper,
  });

  final PeerInfo peer;

  /// 选中群组后显示在信息列下方的加入/退出勾选圈(null = 不显示)。
  final Widget? actionBelow;

  /// 只包住**封面圆**的外壳(拖拽源)。拖拽只能从封面起拖 —— 播放器名 / 歌名
  /// 位置按下不起拖(避免误触把队列拖走),但那两处仍可点(切遥控 / 选组)。
  final Widget Function(Widget circle)? circleWrapper;

  /// 本机圆：封面直接取本地播放态（零延迟），不依赖服务端镜像。
  final bool isSelf;

  /// 当前遥控目标：accent 常亮描边 + 外圈呼吸光环（_ActivePulse）。
  final bool isActive;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.musicFlowColors;
    final String? cover;
    final bool playing;
    // 圆右侧的「正在播」文案：「歌名 - 歌手」。本机取本地播放态，
    // 远端取 PeerNowPlaying.trackLabel；没在播则留空。
    final String trackLabel;
    if (isSelf) {
      // 本机就是这个 App 自己 —— 本地播放态就是权威，省一次请求也零延迟。
      // ⚠️ 但「正在遥控远端」（activePeer != null）时例外：此时本地队列已被
      // 替换成**远端镜像**（客户端是遥控器的设计），不代表本机播放端在播 ——
      // 直接读会把被控端的歌错当成「本机在播」（2026-09-19 用户实测实锤）。
      // 与 PeerCastRow.canPush 同一口径：投屏态下本机队列没有「现场」，
      // 本机圆按空闲显示（设备图标 + 不带曲目文案）。
      final castingRemote = ref.watch(
        castPeerControllerProvider.select((s) => s.activePeer != null),
      );
      if (castingRemote) {
        cover = null;
        playing = false;
        trackLabel = '';
      } else {
        cover = ref.watch(
          playerProvider.select((s) => s.currentSong?.artworkReference),
        );
        playing = ref.watch(playerProvider.select((s) => s.isPlaying));
        final song = ref.watch(playerProvider.select((s) => s.currentSong));
        final title = song?.title ?? '';
        final artist = song?.artist ?? '';
        trackLabel = title.isEmpty
            ? ''
            : artist.isEmpty
            ? title
            : '$title - $artist';
      }
    } else {
      final nowPlaying = ref
          .watch(peerNowPlayingProvider(peer.peerId))
          .valueOrNull;
      playing = nowPlaying?.isActive == true;
      cover = playing ? nowPlaying?.coverArt : null;
      trackLabel = playing ? (nowPlaying?.trackLabel ?? '') : '';
    }

    // 群组用**虚线圆**与单机播放器(实线圆)一眼区分:虚线 = 「容器 / 多台设备
    // 的集合」,实线 = 一台真实设备。描边颜色/粗细口径两者完全一致。
    final bool isGroup = peer.kind == 'group';
    final Color ringColor = highlighted
        ? scheme.primary
        : isActive
        ? colors.accent
        : colors.ink.withValues(alpha: 0.28);
    final double ringWidth = (highlighted || isActive) ? 3 : 1;

    final Widget circle = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: _kRingSize,
      height: _kRingSize,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // 取色体系里的 raised 面：深浅封面下都不会变成一块突兀的白。
        color: colors.raised,
      ),
      // 描边必须走 foregroundDecoration（画在子节点**之上**），不能放进
      // decoration.border —— 后者会被 Container 当作内边距把子节点内缩：
      // 封面被挤小一圈、圆边露出 raised 底色，看起来就是「封面是正方形、
      // 没放大铺满圆」的缺口（高亮态 3px 比常态 1px 更明显）。
      // 前景描边不参与布局，封面得以铺满整个圆，描边只是覆在其上的一圈。
      // 群组的描边交给下面的虚线环 CustomPaint(它要画在封面之上,
      // 且 foregroundDecoration 画不出虚线),故此处置空。
      foregroundDecoration: isGroup
          ? null
          : BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                // 落点高亮：拖到哪个圆上哪个圆亮起来 —— 「会落到谁那儿」一眼可见。
                // 遥控目标高亮：accent 常亮描边，与落点高亮(primary)区分开。
                color: ringColor,
                width: ringWidth,
              ),
            ),
      child: (playing && cover != null && cover.isNotEmpty)
          ? CoverArtImage(
              coverArtId: cover,
              size: _kRingSize,
              requestSize: 240,
              // 显式 cover：封面铺满整个圆，不做任何 letterbox 留白。
              fit: BoxFit.cover,
              semanticLabel: peer.name,
            )
          : _DeviceIcon(peer: peer, dimmed: !playing),
    );

    // 群组:在封面/图标之上叠一圈**虚线圆**(虚线 = 容器,与设备实线圆区分)。
    final Widget dashedOrNot = isGroup
        ? SizedBox(
            width: _kRingSize,
            height: _kRingSize,
            child: Stack(
              children: <Widget>[
                circle,
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _DashedRingPainter(
                        color: ringColor,
                        strokeWidth: ringWidth,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        : circle;

    final circleOnly = isActive ? _ActivePulse(child: dashedOrNot) : dashedOrNot;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        // 拖拽源只包封面圆(见 circleWrapper 注释):从名称/歌名位置不起拖。
        circleWrapper != null ? circleWrapper!(circleOnly) : circleOnly,
        const SizedBox(width: 12),
        // 右侧信息列：第一行播放器名（完整名，极端长名兜底两行），
        // 第二行该端此刻在播的「歌名 - 歌手」；没在播留空。
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                peer.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: lifted || highlighted
                      ? scheme.primary
                      : isActive
                      ? colors.accent
                      : colors.ink,
                ),
              ),
              if (trackLabel.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  trackLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.ink.withValues(alpha: 0.72),
                  ),
                ),
              ],
              // 选中群组后的 +/− 按钮:放在名称/曲目下方(设计图:「独立播放器
              // 底下出现 +/- 符号的按钮」)。
              if (actionBelow != null) ...<Widget>[
                const SizedBox(height: 6),
                actionBelow!,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 群组圆的**虚线圆环**：沿圆周等分画短弧，间隔留空。
/// 语义：虚线 = 容器(多台设备的集合)，实线 = 一台真实设备 —— 圆圈形状本身
/// 就能区分「这是组还是单机」，不依赖文字标签。
class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter({
    required this.color,
    required this.strokeWidth,
  });

  final Color color;
  final double strokeWidth;

  /// 一圈分成多少段(越少段 = 虚线感越强;20 段在 78px 圆上疏密适中)。
  static const int dashCount = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final radius = (size.width - strokeWidth) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final step = math.pi * 2 / dashCount;
    // 每段画 60%、空 40% —— 明显成虚线但不出「断点过密」的噪点感。
    const sweepRatio = 0.6;
    for (int i = 0; i < dashCount; i++) {
      canvas.drawArc(rect, i * step, step * sweepRatio, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRingPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}

/// 遥控目标的「呼吸光环」：外圈 accent 圆环周期性放大 + 渐隐 + 辉光，
/// 提示「客户端此刻遥控的是这一个」。幅度给足（scale 1.26、透明度 0.85 起），
/// 保证在封面色一块儿也能一眼看出「哪个圆在呼吸」。
class _ActivePulse extends StatefulWidget {
  const _ActivePulse({required this.child});

  final Widget child;

  @override
  State<_ActivePulse> createState() => _ActivePulseState();
}

class _ActivePulseState extends State<_ActivePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: <Widget>[
            // 光环：scale 从 1.0 呼吸到 1.26，透明度随之渐隐并带辉光，
            // 视觉上向外「吐」，远处也能看到在动。
            Transform.scale(
              scale: 1.0 + 0.26 * t,
              child: Container(
                width: _kRingSize,
                height: _kRingSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.85 * (1 - t)),
                    width: 4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors.accent.withValues(alpha: 0.35 * (1 - t)),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
            child!,
          ],
        );
      },
    );
  }
}

/// 加减成员小按钮:选中群组后出现在设备圆的信息列下方。
/// 组内显示 −(点击退出),组外显示 +(点击加入);30px 圆形,不挤占圆本体。
/// 加入/退出群组的**可勾选小圆圈**(与 Web 流转列表行尾同一套视觉):
/// 未加入 = 空心圈(边框 + 透明底);已加入 = accent 实心圈 + 白色 ✓。
/// 不再用 +/− —— 勾选态比「加减」更贴近「在不在组里」的是/否语义。
class _MemberToggleButton extends StatelessWidget {
  const _MemberToggleButton({required this.isMember, required this.onTap});

  final bool isMember;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      // 触控热区放到 30px,视觉圈仍是 20px(Web 同款尺寸)。
      child: SizedBox(
        width: 30,
        height: 30,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isMember
                  ? scheme.primary
                  : colors.ink.withValues(alpha: 0.02),
              border: Border.all(
                color: isMember
                    ? scheme.primary
                    : colors.ink.withValues(alpha: 0.45),
                width: 1.5,
              ),
            ),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: isMember ? 1 : 0,
              child: Icon(
                Icons.check,
                size: 13,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部「回收站」：拖任意播放器圆（含本机）进来 = 停止该端并清空其队列。
/// 悬停时红色高亮 + 放大（销毁语义用红色系，与流转落点的 primary 高亮区分）。
/// 圆面 96px **大于播放器圆（78px）** —— 落点要比被拖物大，交互才合理。
class _TrashZone extends StatelessWidget {
  const _TrashZone({required this.onDestroy});

  final Future<void> Function(PeerInfo peer) onDestroy;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final loc = AppLocalizations.of(context);
    return DragTarget<PeerInfo>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onDestroy(details.data),
      builder: (context, candidates, rejected) {
        final hot = candidates.isNotEmpty;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedScale(
              scale: hot ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hot
                      ? colors.error.withValues(alpha: 0.18)
                      : colors.ink.withValues(alpha: 0.08),
                  border: Border.all(
                    color: hot
                        ? colors.error
                        : colors.ink.withValues(alpha: 0.28),
                    width: hot ? 2.5 : 1,
                  ),
                ),
                child: Icon(
                  Icons.delete_outline,
                  size: 42,
                  color: hot ? colors.error : colors.muted,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              loc.player_destroy_zone,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: hot ? colors.error : colors.muted,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 没在播（或曲目无封面）时的设备图标：按 kind + platform 区分。
class _DeviceIcon extends StatelessWidget {
  const _DeviceIcon({required this.peer, this.dimmed = false});

  final PeerInfo peer;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return Center(
      child: Icon(
        _iconFor(peer),
        size: 30,
        color: dimmed ? colors.muted : colors.ink,
      ),
    );
  }

  IconData _iconFor(PeerInfo p) {
    if (p.kind == 'group') return Icons.speaker_group_outlined;
    if (p.kind == 'airplay') return Icons.airplay;
    if (p.kind == 'sendspin') return Icons.graphic_eq;
    if (p.kind == 'local') {
      return switch ((p.platform ?? '').toLowerCase()) {
        'android' || 'ios' => Icons.smartphone,
        'windows' || 'macos' || 'linux' => Icons.desktop_windows_outlined,
        _ => Icons.devices_other,
      };
    }
    return Icons.speaker_outlined; // dlna 及其它渲染器
  }
}
