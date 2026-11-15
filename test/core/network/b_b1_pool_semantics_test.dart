// 批 B1 · 语义收口（判据统一 / suspect 化 / active 不清空 / toast 测试基建）。
//
// 钉住四组语义：
//   T1 「有没有备线」只有一份实现 `AddressPool.hasHealthyBackup`，
//      判死（markFailed）与重试预算（FallbackInterceptor）共用它；
//   T2a 换线路探测失败只降级为 suspect(`unknown`)，**不写 failed**，
//      且探测失败时**不切换**活跃地址；
//   T2b `probeAll` 找不到可用地址时**保留**原活跃地址（不清 null），
//      否则 `isOfflineProvider` 会把「真挂了」漏判成在线；
//   T3 `NetworkErrorNotifier.resetForTest()` 清掉 20s 节流，让
//      「不该弹 toast」这类断言不会因为前置用例弹过而假绿。
//
// 全部用自定义 HttpClientAdapter 打桩，不发真网络。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';

/// 可编程探测适配器：只用来回答 `/rest/ping` 的 HEAD。
///
/// `ok == false` 时刻意**抛异常**而不是返回 5xx —— 这样 `probeAddress`
/// 走 catch 分支返回 failed，且 `_applyProbeResult` 会把它当作「一次失败」
/// 去走宽容计数，正是 suspect 化要观测的那条路径。
class _ProbeAdapter implements HttpClientAdapter {
  /// 置 false 后所有探测都失败（走 `probeAddress` 的 catch 分支）。
  bool ok = true;
  int headCount = 0;
  final List<String> requested = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    headCount++;
    requested.add('${options.method} ${options.uri}');
    if (!ok) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: Exception('probe down'),
      );
    }
    return ResponseBody.fromString(
      '',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }
}

ServerAddress _addr(
  String id, {
  ServerAddressStatus status = ServerAddressStatus.unknown,
  bool isLocked = false,
  int priority = 0,
}) =>
    ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: id,
      url: 'https://$id.example.com',
      priority: priority,
      isLocked: isLocked,
      status: status,
    );

