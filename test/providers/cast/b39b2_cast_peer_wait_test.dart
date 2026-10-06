// b39b2 —— Route B：cast_peer_provider 剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * cast_peer_provider.dart:126  _ensurePeerIdReady：completer 为 null 时新建
//
// 其余未命中行经源码核查均不可达（flutter test 环境），逐行结论见文件末尾注释。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../helpers/mocks.dart';
import '../../features/player/test_player_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CastPeerController.waitForLocalPeerIdForTest（126）', () {
    late ProviderContainer container;
    late CastPeerController ctrl;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      container = ProviderContainer(
        overrides: <Override>[
          subsonicApiClientProvider.overrideWithValue(MockSubsonicApiClient()),
          playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        ],
      );
      ctrl = container.read(castPeerControllerProvider.notifier);
    });

    tearDown(() async {
      try {
        ctrl.stopHeartbeat();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 10));
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('未注册时等待 peerId：首次新建 completer（line 126），超时返回 null', () async {
      // 首次调用：_localPeerIdReady 为 null → line 126 条件成立 → 新建 completer。
      // 无注册落地 → 1.5s 预算超时 → 返回 null（不抛）。
      final pid = await ctrl.waitForLocalPeerIdForTest();
      expect(pid, isNull, reason: '未注册且预算内无注册落地应返回 null');
    });

    test('已有未完成 completer 时复用（line 126 的 isCompleted=false 分支）', () async {
      // 第二次调用：completer 非 null 且未完成 → line 126 条件不成立 → 复用。
      // 两次都是超时兜底，两次合计验证 126 的两个分支均被执行。
      final first = await ctrl.waitForLocalPeerIdForTest();
      final second = await ctrl.waitForLocalPeerIdForTest();
      expect(first, isNull);
      expect(second, isNull);
    });
  });
}

/*
 * 其余未命中行的可达性结论（源码核查，flutter test 环境下均不可达，不虚设用例）：
 *
 * - 264-266 / 269（_waitForApiCredentialsReady 等待凭证信号）：
 *   入口 line 261 `if (Platform.environment['FLUTTER_TEST'] != null) return;`
 *   —— flutter 工具恒注入 FLUTTER_TEST，测试环境直接短路。
 *
 * - 296（_deviceCard 的 catch）：仅当 Platform.isWindows/isAndroid... 或
 *   Platform.localHostname 抛错才触达；这些是宿主 OS 系统调用，测试无法注入失败。
 *
 * - 482-498（fetchLocalQueueForRestore 拉快照）：入口 line 481 同样被
 *   FLUTTER_TEST 门禁短路（lib 内注释已明示这是为避免 timeout Timer 撞
 *   flutter_test 不变量而设的测试门禁）。
 *
 * - 988（_clearSourceQueue 空 peerId）：唯一调用点 _resetPeer(1049) 顶部
 *   （1020-1025）已对空 peerId 早退返回 false，能传进 _clearSourceQueue 的
 *   peerId 恒非空 —— 守卫使然，属防御性死分支。
 *
 * - 1428-1434（seek 下发失败的处理）：[D-060] 已于 batch40 E2 修复 —— seek 现在
 *   检查 _post 返回 null 视为失败：清因果屏障标记、不做乐观对齐、经 warn 日志
 *   上报。b38b3 的「seek 下发失败」用例已翻成锁定修复断言。
 */
