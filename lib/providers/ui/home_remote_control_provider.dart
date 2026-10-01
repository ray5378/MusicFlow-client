import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/player/peer_display_order.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

/// 面板互斥:**单一枚举**。
///
/// 为什么不用两个 bool:`showQueue` / `showVolume` 会出现「两个都 true」的
/// 脏态(L1 同时挂两个覆盖面板)。枚举在类型上就排除了这种状态。
/// autoDispose:块被用户隐藏 → provider 释放 → 状态不残留。
enum RemoteControlPanelKind { none, queue, volume }

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
  // ⚠️ `loadPeers()` 内部会**同步写** CastPeerState(offline/peers 等)。若在
  // provider 的 build 阶段直接调用,riverpod 会抛「Providers are not allowed
  // to modify other providers during their initialization」断言(实测挂掉
  // 整个 discover 页测试组)。用 `Future(() {})` 把它挪到微任务 —— 本次
  // build 落定之后才触发状态写入;不用 `Future.delayed`,避免在测试环境
  // 引入真 Timer。
  await Future<void>(() {});
  return notifier.loadPeers();
});

/// 切换器候选项:仅 `available`(离线不参与选择,对齐 HA 的
/// `available !== false`);**本机由 `p.self` 识别**(不能用 `kind=='local'`
/// 一刀切);排序复用 `peer_display_order.dart` 的唯一实现,不内联副本。
final remoteControlTargetsProvider = Provider.autoDispose<List<PeerInfo>>(
  (ref) {
    final peers = ref.watch(remoteControlPeersProvider).valueOrNull;
    if (peers == null) return const <PeerInfo>[];
    return peers.where((p) => p.available).toList()
      ..sort(comparePeerDisplayOrder);
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
