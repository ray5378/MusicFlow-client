// 批 D-1 · 连接就绪闸 + **两档周期重连**的行为钉子。
//
// 闸的四条硬判据（对应规格第 4 节）：
//   1. **闸会等**：有一轮探测正在给连接暖场、而 `activeAddressProvider.status`
//      还不是 `ok` 时，远程请求不发；status 变 ok 的同一刻放行；
//   2. **闸等的是「往返落定」而不是「状态变化」**：持久化恢复的地址自带上次的
//      `status = ok`，本轮探测成功时状态没有变化 —— 此时必须靠「探测落定」
//      放行，否则每次冷启动都白等满 6s（把首屏加速做成首屏减速）；
//   3. **闸不是门禁**：budget（6s）到期照常尽力发出，且**不**置 failed、
//      不弹「网络异常」；
//   4. **地址池为空立即放行**：没有可连的地址就没有可等的连接。
//
// 两档重连（`Reconnector` 全局单例）的判据：
//   5. **冷启动档 1s**：`sessionEverConnected == false` 时每秒探一次；
//   6. **30s 硬窗口**：从启动算起 30 秒到点必停，之后再也不探；
//   7. **失联档 10s**：`sessionEverConnected == true` 时每 10 秒探一次，无总时限；
//   8. **成功即停 + 一次性全刷**：探测成功的那一刻停表，并把所有失败区块重拉；
//   9. **B6 不叠加 6s**：被重连器刷新的区块重建时，闸必须立即放行
//      （否则「1 秒重连」变成「7 秒重连」）；
//  10. **B2 无观众即停**：注册过的 provider 全部失去监听者 → 暂停；观众回来
//      立即重试一次；
//  11. **B3 dispose 即取消定时器**：容器 dispose（**非 flush 期**）后不再有任何
//      探测，且登记表真的清空 —— `if (_flushing) return;` 那道短路只允许在
//      flush 中途生效，绝不能变成「全部 dispose 也不停」；
//  12. **B4 不放大探测**：首屏十几个区块共用一轮探测；**两档失败都只探测、
//      不扇出** —— 失败扇出会自我节流（6 区块 × 3 次重试 = 18 个请求挤进 3 秒，
//      打穿 12 次/10s 的令牌桶），且在服务器回来那一刻反被限流。业务扇出只在
//      成功那一刻 `_flushAll()` 一次。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/connection_gate.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';

final StateProvider<bool> _flagProvider = StateProvider<bool>((ref) => false);

ServerAddress _addr(ServerAddressStatus status, {String id = 'addr-1'}) =>
    ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: 'Home',
      url: 'https://example.test',
      priority: 0,
      status: status,
    );

/// 地址池替身：提供闸需要的三件事 ——「有没有地址」「有没有往返在飞」
/// 「踢一轮探测」，外加重连器需要的「单发 /ping」。
///
/// 刻意用真 [AddressPool] 的子类而不是 mock：闸依赖 `probeAll` 的 in-flight
/// 复用语义（并发调用拿到同一个 future），子类化能保住这个契约；
/// `sessionEverConnected` 也走真实的「只置 true」路径（[markSessionEverConnected]）。
class _FakePool extends AddressPool {
  _FakePool(this._list) : super(Dio());

  final List<ServerAddress> _list;
  int probeAllCalls = 0;

  /// 重连器探测次数（= `/ping` 次数，判据 5/6/7/10/11 都靠它）。
  int reconnectProbes = 0;

  /// 重连器探测结果。置 true 模拟「服务器回来了」。
  bool reconnectResult = false;

  /// 非空 → 探测「挂住不落定」，用来观察闸在等待期的行为。
  Completer<void>? hold;

  Completer<ServerAddress?>? _inFlight;

  @override
  List<ServerAddress> get addresses => List<ServerAddress>.unmodifiable(_list);

  @override
  bool get isProbing => _inFlight != null;

