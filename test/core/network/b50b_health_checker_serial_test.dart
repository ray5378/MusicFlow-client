// b50b —— HealthChecker 串行化回归（P2）。
//
// 缺陷：`Timer.periodic(30s, (_) => _check())` 不 await，慢网下单轮探测（最坏
// 10s+）与下一轮 tick 重叠 → 并发 probeAll / switchTo，状态竞态。
// 修复：`_checking` 护栏，上一轮未结束则跳过本 tick。
//
// 打法：mocktail Mock AddressPool + FakeAsync；用 Completer 门控首轮探测，
// 证明「挂起期间周期 tick 被跳过」「一轮结束后恢复执行」。
import 'dart:async';

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
}) =>
    ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: 'addr-$id',
      url: 'http://$id.example.com',
      priority: priority,
      status: status,
    );

void main() {
  setUpAll(() {
    registerFallbackValue(_addr('fallback'));
  });

  late MockAddressPool pool;
  late HealthChecker checker;
  final active = _addr('a1');

  setUp(() {
    pool = MockAddressPool();
    checker = HealthChecker(pool);
    when(() => pool.activeAddress).thenReturn(active);
    when(() => pool.updateProbedAddress(any())).thenReturn(null);
    when(() => pool.isManualMode).thenReturn(false);
    when(() => pool.autoFallback).thenReturn(true);
    when(() => pool.addresses).thenReturn(<ServerAddress>[active]);
  });

  test('上一轮探测未结束时跳过周期 tick（串行化，防重叠）', () {
    fakeAsync((async) {
      var probes = 0;
      final gate = Completer<ServerAddress>();
      when(() => pool.probeAddress(any())).thenAnswer((_) {
        probes++;
        return gate.future;
      });

      checker.start();
      async.elapse(const Duration(milliseconds: 10));
      expect(probes, 1);

      // 65s 内两个周期 tick：首轮仍挂起 → 全部跳过，探测数不变。
      async.elapse(const Duration(seconds: 65));
      expect(probes, 1, reason: '首轮未结束，两个周期 tick 应被跳过');

      // 放行首轮；此时已无待处理 tick，探测数仍为 1。
      gate.complete(_addr('a1', status: ServerAddressStatus.ok));
      async.elapse(const Duration(milliseconds: 10));
      expect(probes, 1);
    });
  });

  test('一轮探测结束后下一周期恢复执行', () {
    fakeAsync((async) {
      var calls = 0;
      when(() => pool.probeAddress(any())).thenAnswer((_) async {
        calls++;
        return _addr('a1', status: ServerAddressStatus.ok);
      });

      checker.start();
      async.elapse(const Duration(seconds: 65));
      // 初始 1 次 + 30s / 60s 周期各 1 次 = 3。
      expect(calls, 3);
    });
  });
}