// b54a —— 恢复快照请求的连接闸等待测试（cast_peer_provider._waitForRestoreConnectionGate）。
//
// fetchLocalQueueForRestore 在 FLUTTER_TEST 下入口短路（避免 timeout 的 Timer
// 撞 flutter_test 不变量，见 lib 内注释），所以闸的分支覆盖走测试注入点
// waitForRestoreConnectionGateForTest（b39b2 waitForLocalPeerIdForTest 先例）。
//
// 覆盖三条判据：
//   G1 已真实连通（sessionEverConnected）→ 立即放行，零等待；
//   G2 未连通 → 预算到期照常放行（闸是加速器不是门禁），且等待方摘除干净；
//   G3 等待中首连事件到达 → 立刻放行（远早于预算）。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/connection_gate.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../helpers/mocks.dart';
import '../../features/player/test_player_notifier.dart';

ServerAddress _addr() => ServerAddress(
      id: 'addr-1',
      libraryId: 'lib-1',
      label: 'Home',
      url: 'https://example.test',
      priority: 0,
    );

/// 地址池替身：一条地址、永不自己连通；probeAll 立即落定（不真探）。
class _GatePool extends AddressPool {
  _GatePool() : super(Dio());

  final List<ServerAddress> _list = <ServerAddress>[_addr()];

  @override
  List<ServerAddress> get addresses => List<ServerAddress>.unmodifiable(_list);

  @override
  bool get isProbing => false;

  @override
  Future<ServerAddress?> probeAll() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late CastPeerController ctrl;
  late _GatePool pool;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    resetConnectionGateForTest();
    pool = _GatePool();
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(MockSubsonicApiClient()),
        playerProvider.overrideWith(() => TestPlayerNotifier(PlayerState())),
        addressPoolProvider.overrideWithValue(pool),
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

  test('G1 已真实连通 → 立即放行', () async {
    pool.markSessionEverConnected();
    final watch = Stopwatch()..start();
    await ctrl.waitForRestoreConnectionGateForTest();
    watch.stop();
    expect(
      watch.elapsedMilliseconds,
      lessThan(500),
      reason: '已连通时闸必须零等待放行',
    );
    expect(
      pool.debugSessionEverConnectedListenerCount,
      0,
      reason: '放行后等待方必须摘除干净',
    );
  });

  test('G2 未连通 → 预算到期照常放行（闸不是门禁）', () async {
    restoreSnapshotGateBudget = const Duration(milliseconds: 120);
    final watch = Stopwatch()..start();
    await ctrl.waitForRestoreConnectionGateForTest();
    watch.stop();
    expect(
      watch.elapsedMilliseconds,
      greaterThanOrEqualTo(100),
      reason: '未连通时最多等一个预算，然后放行',
    );
    expect(
      pool.debugSessionEverConnectedListenerCount,
      0,
      reason: '预算到期放行后等待方必须摘除干净',
    );
  });

  test('G3 等待中首连事件到达 → 立刻放行', () async {
    restoreSnapshotGateBudget = const Duration(seconds: 5);
    final watch = Stopwatch()..start();
    final future = ctrl.waitForRestoreConnectionGateForTest();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      pool.debugSessionEverConnectedListenerCount,
      1,
      reason: '等待期必须挂着一个首连等待方',
    );

    pool.markSessionEverConnected();
    pool.notifySessionEverConnectedForTest();
    await future.timeout(const Duration(seconds: 3));
    watch.stop();
    expect(
      watch.elapsedMilliseconds,
      lessThan(2000),
      reason: '首连事件一到必须立刻放行，不能等满预算',
    );
    expect(
      pool.debugSessionEverConnectedListenerCount,
      0,
      reason: '放行后等待方必须摘除干净',
    );
  });
}