  @override
  Future<ServerAddress?> probeAll() {
    final existing = _inFlight;
    if (existing != null) return existing.future;
    probeAllCalls++;
    final completer = Completer<ServerAddress?>();
    _inFlight = completer;
    final value = _list.isEmpty ? null : _list.first;
    void settle() {
      _inFlight = null;
      if (!completer.isCompleted) completer.complete(value);
    }

    final gate = hold;
    if (gate == null) {
      unawaited(Future<void>.value().then((_) => settle()));
    } else {
      unawaited(gate.future.then((_) => settle()));
    }
    return completer.future;
  }

  @override
  Future<void> probeActiveThrottled() async {}

  @override
  Future<bool> probeOnceForReconnect({
    Duration timeout = kReconnectProbeTimeout,
  }) async {
    reconnectProbes += 1;
    if (!reconnectResult) return false;
    // 与生产路径一致：成功必须经 `_applyProbeResult` 的**成功分支**置位。
    markSessionEverConnected();
    return true;
  }
}

/// 被测场景：一个计数器 + 可控失败。
class _Scenario {
  _Scenario({this.fail = false});

  bool fail;
  int fetchCalls = 0;

  Future<String> fetch() async {
    fetchCalls += 1;
    if (fail) throw StateError('simulated tunnel not warm');
    return 'remote-$fetchCalls';
  }
}

final _scenarioProvider = Provider<_Scenario>(
  (ref) => throw UnimplementedError('must be overridden'),
);

/// 真实 FutureProvider 包一层 helper：`ref.invalidateSelf()` 的重连重拉路径
/// 只有在真实 provider 里才有意义。
final _probeProvider = FutureProvider<String>((ref) async {
  final scenario = ref.watch(_scenarioProvider);
  return fetchWithCacheFallback<String>(
    ref: ref,
    label: 'probe',
    fetch: scenario.fetch,
    cacheWrite: (_) async {},
    cacheRead: () async => null,
    failedProvider: _flagProvider,
    errorMessage: 'net-down',
    emptyValue: '',
  );
});

/// 并发用：首屏十几个区块各建一次 provider。
final _familyProbeProvider = FutureProvider.family<String, int>((ref, index) {
  final scenario = ref.watch(_scenarioProvider);
  return fetchWithCacheFallback<String>(
    ref: ref,
    label: 'probe-$index',
    fetch: scenario.fetch,
    cacheWrite: (_) async {},
    cacheRead: () async => null,
    failedProvider: _flagProvider,
    errorMessage: 'net-down',
    emptyValue: '',
  );
});

ProviderContainer _container({
  required _Scenario scenario,
  required ServerAddress active,
  required _FakePool pool,
}) {
  return ProviderContainer(
    overrides: <Override>[
      _scenarioProvider.overrideWithValue(scenario),
      activeAddressProvider.overrideWith((ref) => active),
      ensureActiveAddressProvider.overrideWith((ref) async => active),
      addressPoolProvider.overrideWith((ref) => pool),
    ],
  );
}

