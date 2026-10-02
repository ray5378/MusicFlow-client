import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/features/player/peer_display_order.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

/// 面板互斥:**单一枚举**。
///
/// 为什么不用两个 bool:`showQueue` / `showVolume` 会出现「两个都 true」的
/// 脏态(L1 同时挂两个覆盖面板)。枚举在类型上就排除了这种状态。
/// autoDispose:块被用户隐藏 → provider 释放 → 状态不残留。
enum RemoteControlPanelKind { none, volume }

/// 告警分级(对应缺口 G-4:v1 只做两级,中间态「连接恢复中」不实现,
/// 因为客户端只有二元的 isOfflineProvider,不 new 信号源)。
enum RemoteControlAlert { none, offline, unreachable }

final remoteControlPanelProvider =
    StateProvider.autoDispose<RemoteControlPanelKind>(
  (ref) => RemoteControlPanelKind.none,
);

/// peers 薄壳:现有 `loadPeers()` 的返回值目前只存在于 `PlayerSwitcherSheet`
/// 的局部 state 里(缺口 G-2),这里只包一层 provider,不改写
/// cast_peer_provider。
///
/// **必须 autoDispose**:块被隐藏时不被 watch → provider 释放 → 天然零请求
/// (R22「隐藏分区 = 零请求」这条才成立)。
final remoteControlPeersProvider =
    FutureProvider.autoDispose<List<PeerInfo>>((ref) async {
  final notifier = ref.watch(castPeerControllerProvider.notifier);
  // 连接就绪自动刷新:冷启动时本 provider 可能先于「地址探测完成/凭证注入」
  // 跑第一遍,loadPeers 空手而归后若无重试信号,切换器会一直空到用户手动刷新。
  // watch 活跃地址 status(探测完成置 ok)与凭证就绪信号(活跃库发射时该
  // provider 重建、Future 换新),二者任一落定 → 本 autoDispose provider 重建
  // → 自动重跑 loadPeers()。套路对齐 cover_art_image 的就绪兜底(30da0e7 回归);
  // 禁止 Timer 轮询;手动刷新按钮(invalidate 本 provider)保留。
  ref.watch(activeAddressProvider.select((a) => a?.status));
  ref.watch(apiCredentialsReadyProvider);
  // ⚠️ `loadPeers()` 内部会**同步写** CastPeerState(offline/peers 等)。若在
  // provider 的 build 阶段直接调用,riverpod 会抛「Providers are not allowed
  // to modify other providers during their initialization」断言(实测挂掉
  // 整个 discover 页测试组)。用 `Future(() {})` 把它挪到微任务 —— 本次
  // build 落定之后才触发状态写入;不用 `Future.delayed`,避免在测试环境
  // 引入真 Timer。
  await Future<void>(() {});
  return notifier.loadPeers();
});

/// 切换器候选项:`available` 参与(离线不参与选择,对齐 HA 的
/// `available !== false`),但 **self 条目例外**(unavailable 也保留,否则
/// Windows 等场景服务端不返回 self 行或 available=false 时「本机」chip 消失,
/// 用户从此无法控制本机 —— 旧切换器的口径是「remote 列表排除 self + 本机行
/// 由 UI 恒定保证」,从不出现该问题);**本机由 `p.self` 识别**(不能用
/// `kind=='local'` 一刀切);排序复用 `peer_display_order.dart` 的唯一实现,
/// 不内联副本;列表完全没有 self 条目时兜底合成一条(local-self)。
final remoteControlTargetsProvider = Provider.autoDispose<List<PeerInfo>>(
  (ref) {
    final peers = ref.watch(remoteControlPeersProvider).valueOrNull;
    if (peers == null) return const <PeerInfo>[];
    final targets = peers.where((p) => p.available || p.self).toList()
      ..sort(comparePeerDisplayOrder);
    // 二层兜底:过滤后完全没有 self 条目 → 合成一条「本机」插到最前
    // (排序只作用于真实条目;合成条目按 self 语义跟随,插最前)。
    // _switchTarget 对 `peer.self` 走 backToLocal(),合成条目天然兼容;
    // chip 标签 `isSelf ? loc.peer_self : peer.name` 也天然显示「本机」。
    if (targets.any((p) => p.self)) return targets;
    return <PeerInfo>[
      const PeerInfo(
        peerId: 'local-self',
        name: '',
        kind: 'local',
        available: true,
        self: true,
      ),
      ...targets,
    ];
  },
);

/// 告警分级(纯派生,不 new 信号源)。
final remoteControlAlertProvider = Provider.autoDispose<RemoteControlAlert>(
  (ref) {
    if (ref.watch(isOfflineProvider)) return RemoteControlAlert.unreachable;
    if (ref.watch(castPeerControllerProvider.select((s) => s.offline))) {
      return RemoteControlAlert.offline;
    }
    return RemoteControlAlert.none;
  },
);
