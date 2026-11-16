// b54a —— 播放器宿主对「首次真实连通」事件的接线测试（驱动真实 PlayerNotifier）。
//
// 覆盖两点（重恢复的 once / 代际 / 用户操作保护守卫由
// b54a_reconnect_restore_test.dart 独立钉死，这里只证明「接线」本身）：
//   W1 AddressPool 首连事件触发一次 persister.restoreServerSnapshotAfterReconnect；
//   W2 容器拆卸后回调被摘除干净（不留悬空监听）。
//
// 存储环境 / 平台伪装沿袭 session_teardown_test：JsonFileStore 注入独立临时
// 目录；linux 平台让 _init() 走「桌面 = 不起 AudioService」分支。
// FLUTTER_TEST 下 castPeerController.fetchLocalQueueForRestore 入口短路返回
// null，因此 W1 只断言「入口被触发一次」（debugReconnectRestoreCalls），
// 不断言快照采用 —— 那是 persister 单测的职责。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 地址池替身：空池（未配置服务器等价态），只借真实的
/// 「首连监听表 + markSessionEverConnected + notifyForTest」机制。
class _WiringPool extends AddressPool {
  _WiringPool() : super(Dio());

  @override
  List<ServerAddress> get addresses => const <ServerAddress>[];
}

/// 轮询等待（真实定时器；plain `test` 不走 fakeAsync，安全）。
Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration budget = const Duration(seconds: 3),
  String reason = 'condition not met in time',
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason);
}

/// 等 PlayerNotifier「安静下来」（会话恢复不再进行且持续安静），同
/// session_teardown_test 的姿势（恢复起步有若干 await，不能拿瞬时 false 当已结束）。
Future<void> _quiet(
  PlayerNotifier notifier, {
  Duration quiet = const Duration(milliseconds: 300),
  Duration budget = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(budget);
  var quietSince = DateTime.now();
  while (DateTime.now().isBefore(deadline)) {
    if (notifier.debugIsRestoringPlaybackSession) {
      quietSince = DateTime.now();
    } else if (DateTime.now().difference(quietSince) >= quiet) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('PlayerNotifier 在预算内没有安静下来（构造期恢复疑似挂住）');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('W1 首连事件触发一次重恢复入口；W2 拆卸后回调摘除干净', () async {
    final dir = Directory.systemTemp.createTempSync('b54a_wiring');
    JsonFileStore.instance.debugDirectory = dir;
    final pool = _WiringPool();
    final container = ProviderContainer(
      overrides: <Override>[
        addressPoolProvider.overrideWithValue(pool),
      ],
    );
    final notifier = container.read(playerProvider.notifier);

    try {
      await _quiet(notifier);
      expect(
        notifier.sessionPersister.debugReconnectRestoreCalls,
        0,
        reason: '未连通前不得触发重恢复',
      );

      // 模拟「首次真实探测往返成功」：置位 + 广播（真机由
      // _applyProbeResult 成功分支完成这两步）。
      pool.markSessionEverConnected();
      pool.notifySessionEverConnectedForTest();

      await _waitUntil(
        () async => notifier.sessionPersister.debugReconnectRestoreCalls == 1,
        reason: '首连事件必须触发恰好一次重恢复入口',
      );
      expect(
        notifier.sessionPersister.debugReconnectRestoreCalls,
        1,
        reason: '首次连通只触发一次（事件源本身只广播一次）',
      );

      // W2：容器拆卸后回调必须摘干净（ref.onDispose 摘除）。
      await notifier
          .persistPlaybackStateNow()
          .timeout(const Duration(seconds: 3));
    } finally {
      JsonFileStore.instance.debugDirectory = null;
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }

    expect(
      pool.debugSessionEverConnectedListenerCount,
      0,
      reason: '容器拆卸后首连回调必须摘除干净',
    );
  });
}
