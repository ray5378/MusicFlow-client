// b43a —— 连接状态心跳提示「状态机」的行为测试（R1~R6 + _emit 去重）。
//
// 覆盖 lib/providers/ui/connection_beacon_provider.dart。
//
// ⚠️ 这是 Notifier + Timer 的状态机，**必须**用 fakeAsync 推进虚拟时钟；
// 阈值改用 @visibleForTesting 的可注入字段，压到 10~100ms。
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/api/connection_gate.dart';
import 'package:musicflow_client/providers/ui/connection_beacon_provider.dart';

/// 输入：此刻是否连通 / 本会话是否曾连通过。
final _connectedFlag = StateProvider<bool>((ref) => false);
final _everConnectedFlag = StateProvider<bool>((ref) => false);

/// 测试用阈值（与 setUp 里的赋值保持一致，断言里可读）。
const Duration _showDelay = Duration(milliseconds: 10);
const Duration _linger = Duration(milliseconds: 50);
const Duration _debounce = Duration(milliseconds: 20);
const Duration _coldStartDeadline = Duration(milliseconds: 100);

/// 把 provider 容器 + 状态流转记录打包起来，省掉每条用例的样板代码。
class _Beacon {
  _Beacon({required bool connected, required bool everConnected}) {
    container = ProviderContainer(
      overrides: <Override>[
        sessionConnectedProvider.overrideWith(
          (ref) => ref.watch(_connectedFlag),
        ),
        sessionEverConnectedProvider.overrideWith(
          (ref) => ref.watch(_everConnectedFlag),
        ),
      ],
    );
    // 先落输入，再建 provider：build() 会在首次读取时读取这两个真值。
    container.read(_connectedFlag.notifier).state = connected;
    container.read(_everConnectedFlag.notifier).state = everConnected;
    container.read(connectionBeaconProvider);
    subscription = container.listen<ConnectionBeaconState>(
      connectionBeaconProvider,
      (previous, next) => phases.add(next.phase),
      fireImmediately: true,
    );
  }

  late final ProviderContainer container;
  late final ProviderSubscription<ConnectionBeaconState> subscription;

  /// 依次出现过的 phase（首项是初始状态）。
  final List<ConnectionBeaconPhase> phases = <ConnectionBeaconPhase>[];

  ConnectionBeaconPhase get phase => container.read(connectionBeaconProvider).phase;

  ConnectionBeaconReason get reason =>
      container.read(connectionBeaconProvider).reason;

  void connect(bool value) {
    container.read(_connectedFlag.notifier).state = value;
  }

  void markEverConnected() {
    container.read(_everConnectedFlag.notifier).state = true;
  }

  void dispose() {
    subscription.close();
    container.dispose();
  }
}

