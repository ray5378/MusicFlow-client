/// 本地播放「服务端权威洗牌序列」推进的**纯逻辑**（无 Flutter / HTTP / Riverpod 依赖，可单测）。
///
/// 背景：2026-09-11 补齐 SPEC，洗牌序列唯一权威在服务端，客户端只做镜像。
/// 本机 `next()` 沿服务端序列推进，拿不到序列（离线/未注册）时回退本地随机。
/// 序列推进里最易回归的两段——「跳过已知死链」与「序列尾触发重洗」——被
/// 抽成纯函数，由 [ServerShuffleSequence.advance] 承载，使它们脱离 HTTP/状态
/// 即可单测（见 test/core/player/server_shuffle_sequence_test.dart，阻塞式
/// offline-cache-guard 覆盖）。
///
/// 语义（与 `player_shuffle_queue.dart::_pickServerShuffleNext` 同源）：
/// - 只沿序列前进，遇到「明确的、未过期的不可播」歌（[isUnplayable] 返回 true）
///   才跳过；未知/transient 一律照常播（绝不把「不知道」当「死的」）。
/// - 从 [startPos]+1 起若再无可播（越过序列尾，或剩余全死），返回 null，
///   由调用方触发整轮重洗。
class ServerShuffleSequence {
  ServerShuffleSequence._();

  /// 沿洗牌序列从 [startPos] 向后推进，跳过已知死链，返回下一首的**队列下标**；
  /// 若从 [startPos]+1 起全部不可播（越过序列尾）返回 null（调用方应触发重洗）。
  ///
  /// [isUnplayable] 接收队列下标，判断该首是否已知不可播（true=跳）。
  /// 不改任何状态；[order] 为队列下标序列，[startPos] 为当前曲在序列中的位置
  /// （传 -1 表示从序列头开始找第一首非死链）。
  static int? advance(
    List<int> order,
    int startPos,
    bool Function(int queueIndex) isUnplayable,
  ) {
    final n = order.length;
    if (n == 0) return null;
    if (startPos < -1) return null;
    var p = startPos + 1;
    while (p < n && isUnplayable(order[p])) {
      p++;
    }
    if (p >= n) return null;
    return order[p];
  }
}
