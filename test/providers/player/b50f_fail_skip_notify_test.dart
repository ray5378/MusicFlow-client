// b50f：P2「连跳提示」——连续自动跳过的合并提示策略。
//
// 背景：i5 评估「统一四条链路连跳停止阈值」时发现该方向**违反**已钉死的播放
// 链路契约（2026-09-09 拍板：无停播阈值、不可播逐曲移除、无限跳；服务端
// `.github/workflows/playback-chain-guard.yml` 对 QueueController / Web player.ts
// 做静态守卫）。故只落地契约兼容的一半：**只提示、不停止**。
//
// 这里只测纯策略 `shouldNotifyFailSkipStreak`（确定性、无副作用）；失败路径
// 下「提示不抛」的集成断言见 b29a_playback_helpers_cov_test.dart。
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/player/player_provider.dart';

void main() {
  test('阈值前不提示：0/1/2 次连跳静默（不打扰用户）', () {
    expect(shouldNotifyFailSkipStreak(consecutiveFailSkips: 0), isFalse);
    expect(shouldNotifyFailSkipStreak(consecutiveFailSkips: 1), isFalse);
    expect(shouldNotifyFailSkipStreak(consecutiveFailSkips: 2), isFalse);
  });

  test('恰好到达阈值（3）时提示', () {
    expect(kFailSkipNotifyThreshold, 3);
    expect(shouldNotifyFailSkipStreak(consecutiveFailSkips: 3), isTrue);
  });

  test('超过阈值不再重复提示（计数器仅在成功播放后清零 ⇒ 一条失败串只提示一次）', () {
    expect(shouldNotifyFailSkipStreak(consecutiveFailSkips: 4), isFalse);
    expect(shouldNotifyFailSkipStreak(consecutiveFailSkips: 10), isFalse);
  });
}