void main() {
  setUp(() {
    beaconShowDelay = _showDelay;
    beaconConnectedLinger = _linger;
    beaconLostDebounce = _debounce;
    beaconColdStartDeadline = _coldStartDeadline;
  });

  tearDown(resetConnectionBeaconTimingsForTest);

  test('R1 快连不闪灰：显示延迟内连上，全程不出现 waiting', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: false, everConnected: false);
      expect(beacon.phase, ConnectionBeaconPhase.hidden);

      // 还没到显示延迟就连上了。
      async.elapse(const Duration(milliseconds: 4));
      beacon.connect(true);

      async.elapse(_linger * 4);

      expect(
        beacon.phases,
        isNot(contains(ConnectionBeaconPhase.waiting)),
        reason: '显示延迟内连上就不该闪一下灰点',
      );
      expect(beacon.phases, <ConnectionBeaconPhase>[
        ConnectionBeaconPhase.hidden,
        ConnectionBeaconPhase.connected,
        ConnectionBeaconPhase.hidden,
      ]);
      beacon.dispose();
    });
  });

  test('R1 慢连才出灰点：超过显示延迟后 waiting + coldStart', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: false, everConnected: false);
      expect(beacon.phase, ConnectionBeaconPhase.hidden);

      // 延迟差一点点：仍然隐藏。
      async.elapse(_showDelay - const Duration(milliseconds: 1));
      expect(beacon.phase, ConnectionBeaconPhase.hidden);

      async.elapse(const Duration(milliseconds: 2));
      expect(beacon.phase, ConnectionBeaconPhase.waiting);
      expect(beacon.reason, ConnectionBeaconReason.coldStart);
      beacon.dispose();
    });
  });

  test('R2 连上立即变绿，停留期满后隐藏', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: false, everConnected: false);
      async.elapse(_showDelay + const Duration(milliseconds: 1));
      expect(beacon.phase, ConnectionBeaconPhase.waiting);

      beacon.connect(true);
      expect(beacon.phase, ConnectionBeaconPhase.connected);

      async.elapse(_linger - const Duration(milliseconds: 1));
      expect(
        beacon.phase,
        ConnectionBeaconPhase.connected,
        reason: '停留期内绿色必须常亮',
      );

      async.elapse(const Duration(milliseconds: 2));
      expect(beacon.phase, ConnectionBeaconPhase.hidden);
      beacon.dispose();
    });
  });

  test('R3 失联走防抖：窗口内维持原状，到期仍断才变灰', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: true, everConnected: true);
      expect(beacon.phase, ConnectionBeaconPhase.connected);
      async.elapse(_linger * 2);
      expect(beacon.phase, ConnectionBeaconPhase.hidden);

      beacon.connect(false);
      async.elapse(_debounce - const Duration(milliseconds: 1));
      expect(
        beacon.phase,
        ConnectionBeaconPhase.hidden,
        reason: '防抖窗口内不得抢跑',
      );

      async.elapse(const Duration(milliseconds: 2));
      expect(beacon.phase, ConnectionBeaconPhase.waiting);
      expect(beacon.reason, ConnectionBeaconReason.lost);
      beacon.dispose();
    });
  });

  test('R3 防抖窗口内恢复：全程不出现 waiting', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: true, everConnected: true);
      async.elapse(_linger * 2);
      expect(beacon.phase, ConnectionBeaconPhase.hidden);

      beacon.connect(false);
      async.elapse(_debounce ~/ 2);
      beacon.connect(true);
      expect(beacon.phase, ConnectionBeaconPhase.connected);

      async.elapse(_linger * 3);
      expect(
        beacon.phases,
        isNot(contains(ConnectionBeaconPhase.waiting)),
        reason: '抖动恢复不该横跳成灰点',
      );
      beacon.dispose();
    });
  });

  test('R4 绿色窗口内失联：立即变灰，不等防抖也不等隐藏', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: true, everConnected: true);
      expect(beacon.phase, ConnectionBeaconPhase.connected);

      // 停留在绿色 5 秒窗口**之内**。
      async.elapse(_linger ~/ 2);
      expect(beacon.phase, ConnectionBeaconPhase.connected);

      beacon.connect(false);
      // 同步生效，不需要 elapse（远小于防抖窗口）。
      expect(beacon.phase, ConnectionBeaconPhase.waiting);
      expect(beacon.reason, ConnectionBeaconReason.lost);

      // 原来的隐藏定时器必须被取消，否则灰点会被覆盖成隐藏。
      async.elapse(_linger * 4);
      expect(beacon.phase, ConnectionBeaconPhase.waiting);
      beacon.dispose();
    });
  });

  test('R5 冷启动灰点累计到上限后隐藏', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: false, everConnected: false);
      async.elapse(_showDelay + const Duration(milliseconds: 1));
      expect(beacon.phase, ConnectionBeaconPhase.waiting);
      expect(beacon.reason, ConnectionBeaconReason.coldStart);

      async.elapse(const Duration(milliseconds: 90));
      expect(beacon.phase, ConnectionBeaconPhase.waiting);

      async.elapse(const Duration(milliseconds: 40));
      expect(beacon.phase, ConnectionBeaconPhase.hidden);
      beacon.dispose();
    });
  });

  test('R6 本会话曾连通过：失联灰点不受冷启动上限约束', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: false, everConnected: false);
      async.elapse(_showDelay + const Duration(milliseconds: 1));
      expect(beacon.phase, ConnectionBeaconPhase.waiting);
      expect(beacon.reason, ConnectionBeaconReason.coldStart);

      // 会话级「曾连通」翻真 → 撤掉 60s 上限。
      beacon.markEverConnected();
      beacon.connect(true);
      expect(beacon.phase, ConnectionBeaconPhase.connected);
      beacon.connect(false);
      expect(beacon.phase, ConnectionBeaconPhase.waiting);
      expect(beacon.reason, ConnectionBeaconReason.lost);

      async.elapse(_coldStartDeadline * 5);
      expect(
        beacon.phase,
        ConnectionBeaconPhase.waiting,
        reason: '连通过之后失联，灰点应常驻而不是 60 秒后自愈消失',
      );
      expect(beacon.reason, ConnectionBeaconReason.lost);
      beacon.dispose();
    });
  });

  test('_emit 去重：同值不重发，state 实例保持不变', () {
    fakeAsync((async) {
      final beacon = _Beacon(connected: false, everConnected: false);
      beacon.connect(true);
      expect(beacon.phase, ConnectionBeaconPhase.connected);
      async.elapse(_linger * 2);
      expect(beacon.phase, ConnectionBeaconPhase.hidden);

      final before = beacon.container.read(connectionBeaconProvider);
      final notificationsBefore = beacon.phases.length;

      // 从未连通过 + 已经是 hidden → 走的正是 `_emit(hidden, coldStart)`，
      // 与当前值相同，必须被去重掉。
      beacon.connect(false);
      final after = beacon.container.read(connectionBeaconProvider);

      expect(
        identical(before, after),
        isTrue,
        reason: '值相同的 _emit 不得重建 state，否则订阅者会白刷一遍',
      );
      expect(after, before);
      expect(after.phase, ConnectionBeaconPhase.hidden);
      expect(beacon.phases.length, notificationsBefore);
      beacon.dispose();
    });
  });
}
