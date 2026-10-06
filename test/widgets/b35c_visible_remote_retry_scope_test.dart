// batch35 C 路 —— `lib/widgets/visible_remote_retry_scope.dart` 补测。
//
// 覆盖点：
//   * 网络类型变化（wifi↔mobile）且页面可见 → onRetry 触发；
//   * 变为 none / 同类型重复广播 → 不触发；
//   * shouldRetry=false → 不触发；
//   * branchIndex 与 currentVisibleBranchIndexProvider 不匹配 → 不触发，匹配后触发；
//   * onRetry 抛异常被吞且 _retryInProgress 复位（后续变化可再次重试）；
//   * onRetry 进行中再次网络变化 → 不并发重试；
//   * 网络流 error → 不崩；
//   * dispose 取消订阅（卸载后 emit 不再触发）；
//   * 被 opaque 路由盖住（ModalRoute.isCurrent=false）→ 不重试，pop 回来后恢复。
//
// 踩坑记录：
// #R1 ConnectivityMonitor 是具体类，桩用 implements（只实现 4 个公共成员），
//     自持 StreamController 广播网络类型；connectivityMonitorProvider 直接
//     overrideWithValue，绕开 AddressPool/Dio。
// #R2 _retryIfNeeded 是 async，emit 后需要 pump 推 microtask；onRetry 挂起用
//     Completer 控制，complete 后再 pump。
// #R3 ModalRoute 不可见分支：用 Navigator.push 一个 opaque 路由盖住。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';
import 'package:musicflow_client/widgets/visible_remote_retry_scope.dart';

class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({this.currentNetworkType = NetworkType.none});

  final StreamController<NetworkType> _controller =
      StreamController<NetworkType>.broadcast();

  @override
  NetworkType currentNetworkType;

  @override
  Stream<NetworkType> get networkTypeStream => _controller.stream;

  @override
  void start() {}

  @override
  void stop() {}

  void emit(NetworkType type) {
    currentNetworkType = type;
    _controller.add(type);
  }

  void emitError(Object error) => _controller.addError(error);

  Future<void> dispose() => _controller.close();
}

class _Harness {
  _Harness({this.branchIndex});

  final int? branchIndex;
  final FakeConnectivityMonitor monitor = FakeConnectivityMonitor();
  final List<int> retryCalls = <int>[];
  final List<Completer<void>> pendingRetries = <Completer<void>>[];
  bool shouldRetryValue = true;

  late ProviderContainer container;

  Widget build() {
    container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(monitor),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: VisibleRemoteRetryScope(
            debugLabel: 'b35c-test',
            branchIndex: branchIndex,
            shouldRetry: (_) => shouldRetryValue,
            onRetry: (_) async {
              retryCalls.add(retryCalls.length);
              final completer = Completer<void>();
              pendingRetries.add(completer);
              await completer.future;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  void setBranch(int value) {
    container.read(currentVisibleBranchIndexProvider.notifier).state = value;
  }
}

Future<void> settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  tearDown(() {});

  testWidgets('网络类型变化：wifi→mobile 触发一次重试', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.build());
    await settle(tester);

    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();

    expect(harness.retryCalls.length, 1);
  });

  testWidgets('网络变为 none：不触发重试', (tester) async {
    final harness = _Harness();
    harness.monitor.currentNetworkType = NetworkType.wifi;
    await tester.pumpWidget(harness.build());
    await settle(tester);

    harness.monitor.emit(NetworkType.none);
    await tester.pump();
    await tester.pump();

    expect(harness.retryCalls, isEmpty);
  });

  testWidgets('同类型重复广播：不触发重试', (tester) async {
    final harness = _Harness();
    harness.monitor.currentNetworkType = NetworkType.wifi;
    await tester.pumpWidget(harness.build());
    await settle(tester);

    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();

    expect(harness.retryCalls, isEmpty);
  });

  testWidgets('shouldRetry=false：网络变化不触发重试', (tester) async {
    final harness = _Harness();
    harness.shouldRetryValue = false;
    await tester.pumpWidget(harness.build());
    await settle(tester);

    harness.monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();

    expect(harness.retryCalls, isEmpty);
  });

  testWidgets('branchIndex 门禁：分支不可见不重试，可见后恢复', (tester) async {
    final harness = _Harness(branchIndex: 3);
    await tester.pumpWidget(harness.build());
    await settle(tester);

    // 当前分支索引默认 0 ≠ 3 → 不重试。
    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls, isEmpty);

    // 切到分支 3 → 重试。
    harness.setBranch(3);
    harness.monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls.length, 1);
  });

  testWidgets('onRetry 抛异常：被吞且复位，后续网络变化可再次重试', (tester) async {
    final harness = _Harness();
    // onRetry 同步抛错：pendingRetries completer 永不 complete → 这里换一种方式：
    // 让 completer.completeError。
    await tester.pumpWidget(harness.build());
    await settle(tester);

    // 第一次：触发后让 onRetry 失败。
    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    harness.pendingRetries.last.completeError(StateError('boom'));
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls.length, 1);
    expect(tester.takeException(), isNull, reason: '重试失败应被内部吞掉');

    // 复位后第二次变化仍可重试。
    harness.monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls.length, 2);
  });

  testWidgets('onRetry 进行中：再次网络变化不并发重试，完成后恢复', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.build());
    await settle(tester);

    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls.length, 1);

    // 第一次仍在挂起 → 不并发。
    harness.monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls.length, 1);

    // 完成第一次后，再来一次变化才触发。
    harness.pendingRetries.last.complete();
    await tester.pump();
    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls.length, 2);
  });

  testWidgets('网络流 error：不崩溃', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.build());
    await settle(tester);

    harness.monitor.emitError(StateError('stream broken'));
    await tester.pump();
    await tester.pump();

    expect(harness.retryCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卸载组件树：取消订阅，后续 emit 不再触发', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.build());
    await settle(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    expect(harness.retryCalls, isEmpty, reason: 'dispose 应已取消网络流订阅');
  });

  testWidgets('被 opaque 路由盖住：不重试；pop 回来后恢复', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.build());
    await settle(tester);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('第二页')),
        ),
      ),
    );
    await settle(tester, frames: 10);

    harness.monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls, isEmpty, reason: '路由非 current 时不重试');

    navigator.pop();
    await settle(tester, frames: 10);

    harness.monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    expect(harness.retryCalls.length, 1, reason: '回到当前路由后恢复重试');
  });
}