void main() {
  // 失败路径会经 NetworkErrorNotifier → ToastNotifier 访问 WidgetsBinding。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NetworkErrorNotifier.resetForTest();
    resetRefreshGateForTest();
    resetConnectionGateForTest();
    refreshClockForTest = DateTime.now;
  });

  tearDown(() {
    NetworkErrorNotifier.resetForTest();
    resetRefreshGateForTest();
    resetConnectionGateForTest();
  });

  group('连接就绪闸', () {
    test('探测在飞 + status=unknown → 请求会等；status 变 ok 后立即放行', () {
      fakeAsync((async) {
        final scenario = _Scenario();
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.unknown),
        ])..hold = Completer<void>();
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.unknown),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(scenario.fetchCalls, 0, reason: '连接还没建立就发请求，正是用户报的「请求时机早于连接建立」');

        // 连接建立（探测成功 → status 变 ok 并上报到 activeAddressProvider）。
        container.read(activeAddressProvider.notifier).state = _addr(
          ServerAddressStatus.ok,
        );
        async.flushMicrotasks();

        expect(
          scenario.fetchCalls,
          1,
          reason: 'status 变 ok 的同一刻就该放行，不该再等满 6s 预算',
        );
        expect(container.read(_flagProvider), isFalse);
      });
    });

    test('持久化恢复的 stale-ok + 探测在飞 → 探测落定即放行（靠落定信号）', () {
      fakeAsync((async) {
        final scenario = _Scenario();
        final pool = _FakePool(<ServerAddress>[_addr(ServerAddressStatus.ok)])
          ..hold = Completer<void>();
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.ok), // 上次会话留下的 ok
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(scenario.fetchCalls, 0, reason: '已有一轮往返在给连接暖场 → 等它，别抢在暖场之前发请求');

        // 这一轮探测落定（成功时状态没有变化，所以不会有 status 变化回调）。
        pool.hold!.complete();
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();

        expect(
          scenario.fetchCalls,
          1,
          reason:
              '必须具备「探测落定」这条放行信号，否则 stale-ok 场景每次'
              '冷启动都白等满 6s（状态没变化 → 永远等不到 status 回调）',
        );
      });
    });

    test('闸不是门禁：6s 预算到期照常放行，且不置 failed、不弹网络异常', () {
      fakeAsync((async) {
        final scenario = _Scenario();
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.failed),
        ])..hold = Completer<void>();
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.failed),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(scenario.fetchCalls, 0, reason: '5s 时仍在预算内，继续等');

        async.elapse(kConnectionGateBudget);
        async.flushMicrotasks();

        expect(scenario.fetchCalls, 1, reason: '预算到期必须放行 —— 闸是加速器，不是门禁');
        expect(
          container.read(_flagProvider),
          isFalse,
          reason: '闸超时绝不能置 failed：那会把「连得慢」误报成「加载失败」',
        );
      });
    });

    test('地址池为空（未配置服务器）→ 闸立即放行，不白等 6s', () {
      fakeAsync((async) {
        final scenario = _Scenario();
        final pool = _FakePool(const <ServerAddress>[]);
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.unknown),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(scenario.fetchCalls, 1, reason: '没有可连的地址就没有可等的连接，硬等只会把首屏白拖 6s');
        expect(pool.probeAllCalls, 0);
        expect(
          Reconnector.instance.isRunning,
          isFalse,
          reason: '未配置服务器是另一条产品路径（引导页），不该起定时重连',
        );
      });
    });
  });

  group('两档周期重连', () {
    test('冷启动档：每 1 秒一次探测（10s 内 10 次）', () {
      fakeAsync((async) {
        final scenario = _Scenario(fail: true);
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.failed),
        ]);
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.failed),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(scenario.fetchCalls, 1, reason: '首次加载失败 → 上报重连器');
        expect(container.read(_flagProvider), isTrue);
        expect(Reconnector.instance.isRunning, isTrue);
        expect(Reconnector.instance.tier, 'cold');
        expect(pool.reconnectProbes, 0, reason: '第一个 tick 要在 1s 之后');

        async.elapse(const Duration(seconds: 10));
        expect(
          pool.reconnectProbes,
          10,
          reason: '冷启动档必须每秒一次（用户原话：「失败后自动重连每秒触发一次」）',
        );
        expect(
          Reconnector.instance.tickCount,
          10,
          reason: '1s 一次必须落在「探测」上，不是每个区块各发一次业务请求',
        );
        expect(
          scenario.fetchCalls,
          1,
          reason:
              '冷启动档失败时**不许**重拉区块：1s × 十几个区块会把 '
              '12 次/10s 的令牌桶打穿（自我 DDoS）',
        );
      });
    });

    test('冷启动档：30s 硬窗口到点必停，之后不再探测', () {
      fakeAsync((async) {
        final scenario = _Scenario(fail: true);
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.failed),
        ]);
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.failed),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 40));

        // 30s 窗口内 1s 一跳 ⇒ 29~30 次（窗口 timer 与最后一个 tick 同在
        // t=30s 到期，谁先触发取决于注册顺序，两种都算合格）。
        expect(pool.reconnectProbes, inInclusiveRange(29, 30));
        expect(
          Reconnector.instance.isRunning,
          isFalse,
          reason: '30s 到点必须停：服务器真挂了就不许无限烧电池，交给下拉刷新兜',
        );
        expect(container.read(_flagProvider), isTrue);

        final settled = pool.reconnectProbes;
        async.elapse(const Duration(seconds: 120));
        expect(
          pool.reconnectProbes,
          settled,
          reason: '窗口耗尽后必须彻底停手（否则就是永久 1s 轮询）',
        );
      });
    });

    test('失联档：会话已连通过 → 10 秒一次，且无总时限', () {
      fakeAsync((async) {
        final scenario = _Scenario(fail: true);
        final pool = _FakePool(<ServerAddress>[_addr(ServerAddressStatus.ok)])
          ..markSessionEverConnected();
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.ok),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(Reconnector.instance.tier, 'disconnect');

        async.elapse(const Duration(seconds: 9));
        expect(pool.reconnectProbes, 0, reason: '失联档是 10s，不是 1s');

        async.elapse(const Duration(seconds: 1));
        expect(pool.reconnectProbes, 1, reason: '第 10 秒必须有且只有一次');

        // 无总时限：越过 30s 仍在跑（这点与冷启动档正相反）。
        async.elapse(const Duration(seconds: 60));
        expect(Reconnector.instance.isRunning, isTrue);
        expect(pool.reconnectProbes, 7, reason: '10s、20s、…、70s 共 7 次');
      });
    });

    test('连接成功即停，并把所有失败区块一次性重拉（B1 + B6 不叠加 6s）', () {
      fakeAsync((async) {
        final scenario = _Scenario(fail: true);
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.failed),
        ]);
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.failed),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(pool.reconnectProbes, 2);
        expect(scenario.fetchCalls, 1);

        // 服务器回来了。同时把 probeAll 挂住：若被刷新的区块重建时还老实等闸，
        // 就会白等满 6s —— B6 的快速放行通道必须让它在毫秒级就发出请求。
        pool.reconnectResult = true;
        scenario.fail = false;
        pool.hold = Completer<void>();

        async.elapse(const Duration(seconds: 1)); // 第 3 个 tick → 成功
        async.elapse(const Duration(milliseconds: 1)); // 让 invalidateSelf 的重建落地

        expect(
          Reconnector.instance.isRunning,
          isFalse,
          reason: 'B1：探测成功必须立刻停表',
        );
        expect(
          scenario.fetchCalls,
          2,
          reason: 'B6：重连触发的重建必须立即放行；只到 1 次说明它又白等了 6s',
        );

        final probes = pool.reconnectProbes;
        async.elapse(const Duration(seconds: 60));
        expect(pool.reconnectProbes, probes, reason: '停表之后不许再有探测');
      });
    });

    test('B2 无观众即暂停；观众回来立即重试一次', () {
      fakeAsync((async) {
        final scenario = _Scenario(fail: true);
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.failed),
        ]);
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.failed),
          pool: pool,
        );
        addTearDown(container.dispose);
        final sub = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(pool.reconnectProbes, 2);

        // 首页被切走：最后一个监听者消失。
        sub.close();
        async.flushMicrotasks();
        expect(Reconnector.instance.isPaused, isTrue);

        async.elapse(const Duration(seconds: 20));
        expect(pool.reconnectProbes, 2, reason: 'B2：没人看的时候不该继续烧流量');

        // 用户切回首页：必须**立即**重试一次，不能等一整个间隔。
        final sub2 = container.listen(_probeProvider, (_, _) {});
        addTearDown(sub2.close);
        async.elapse(const Duration(milliseconds: 1));
        expect(pool.reconnectProbes, 3, reason: 'B2：观众回来立即重试一次');
        expect(Reconnector.instance.isPaused, isFalse);
      });
    });

    test('B3 容器 dispose（**非 flush 期**）后取消定时器，不再有任何探测', () {
      fakeAsync((async) {
        final scenario = _Scenario(fail: true);
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.failed),
        ]);
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.failed),
          pool: pool,
        );
        final sub = container.listen(_probeProvider, (_, _) {});

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(pool.reconnectProbes, 2);

        sub.close();
        container.dispose();
        async.flushMicrotasks();
        expect(
          Reconnector.instance.isRunning,
          isFalse,
          reason: 'B3：provider 全部 dispose ⇒ 定时器必须一起取消',
        );
        expect(
          Reconnector.instance.pendingTargetCount,
          0,
          reason:
              '**非 flush 期**的 unregister 必须真的清登记表：'
              '`if (_flushing) return;` 那道短路的用意是「flush 中途连环 '
              'onDispose 不许判停」，绝不能让「全部 dispose 也不停」成立',
        );

        final probes = pool.reconnectProbes;
        async.elapse(const Duration(seconds: 60));
        expect(pool.reconnectProbes, probes);
      });
    });

    test('失联档失败只探测、不扇出：fetchCalls 一次都不增、reconnectProbes 按 10s 递增', () {
      fakeAsync((async) {
        final scenario = _Scenario(fail: true);
        final pool = _FakePool(<ServerAddress>[_addr(ServerAddressStatus.ok)])
          ..markSessionEverConnected();
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.ok),
          pool: pool,
        );
        addTearDown(container.dispose);

        final subs = <ProviderSubscription<AsyncValue<String>>>[];
        for (var i = 0; i < 8; i++) {
          subs.add(container.listen(_familyProbeProvider(i), (_, _) {}));
        }
        addTearDown(() {
          for (final s in subs) {
            s.close();
          }
        });

        async.flushMicrotasks();
        expect(scenario.fetchCalls, 8, reason: '8 个区块各失败一次');
        expect(Reconnector.instance.tier, 'disconnect');
        expect(Reconnector.instance.pendingTargetCount, 8);

        // 第 1 个 tick：只打一次 /ping，**一个业务请求都不许重发**。
        async.elapse(const Duration(seconds: 10));
        async.elapse(const Duration(milliseconds: 1));
        expect(pool.reconnectProbes, 1, reason: '10s 到点先探测');
        expect(
          scenario.fetchCalls,
          8,
          reason:
              '失败扇出是自我节流：6 个区块 × 3 次重试 = 18 个请求挤进 ~3 秒，'
              '12 次/10s 的令牌桶立刻见底；更糟的是服务器真回来那一刻桶已空，'
              '`_flushAll()` 反被限流 —— 在最该快的时候慢。所以失败时只探测、不扇出。',
        );

        // 第 2、3 个 tick 同理：探测照旧 10s 一次，业务请求仍是 0。
        async.elapse(const Duration(seconds: 10));
        async.elapse(const Duration(milliseconds: 1));
        async.elapse(const Duration(seconds: 10));
        async.elapse(const Duration(milliseconds: 1));
        expect(
          pool.reconnectProbes,
          3,
          reason: '10s/20s/30s 各一次；失联档无总时限（越过冷启动档的 30s 窗口仍在跑）',
        );
        expect(
          scenario.fetchCalls,
          8,
          reason:
              '三轮 tick 之后业务扇出依然为 0：「每 10 秒自动重连」指的是探测，'
              '不是「每 10 秒重拉 8 个区块」',
        );
        expect(Reconnector.instance.isRunning, isTrue);
        expect(
          Reconnector.instance.pendingTargetCount,
          8,
          reason: '区块照旧挂着等成功那一刻统一全刷（`_flushAll` 只在成功时跑一次）',
        );
      });
    });
  });

  group('闸不放大探测', () {
    test('首屏十几个区块同时建 → 共用同一轮探测（probeAll 只踢一次）', () {
      fakeAsync((async) {
        final scenario = _Scenario();
        final pool = _FakePool(<ServerAddress>[
          _addr(ServerAddressStatus.unknown),
        ])..hold = Completer<void>();
        final container = _container(
          scenario: scenario,
          active: _addr(ServerAddressStatus.unknown),
          pool: pool,
        );
        addTearDown(container.dispose);

        // 同一个事件循环内建 12 个区块（等价于首屏一批请求同时到达）。
        final subs = <ProviderSubscription<AsyncValue<String>>>[];
        for (var i = 0; i < 12; i++) {
          subs.add(container.listen(_familyProbeProvider(i), (_, _) {}));
        }
        addTearDown(() {
          for (final s in subs) {
            s.close();
          }
        });

        async.flushMicrotasks();
        expect(
          pool.probeAllCalls,
          1,
          reason: '不做 in-flight 复用会变成「12 个区块 12 轮全量探测」的探测风暴',
        );
        expect(scenario.fetchCalls, 0);
      });
    });
  });
}