/// 复刻 `isOfflineProvider` 的真实判据（不 mock 掉被测逻辑）。
Future<bool> _offline({
  required ServerAddress? active,
  NetworkType type = NetworkType.wifi,
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      currentNetworkTypeProvider.overrideWith(
        (ref) => Stream<NetworkType>.value(type),
      ),
      activeAddressProvider.overrideWith((ref) => active),
    ],
  );
  addTearDown(container.dispose);
  // 必须先等 StreamProvider 发出首值：否则同步读拿到 loading，valueOrNull
  // 为 null，`??` 会回落到真实 connectivityMonitorProvider（测试环境恒为
  // none → 恒判离线），断言就没有区分力了。
  await container.read(currentNetworkTypeProvider.future);
  return container.read(isOfflineProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late _ProbeAdapter adapter;

  setUp(() {
    dio = Dio();
    adapter = _ProbeAdapter();
    dio.httpClientAdapter = adapter;    NetworkErrorNotifier.resetForTest();
  });

  tearDown(NetworkErrorNotifier.resetForTest);

  group('T1 hasHealthyBackup —— 「有没有备线」的唯一判据', () {
    test('单地址（ok）→ 排除它自己后无备线 → false', () async {
      final pool = AddressPool(dio);
      pool.setAddresses([_addr('a', status: ServerAddressStatus.ok)]);
      // 同步断言：setAddresses 触发的探测还在微任务里，状态未被改写。
      expect(pool.hasHealthyBackup(excludeId: 'a'), isFalse);
      expect(pool.hasHealthyBackup(), isTrue, reason: '不排除时自身即是一条');
      await pumpEventQueue();
    });

    test('a.ok + b.ok → 排除 a 后仍有 b → true', () async {
      final pool = AddressPool(dio);
      pool.setAddresses([
        _addr('a', status: ServerAddressStatus.ok, priority: 0),
        _addr('b', status: ServerAddressStatus.ok, priority: 1),
      ]);
      expect(pool.hasHealthyBackup(excludeId: 'a'), isTrue);
      await pumpEventQueue();
    });

    test('a.ok + b.failed → 无备线 → **false**（双标就是在这里被消掉的）',
        () async {
      final pool = AddressPool(dio);
      pool.setAddresses([
        _addr('a', status: ServerAddressStatus.ok, priority: 0),
        _addr('b', status: ServerAddressStatus.failed, priority: 1),
      ]);
      expect(
        pool.hasHealthyBackup(excludeId: 'a'),
        isFalse,
        reason: 'failed 的地址不是可信去处；判死侧曾把它当备线，导致'
            '「重试判无备线 · 判死判有备线」',
      );
      await pumpEventQueue();
    });

    test('a.ok + b.ok(locked) → 锁定不算备线 → false', () async {
      final pool = AddressPool(dio);
      pool.setAddresses([
        _addr('a', status: ServerAddressStatus.ok, priority: 0),
        _addr(
          'b',
          status: ServerAddressStatus.ok,
          isLocked: true,
          priority: 1,
        ),
      ]);
      expect(pool.hasHealthyBackup(excludeId: 'a'), isFalse);
      await pumpEventQueue();
    });
  });

  group('T1 markFailed 判死口径与 hasHealthyBackup 一致', () {
    test('a.ok + b.failed → markFailed(a) 不判死、不持久化', () async {
      // 探测一律失败，否则 setAddresses 的后台探测会把 b 从 failed 抬回 ok，
      // 用例就不再处于「1 ok + 1 failed」这个被测形态了。
      adapter.ok = false;
      final updated = <ServerAddress>[];
      final pool = AddressPool(dio, onAddressUpdated: updated.add);

      pool.setAddresses([
        _addr('a', status: ServerAddressStatus.ok, priority: 0),
        _addr('b', status: ServerAddressStatus.failed, priority: 1),
      ]);
      // 排空 setAddresses 触发的后台探测，避免它往 updated 里追加。
      await pumpEventQueue();
      updated.clear();

      pool.markFailed(_addr('a'));

      expect(
        pool.addresses.firstWhere((x) => x.id == 'a').status,
        ServerAddressStatus.ok,
        reason: '没有可信备线时判死只会把唯一健康地址从候选里剔除',
      );
      expect(
        updated,
        isEmpty,
        reason: '不判死就不该持久化 failed（否则下次冷启动恢复不出活跃地址）',
      );
    });

    test('a.ok + b.ok → markFailed(a) 照旧判死并持久化一次（批 A 语义保留）',
        () async {
      final updated = <ServerAddress>[];
      final pool = AddressPool(dio, onAddressUpdated: updated.add);

      pool.setAddresses([
        _addr('a', status: ServerAddressStatus.ok, priority: 0),
        _addr('b', status: ServerAddressStatus.ok, priority: 1),
      ]);
      await pumpEventQueue();
      updated.clear();

      pool.markFailed(_addr('a'));

      expect(
        pool.addresses.firstWhere((x) => x.id == 'a').status,
        ServerAddressStatus.failed,
      );
      expect(updated.length, 1);
      expect(updated.single.id, 'a');
    });
  });

  group('T2a 换线路探测失败 → suspect 而非 failed', () {
    test('双地址切 b 失败 → b 是 unknown、active 仍是 a、不判离线、不回调',
        () async {
      adapter.ok = false; // 探测一律失败
      final activeChanges = <ServerAddress?>[];
      final updated = <ServerAddress>[];
      final pool = AddressPool(
        dio,
        onActiveAddressChanged: activeChanges.add,
        onAddressUpdated: updated.add,
      );

      pool.setAddresses([
        _addr('a', status: ServerAddressStatus.ok, priority: 0),
        _addr('b', status: ServerAddressStatus.failed, priority: 1),
      ]);
      await pumpEventQueue();
      expect(pool.activeAddress?.id, 'a');
      activeChanges.clear();
      updated.clear();

      final switched = await pool.switchTo(
        pool.addresses.firstWhere((x) => x.id == 'b'),
        manual: false,
      );

      expect(switched, isFalse, reason: '探测没通过就不算切换成功');
      final b = pool.addresses.firstWhere((x) => x.id == 'b');
      expect(
        b.status,
        ServerAddressStatus.unknown,
        reason: '候选探测失败只降级为 suspect(unknown)，写 failed 会让全 App 判离线',
      );
      expect(
        pool.activeAddress?.id,
        'a',
        reason: '探测失败必须保持原活跃地址不动（旧实现会把它设成没通过探测的 b）',
      );
      expect(activeChanges, isEmpty, reason: '活跃地址没变就不该回调');

      expect(
        await _offline(active: pool.activeAddress),
        isFalse,
        reason: '一次切线路探测失败不得被判成离线（封面/播放/遥控会一起降级）',
      );
    });

    test('反向对照：同一条链路下 status 真的是 failed 时必须判离线', () async {
      // 没有这一条，上面的 isFalse 可能只是断言写坏了（假绿）。
      expect(
        await _offline(
          active: _addr('x', status: ServerAddressStatus.failed),
        ),
        isTrue,
      );
    });
  });

  group('T2b probeAll 找不到可用地址时保留活跃地址', () {
    test('单地址连续 2 次探测失败 → failed、active 非 null、判离线', () async {
      adapter.ok = false;
      final pool = AddressPool(dio);
      pool.setAddresses([_addr('only', status: ServerAddressStatus.ok)]);
      expect(pool.activeAddress?.id, 'only');

      await pool.probeAll(); // 失败第 1 次：宽容，仍 ok
      expect(pool.activeAddress?.status, ServerAddressStatus.ok);
      await pool.probeAll(); // 失败第 2 次：达阈值 → failed
      await pumpEventQueue();

      expect(pool.addresses.single.status, ServerAddressStatus.failed);
      expect(
        pool.activeAddress,
        isNotNull,
        reason: '真挂了也要留住这条活跃地址：它的 failed 状态是离线判定的唯一依据',
      );
      expect(pool.activeAddress?.id, 'only');
      expect(
        await _offline(active: pool.activeAddress),
        isTrue,
        reason: '正例：服务端真的不可达时必须判离线，播放器才会走本地缓存',
      );
    });

    test('全 unknown（首装）→ 不判离线', () async {
      expect(
        await _offline(active: _addr('x')),
        isFalse,
        reason: '没探测过不等于离线，否则首装就禁用播放',
      );
    });

    test('netType == none → 判离线（物理断网优先）', () async {
      expect(
        await _offline(
          active: _addr('x', status: ServerAddressStatus.ok),
          type: NetworkType.none,
        ),
        isTrue,
      );
    });
  });

  group('T3 NetworkErrorNotifier.resetForTest', () {
    testWidgets('同一文件连续两次都能弹（20s 节流被 reset 清掉）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          // MusicFlowMessage 读 AppLocalizations.of(context)!，必须带 delegate。
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      NetworkErrorNotifier.resetForTest();
      NetworkErrorNotifier.show('first-toast');
      await tester.pump();
      expect(
        find.text('first-toast'),
        findsOneWidget,
        reason: 'reset 后应立刻可弹（_startedAt 已清空，不进 30s 宽限期）',
      );

      // 关键：不推进时间就再弹一次。没有 resetForTest 的话，`_lastShownAt`
      // 的 20s 节流会把这一次静默吞掉 —— 于是所有「不该弹 toast」的断言都假绿。
      NetworkErrorNotifier.resetForTest();
      NetworkErrorNotifier.show('second-toast');
      await tester.pump();
      expect(
        find.text('second-toast'),
        findsOneWidget,
        reason: 'resetForTest 必须清掉 _lastShownAt，否则 20s 内第二次被节流',
      );

      // 排空 toast 的自动消失计时器，避免 pending timer 判红。
      await tester.pump(const Duration(seconds: 31));
    });
  });
}
