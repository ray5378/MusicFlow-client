/// 播放端展示序 —— 三端统一口径的**唯一实现**（客户端 / HA 卡片同序）。
///
/// 排序键依次为（用户定稿 2026-09-24）：
///   ① **正在播的排前面** —— 取服务端 `queue.isActive`（→ `PeerInfo.queueActive`），
///      不额外发请求；多台设备一起响时，在播的先看得到；
///   ② 同为在播或同为闲置时按**类别**：客户端本机 > 群组 > 独立播放器
///      （群组是更上层的控制目标，排在独立播放器之前）；
///   ③ 再相同按名称，保证顺序稳定。
///
/// ⚠️ **口径历史**：曾出现过「类别优先」（群组恒压过在播）的中间态，用户已明确否掉 ——
/// 第一维度必须是「在播」，不是「类别」。
///
/// ⚠️ **不得内联副本**：流转页（`player_transfer_page.dart`）与切换器
/// （`player_switcher.dart`）曾经各写一份比较器，改了一处就漂移。两个调用点必须走本文件。
/// CI 双锁：`tool/check-peer-order.mjs`（禁止内联副本 + 校验键序）+
/// `test/features/player/peer_display_order_test.dart`（行为锁），
/// 由阻塞 workflow `.github/workflows/peer-order-guard.yml` 执行。
library;

import 'package:musicflow_client/data/models/peer.dart';

/// 类别权重：客户端本机（含同账号其它端）0 < 群组 1 < 独立播放器 2。
int peerKindRank(PeerInfo p) {
  if (p.isLocal) return 0;
  if (p.kind == 'group') return 1;
  return 2;
}

/// 播放端展示序比较器：**在播优先 → 类别 → 名称**。
///
/// 注意比较顺序即契约：先比 [PeerInfo.queueActive]，再比 [peerKindRank]。
/// 调换两者 = 变成「类别优先」，是已被否掉的口径（守卫会判红）。
int comparePeerDisplayOrder(PeerInfo a, PeerInfo b) {
  final pa = a.queueActive ? 0 : 1;
  final pb = b.queueActive ? 0 : 1;
  if (pa != pb) return pa - pb;
  final ka = peerKindRank(a);
  final kb = peerKindRank(b);
  if (ka != kb) return ka - kb;
  return a.name.compareTo(b.name);
}
