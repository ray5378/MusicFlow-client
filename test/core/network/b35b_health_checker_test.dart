// b35b: health_checker.dart 补测(逻辑层收尾批)。
// 产品代码零改动。mocktail Mock AddressPool + FakeAsync 推进 Timer.periodic,
// 覆盖: 活跃地址健康/不健康恢复、手动模式+关闭自动回退跳过、手动模式不回退、
// 更高优先级地址提升、无活跃地址触发 probeAll、周期探测持续运行、stop 清理。


import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/health_checker.dart';
import 'package:musicflow_client/data/models/server_address.dart';

class MockAddressPool extends Mock implements AddressPool {}

ServerAddress _addr(
  String id, {
  int priority = 0,
  ServerAddressStatus status = ServerAddressStatus.unknown,
  bool isLocked = false,
}) {
  return ServerAddress(
    id: id,
    libraryId: 'lib-1',
    label: 'addr-$id',
    url: 'http://$id.example.com',
    priority: priority,
    status: status,
    isLocked: isLocked,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(_addr('fallback'));
  });

  late MockAddressPool pool;
  late HealthChecker checker;

  ServerAddress? active;
  late ServerAddress probed;
  ServerAddress? next;
  bool manualMode = false;
  bool autoFallback = true;
  List<ServerAddress> poolAddresses = const [];

  void stubPool() {
    when(() => pool.activeAddress).thenReturn(active);
    when(() => pool.probeAddress(any())).thenAnswer((_) async => probed);
    when(() => pool.updateProbedAddress(any())).thenReturn(null);
    when(() => pool.isManualMode).thenReturn(manualMode);
    when(() => pool.autoFallback).thenReturn(autoFallback);
    when(() => pool.getNextAvailable()).thenReturn(next);
    when(() => pool.switchTo(any(), manual: any(named: 'manual')))
        .thenAnswer((_) async => true);
    when(() => pool.addresses).thenReturn(poolAddresses);
    when(() => pool.probeAll()).thenAnswer((_) async => null);
  }

  /// 启动并跑过首轮探测(初始 _check 是异步的,elapse 让微任务落地)。
  void runInFake(void Function(FakeAsync _) body) {
    fakeAsync((async) {
      stubPool();
      checker.start();
      async.elapse(const Duration(milliseconds: 10));
      body(async);
    });
  }

  setUp(() {
    pool = MockAddressPool();
    checker = HealthChecker(pool);
    active = _addr('a1', priority: 1);
    probed = _addr('a1', priority: 1, status: ServerAddressStatus.ok);
    next = null;
    manualMode = false;
    autoFallback = true;
    poolAddresses = [active!];
  });

  test('活跃地址健康: 更新探测结果、取消待确认错误、不切换', () {
    runInFake((async) {
      verify(() => pool.probeAddress(any())).called(1);
      verify(() => pool.updateProbedAddress(probed)).called(1);
      verifyNever(() => pool.getNextAvailable());
      verifyNever(() => pool.switchTo(any(), manual: any(named: 'manual')));
    });
  });

  test('活跃地址健康且手动模式: 不自动回退到更高优先级', () {
    manualMode = true;
    poolAddresses = [_addr('a0', priority: 0), active!];
    runInFake((async) {
      // 手动模式直接 return:连 best 探测都不发起。
      verifyNever(() => pool.probeAddress(
          any(that: isNot(equals(active)))));
      verifyNever(() => pool.switchTo(any(), manual: any(named: 'manual')));
    });
  });

  test('非手动且当前非最高优先级: 更优地址健康 → 自动提升切换', () {
    final best = _addr('a0', priority: 0, status: ServerAddressStatus.ok);
    poolAddresses = [best, active!];
    fakeAsync((async) {
      stubPool();
      // 对 best 地址的探测返回健康(同一实例,便于值相等断言)。
      when(() => pool.probeAddress(best)).thenAnswer((_) async => best);
      checker.start();
      async.elapse(const Duration(milliseconds: 10));

      verify(() => pool.switchTo(
            any(that: equals(best)),
            manual: false,
          )).called(1);
    });
  });

  test('非手动且当前非最高优先级: 更优地址探测失败 → 不切换', () {
    final best = _addr('a0', priority: 0);
    poolAddresses = [best, active!];
    fakeAsync((async) {
      stubPool();
      when(() => pool.probeAddress(best)).thenAnswer(
          (_) async => _addr('a0', priority: 0, status: ServerAddressStatus.failed));
      checker.start();
      async.elapse(const Duration(milliseconds: 10));

      verifyNever(() => pool.switchTo(any(), manual: any(named: 'manual')));
    });
  });

  test('活跃地址不健康 + 手动模式关闭自动回退: 跳过恢复', () {
    manualMode = true;
    autoFallback = false;
    probed = _addr('a1', priority: 1, status: ServerAddressStatus.failed);
    runInFake((async) {
      verifyNever(() => pool.getNextAvailable());
      verifyNever(() => pool.switchTo(any(), manual: any(named: 'manual')));
    });
  });

  test('活跃地址不健康: 切换到下一个可用地址(manual:false)', () {
    final fallback = _addr('a2', priority: 2);
    next = fallback;
    probed = _addr('a1', priority: 1, status: ServerAddressStatus.failed);
    runInFake((async) {
      verify(() => pool.switchTo(
            any(that: equals(fallback)),
            manual: false,
          )).called(1);
    });
  });

  test('活跃地址不健康且无可用备选(next 为 null): 不切换', () {
    next = null;
    probed = _addr('a1', priority: 1, status: ServerAddressStatus.failed);
    runInFake((async) {
      verifyNever(() => pool.switchTo(any(), manual: any(named: 'manual')));
    });
  });

  test('活跃地址不健康且备选就是当前地址: 不重复切换', () {
    next = _addr('a1', priority: 1);
    probed = _addr('a1', priority: 1, status: ServerAddressStatus.failed);
    runInFake((async) {
      verifyNever(() => pool.switchTo(any(), manual: any(named: 'manual')));
    });
  });

  test('无活跃地址: 触发 probeAll,不探测单地址', () {
    active = null;
    runInFake((async) {
      verify(() => pool.probeAll()).called(1);
      verifyNever(() => pool.probeAddress(any()));
    });
  });

  test('Timer.periodic 持续探测: 65 秒内初始 1 次 + 周期 2 次', () {
    fakeAsync((async) {
      stubPool();
      checker.start();
      async.elapse(const Duration(seconds: 65));
      // start 时的 initial check + 30s/60s 两个周期 tick。
      verify(() => pool.probeAddress(any())).called(3);
    });
  });

  test('stop 后不再周期探测', () {
    fakeAsync((async) {
      stubPool();
      checker.start();
      async.elapse(const Duration(milliseconds: 10));
      checker.stop();
      async.elapse(const Duration(seconds: 70));
      // 只有 initial check 一次。
      verify(() => pool.probeAddress(any())).called(1);
    });
  });

  test('start 幂等: 重复 start 先 cancel 旧定时器,不叠加周期', () {
    fakeAsync((async) {
      stubPool();
      checker.start();
      async.elapse(const Duration(milliseconds: 10));
      checker.start(); // 重新开始,旧 timer 被取消
      async.elapse(const Duration(seconds: 65));
      // 第一个实例:initial(1);第二个实例:initial(1) + 30s/60s(2) = 4。
      verify(() => pool.probeAddress(any())).called(4);
    });
  });
}
