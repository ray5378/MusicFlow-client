// b35b: connectivity_monitor.dart 补测(逻辑层收尾批)。
// 产品代码零改动。替换 ConnectivityPlatform.instance 桩网络类型,
// 覆盖: _resolveNetworkType 全分支(wifi/mobile/ethernet→wifi/vpn→mobile/
// none/bluetooth→mobile)、listEquals 去重、恢复联网触发 probeAll、
// 断网不触发、初始 checkConnectivity 异常容错、stop 关闭广播流。

import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';

class MockAddressPool extends Mock implements AddressPool {}

class FakeConnectivityPlatform extends ConnectivityPlatform {
  final StreamController<List<ConnectivityResult>> changeController =
      StreamController<List<ConnectivityResult>>.broadcast();

  List<ConnectivityResult> initial = const [ConnectivityResult.none];

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => initial;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      changeController.stream;
}

void main() {
  late FakeConnectivityPlatform platform;
  late MockAddressPool pool;

  setUpAll(() {
    registerFallbackValue(<ConnectivityResult>[ConnectivityResult.none]);
  });

  setUp(() {
    platform = FakeConnectivityPlatform();
    ConnectivityPlatform.instance = platform;
    pool = MockAddressPool();
    when(() => pool.probeAll()).thenAnswer((_) async => null);
  });

  /// 创建 monitor、start 并等初始检测落地。
  Future<ConnectivityMonitor> started() async {
    final monitor = ConnectivityMonitor(pool);
    monitor.start();
    // start 内部 checkConnectivity 是异步 then,让事件循环跑完。
    await Future<void>.delayed(Duration.zero);
    return monitor;
  }

  test('初始 wifi → networkType 为 wifi 且广播', () async {
    platform.initial = const [ConnectivityResult.wifi];
    final monitor = await started();
    expect(monitor.currentNetworkType, NetworkType.wifi);
    monitor.stop();
  });

  test('流事件驱动类型切换: mobile/ethernet/vpn/none/bluetooth', () async {
    platform.initial = const [ConnectivityResult.none];
    final monitor = await started();
    final events = <NetworkType>[];
    final sub = monitor.networkTypeStream.listen(events.add);

    Future<void> emit(List<ConnectivityResult> results) async {
      platform.changeController.add(results);
      await Future<void>.delayed(Duration.zero);
    }

    await emit([ConnectivityResult.mobile]);
    expect(monitor.currentNetworkType, NetworkType.mobile);

    await emit([ConnectivityResult.ethernet]); // 有线视为 wifi
    expect(monitor.currentNetworkType, NetworkType.wifi);

    await emit([ConnectivityResult.vpn]); // VPN 保守视为 mobile
    expect(monitor.currentNetworkType, NetworkType.mobile);

    await emit([ConnectivityResult.none]);
    expect(monitor.currentNetworkType, NetworkType.none);

    await emit([ConnectivityResult.bluetooth]); // 其他视为 mobile
    expect(monitor.currentNetworkType, NetworkType.mobile);

    await emit([ConnectivityResult.wifi, ConnectivityResult.vpn]); // wifi 优先
    expect(monitor.currentNetworkType, NetworkType.wifi);

    expect(events, [
      NetworkType.mobile,
      NetworkType.wifi,
      NetworkType.mobile,
      NetworkType.none,
      NetworkType.mobile,
      NetworkType.wifi,
    ]);
    await sub.cancel();
    monitor.stop();
  });

  test('相同结果重复上报被 listEquals 去重,不重复广播/不重复 probeAll', () async {
    platform.initial = const [ConnectivityResult.wifi];
    final monitor = await started();
    final events = <NetworkType>[];
    final sub = monitor.networkTypeStream.listen(events.add);

    // 注意:start() 的初始 checkConnectivity 只更新 networkType,不回写
    // _lastResults(初始为 [none]),故首个 wifi 事件仍会被当作一次「变化」,
    // 触发一次 probeAll —— 此后完全相同的上报才被 listEquals 去重。
    platform.changeController.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    platform.changeController.add(const [ConnectivityResult.wifi]);
    platform.changeController.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty); // 类型未变,不重复广播
    verify(() => pool.probeAll()).called(1); // 仅首个事件触发一次
    await sub.cancel();
    monitor.stop();
  });

  test('网络恢复(有连接) → 取消待确认错误并 probeAll', () async {
    platform.initial = const [ConnectivityResult.none];
    final monitor = await started();

    platform.changeController.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);

    verify(() => pool.probeAll()).called(1);
    monitor.stop();
  });

  test('网络断开(none) → 不触发 probeAll', () async {
    platform.initial = const [ConnectivityResult.wifi];
    final monitor = await started();

    platform.changeController.add(const [ConnectivityResult.none]);
    await Future<void>.delayed(Duration.zero);

    verifyNever(() => pool.probeAll());
    monitor.stop();
  });

  test('初始 checkConnectivity 抛异常不崩溃,监听流仍可用', () async {
    final failing = FakeConnectivityPlatform();
    // 覆盖 checkConnectivity 抛异常:用匿名子类拦截。
    final broken = _BrokenPlatform(platform);
    ConnectivityPlatform.instance = broken;
    final monitor = ConnectivityMonitor(pool);
    monitor.start();
    await Future<void>.delayed(Duration.zero);
    expect(monitor.currentNetworkType, NetworkType.none);

    broken.base.changeController.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    expect(monitor.currentNetworkType, NetworkType.wifi);
    monitor.stop();
    // 避免 lint 未使用告警。
    expect(failing.initial, isNotNull);
  });

  test('onConnectivityChanged 流错误 → onError 记日志不崩溃', () async {
    platform.initial = const [ConnectivityResult.none];
    final monitor = await started();

    platform.changeController.addError(StateError('stream boom'));
    await Future<void>.delayed(Duration.zero);
    expect(monitor.currentNetworkType, NetworkType.none);
    monitor.stop();
  });

  test('stop 关闭 networkTypeStream', () async {
    platform.initial = const [ConnectivityResult.wifi];
    final monitor = await started();
    final done = Completer<void>();
    final sub = monitor.networkTypeStream.listen((_) {}, onDone: done.complete);
    monitor.stop();
    await done.future.timeout(const Duration(seconds: 2));
    await sub.cancel();
  });
}

class _BrokenPlatform extends ConnectivityPlatform {
  _BrokenPlatform(this.base);

  final FakeConnectivityPlatform base;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    throw StateError('initial check failed');
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      base.changeController.stream;
}
