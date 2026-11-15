import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';

class MockDio extends Mock implements Dio {
  @override
  BaseOptions get options => BaseOptions();
}

void main() {
  late MockDio dio;
  late AddressPool pool;
  var headResponse = 200;
  final updatedCallbacks = <ServerAddress>[];
  final activeCallbacks = <ServerAddress?>[];

  Response okResponse(String url) => Response(
        requestOptions: RequestOptions(path: url),
        statusCode: 200,
        data: null,
      );

  void stubHead(Future<Response> Function(String url) handler) {
    when(() => dio.head(any(), options: any(named: 'options'))).thenAnswer(
      (inv) async => handler(inv.positionalArguments[0] as String),
    );
  }

  setUp(() {
    dio = MockDio();
    headResponse = 200;
    updatedCallbacks.clear();
    activeCallbacks.clear();
    pool = AddressPool(
      dio,
      onAddressUpdated: updatedCallbacks.add,
      onActiveAddressChanged: activeCallbacks.add,
    );
    stubHead((url) async {
      if (headResponse == 200) return okResponse(url);
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: url),
          statusCode: headResponse,
        ),
      );
    });
  });

  ServerAddress addr({
    String id = 'a1',
    String label = 'Server 1',
    String url = 'https://a.example.com',
    int priority = 0,
    bool isLocked = false,
    ServerAddressStatus status = ServerAddressStatus.unknown,
  }) =>
      ServerAddress(
        id: id,
        libraryId: 'lib-1',
        label: label,
        url: url,
        priority: priority,
        isLocked: isLocked,
        status: status,
      );

  group('waitForActiveAddress', () {
    test('已有活跃地址时同步快路径立即返回', () async {
      pool.setAddresses([addr(status: ServerAddressStatus.ok)]);
      final result = await pool.waitForActiveAddress();
      expect(result?.id, 'a1');
    });

    test('无活跃地址且超时 → 返回 null 不抛异常', () async {
      final result = await pool.waitForActiveAddress(
        const Duration(milliseconds: 60),
      );
      expect(result, isNull);
    });

    test('等待中激活地址 → 立即被唤醒返回该地址', () async {
      final future = pool.waitForActiveAddress(const Duration(seconds: 2));
      pool.setAddresses([addr(status: ServerAddressStatus.ok)]);
      final result = await future;
      expect(result?.id, 'a1');
    });
  });

  group('setAddresses 恢复活跃地址', () {
    test('优先恢复手动锁定的地址', () async {
      pool.setAddresses([
        addr(id: 'locked', isLocked: true, priority: 1),
        addr(id: 'ok', status: ServerAddressStatus.ok),
      ]);
      expect(pool.activeAddress?.id, 'locked');
      expect(pool.isManualMode, isTrue);
      await pool.probeAll();
    });

    test('无锁定时恢复上次状态为 ok 的最高优先级地址', () async {
      pool.setAddresses([
        addr(id: 'b', status: ServerAddressStatus.ok, priority: 1),
        addr(id: 'a', status: ServerAddressStatus.ok, priority: 0),
      ]);
      expect(pool.activeAddress?.id, 'a');
      await pool.probeAll();
    });

    test('上次状态无可恢复地址 → 活跃地址保持 null，随后探测补上', () async {
      pool.setAddresses([addr(id: 'x')]);
      expect(pool.activeAddress, isNull);
      final active = await pool.probeAll();
      expect(active?.id, 'x');
    });

    test('空地址列表 → 不探测不恢复', () async {
      pool.setAddresses([]);
      final result = await pool.probeAll();
      expect(result, isNull);
      expect(pool.activeAddress, isNull);
    });

    test('活跃地址不在新列表中 → 重置', () async {
      pool.setAddresses([addr(id: 'old', status: ServerAddressStatus.ok)]);
      expect(pool.activeAddress?.id, 'old');
      // 新列表不含 old；old 不再是 ok 状态 → 无法恢复。
      pool.setAddresses([addr(id: 'new')]);
      // old 被移除后 active 先置 null；new 状态 unknown 无法立即恢复。
      final stillOld = pool.activeAddress;
      expect(stillOld == null || stillOld.id == 'new', isTrue);
      await pool.probeAll();
    });
  });

  group('probeAll / probeAddress', () {
    test('空列表探测返回 null', () async {
      expect(await pool.probeAll(), isNull);
    });

    test('并发探测合并为一次 in-flight（后续调用加入现有探测）', () async {
      final slow = Completer<Response>();
      stubHead((url) async {
        if (url.contains('slow')) return slow.future;
        return okResponse(url);
      });
      pool.setAddresses([
        addr(id: 'slow', url: 'https://slow.example.com'),
        addr(id: 'fast', url: 'https://fast.example.com'),
      ]);
      // setAddresses 内部已发起一次探测，后续调用应加入同一 in-flight。
      final p1 = pool.probeAll();
      await Future<void>.delayed(Duration.zero);
      final p2 = pool.probeAll();
      slow.complete(okResponse('https://slow.example.com/rest/ping'));
      // 全部探测完成后自动模式按优先级选回 slow（列表第一个）。
      expect((await p1)?.id, 'slow');
      expect((await p2)?.id, 'slow');
    });

    test('HTTP 200 → ok 并记录延迟；4xx → failed（validateStatus<500 走失败分支）',
        () async {
      // 必须先替换 stub 再 setAddresses：setAddresses 会在同步阶段发起探测。
      stubHead((url) async {
        if (url.contains('bad')) {
          return Response(
            requestOptions: RequestOptions(path: url),
            statusCode: 404,
          );
        }
        return okResponse(url);
      });
      pool.setAddresses([
        addr(id: 'good', url: 'https://good.example.com'),
        addr(id: 'bad', url: 'https://bad.example.com'),
      ]);
      await pool.probeAll();
      final statuses = {
        for (final a in pool.addresses) a.id: a.status,
      };
      expect(statuses['good'], ServerAddressStatus.ok);
      // 宽容逻辑：bad 单次失败仍保留原状态 unknown。
      expect(statuses['bad'], ServerAddressStatus.unknown);
      expect(
        pool.addresses.firstWhere((a) => a.id == 'good').lastLatencyMs,
        isNotNull,
      );
      expect(
        pool.addresses.firstWhere((a) => a.id == 'bad').lastLatencyMs,
        isNull,
      );
      // 连续第 2 次失败 → 降级 failed。
      await pool.probeAll();
      expect(
        pool.addresses.firstWhere((a) => a.id == 'bad').status,
        ServerAddressStatus.failed,
      );
    });

    test('探测抛异常（如 5xx）→ 单次失败被「加大宽容」容忍', () async {
      headResponse = 500;
      pool.setAddresses([addr(id: 'x')]);
      // 探测异常走 failed 判定，但 _applyProbeResult 宽容逻辑：
      // 单次失败保留原状态（unknown）。
      //
      // 口径变更（批 B / T2）：自动模式「没有 ok 可选」时**保持**原活跃地址，
      // 不再置 null。旧行为会把它清空，于是 isOfflineProvider 判「不在线」，
      // 服务端真挂时播放器反而去试在线流（弹「无路由」）而不是走本地缓存。
      final active = await pool.probeAll();
      expect(active?.id, 'x', reason: '没有可选地址时保持原活跃地址，不清空');
      expect(pool.addresses.single.status, ServerAddressStatus.unknown);
    });

    test('连续失败达到阈值才降级为 failed（宽容逻辑）', () async {
      pool.setAddresses([addr(id: 'only', status: ServerAddressStatus.ok)]);
      expect(pool.activeAddress?.id, 'only');
      headResponse = 500;
      await pool.probeAll(); // 加入 setAddresses 触发的探测（head 早已按 200 发出）
      await pool.probeAll(); // 第 1 次失败：容忍，状态保持 ok。
      expect(pool.activeAddress?.status, ServerAddressStatus.ok);
      await pool.probeAll(); // 第 2 次失败：达到 requiredConsecutiveFails → failed。
      expect(pool.addresses.single.status, ServerAddressStatus.failed);
      // 口径变更（批 B / T2）：真挂了也要**留住**这条活跃地址 —— 它的
      // status == failed 正是 isOfflineProvider 判离线的唯一依据；
      // 置 null 会让「真挂了」漏判成在线（见下一条用例的正例断言）。
      expect(
        pool.activeAddress?.id,
        'only',
        reason: '唯一地址 failed 时保留活跃地址，供 isOfflineProvider 判离线',
      );
      expect(pool.activeAddress?.status, ServerAddressStatus.failed);
    });

    test('探测成功后重置连续失败计数', () async {
      pool.setAddresses([addr(id: 'only', status: ServerAddressStatus.ok)]);
      headResponse = 500;
      await pool.probeAll(); // 失败 1 次（容忍）
      headResponse = 200;
      await pool.probeAll(); // 成功 → 计数清零
      headResponse = 500;
      await pool.probeAll(); // 又是「第 1 次」失败 → 仍容忍
      expect(pool.activeAddress?.status, ServerAddressStatus.ok);
    });

    test('探测中发现更优地址 → 探测途中提升活跃地址（promote 分支）', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll(); // 两者都 ok → active a
      expect(pool.activeAddress?.id, 'a');
      headResponse = 500;
      await pool.probeAll();
      await pool.probeAll(); // a/b 各连续 2 次失败 → 均 failed
      // 口径变更（批 B / T2）：不再把活跃地址清成 null —— 保留最后一条
      // failed 的地址，isOfflineProvider 才能判出「服务端真挂了」。
      expect(pool.activeAddress, isNotNull);
      expect(pool.activeAddress?.status, ServerAddressStatus.failed);
      headResponse = 200;
      final active = await pool.probeAll(); // a 恢复 ok → 探测途中 promote
      expect(active?.id, 'a');
      expect(pool.activeAddress?.id, 'a');
    });

    test('手动模式下探测只更新数据不切换活跃地址', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll();
      await pool.setManualMode(pool.addresses.lastWhere((a) => a.id == 'b'));
      expect(pool.activeAddress?.id, 'b');
      headResponse = 500;
      final active = await pool.probeAll();
      expect(active?.id, 'b', reason: '手动模式下即使探测失败也不切走');
    });
  });

  group('markFailed', () {
    test('多地址池：状态更新 + 回调 + 活跃地址同步', () async {
      pool.setAddresses([
        addr(id: 'a', status: ServerAddressStatus.ok),
        addr(id: 'b', url: 'https://b.example.com', priority: 1),
      ]);
      await pool.probeAll();
      expect(pool.activeAddress?.id, 'a');
      updatedCallbacks.clear();
      activeCallbacks.clear();

      pool.markFailed(addr(id: 'a'));

      expect(
        pool.addresses.firstWhere((a) => a.id == 'a').status,
        ServerAddressStatus.failed,
      );
      expect(pool.activeAddress?.status, ServerAddressStatus.failed);
      expect(updatedCallbacks.map((a) => a.id), contains('a'));
      expect(activeCallbacks, isNotEmpty);
    });

    test('单地址池：跳过判死（状态保持原值、无回调）', () async {
      // 语义已从「单地址也写 failed」改为「单地址刻意跳过判死」：
      // 唯一线路被判死会经 onAddressUpdated 持久化成 failed（下次冷启动
      // _restoreActiveAddressFromPool 只认 status==ok → 恢复不出活跃地址 →
      // 首屏带空 baseUrl 派发），并让 isOfflineProvider 判离线（封面/播放/
      // 遥控全降级）。真实可达性交给 HealthChecker 的周期探测（连续 2 次
      // 失败才降级），这里只记录一次失败。
      pool.setAddresses([addr(id: 'a', status: ServerAddressStatus.ok)]);
      await pool.probeAll();
      expect(pool.activeAddress?.id, 'a');
      updatedCallbacks.clear();
      activeCallbacks.clear();

      pool.markFailed(addr(id: 'a'));

      expect(
        pool.addresses.single.status,
        ServerAddressStatus.ok,
        reason: '单地址判定失败会连锁触发持久化失败 + 全 App 离线降级',
      );
      expect(pool.activeAddress?.status, ServerAddressStatus.ok);
      expect(updatedCallbacks, isEmpty, reason: '不持久化失败态');
      expect(activeCallbacks, isEmpty);
    });

    test('单地址池：markFailed 后 getNextAvailable 仍可用、isOfflineProvider 不判离线',
        () async {
      // 上一条只钉住了「status 不变 + 不回调」。但「判死」在运行时有两条真实
      // 后果链路，必须一并钉住：
      //   1. getNextAvailable() 若返回 null，同地址重试耗尽后的第 6 步 failover
      //      就无路可走 —— 外网只有「单一 HTTPS 反代地址」，等于直接失败；
      //   2. isOfflineProvider 把 activeAddress.status == failed 直接当离线，
      //      于是封面全占位、播放被拒、遥控不可达。
      pool.setAddresses([addr(id: 'a', status: ServerAddressStatus.ok)]);
      await pool.probeAll();
      expect(pool.activeAddress?.id, 'a');

      pool.markFailed(addr(id: 'a'));

      expect(
        pool.getNextAvailable()?.id,
        'a',
        reason: '单地址被判死后 failover 无路可走，必须仍能返回该地址',
      );

      Future<bool> offlineWith(ServerAddress? active) async {
        final container = ProviderContainer(
          overrides: <Override>[
            currentNetworkTypeProvider.overrideWith(
              (ref) => Stream<NetworkType>.value(NetworkType.wifi),
            ),
            activeAddressProvider.overrideWith((ref) => active),
          ],
        );
        addTearDown(container.dispose);
        // 先等 StreamProvider 发出首值：否则首次同步读拿到 loading，valueOrNull
        // 为 null，`??` 会回落到 connectivityMonitorProvider 的真实网络状态
        // （测试环境恒为 none → 恒判离线），断言就失去区分力。
        await container.read(currentNetworkTypeProvider.future);
        return container.read(isOfflineProvider);
      }

      expect(
        await offlineWith(pool.activeAddress),
        isFalse,
        reason: '单地址 markFailed 后不得被判离线',
      );
      // 反向对照：同一套 provider 组合下，status 真为 failed 时必须判离线。
      // 缺了这一条，上面的 isFalse 可能只是断言写坏了（假绿）。
      expect(
        await offlineWith(
          pool.activeAddress?.copyWith(status: ServerAddressStatus.failed),
        ),
        isTrue,
        reason: '对照组：status == failed 时 isOfflineProvider 必须为 true',
      );
    });

    test('未知 id → 无操作', () async {
      pool.setAddresses([
        addr(id: 'a', status: ServerAddressStatus.ok),
        addr(id: 'b', url: 'https://b.example.com', priority: 1),
      ]);
      await pool.probeAll();
      updatedCallbacks.clear();

      pool.markFailed(addr(id: 'ghost'));

      expect(
        pool.addresses.every((a) => a.status == ServerAddressStatus.ok),
        isTrue,
      );
      expect(updatedCallbacks, isEmpty);
    });
  });

  group('getNextAvailable', () {
    test('返回第一个 ok 且未锁定的地址', () async {
      pool.setAddresses([
        addr(id: 'locked', status: ServerAddressStatus.ok, isLocked: true),
        addr(id: 'free', status: ServerAddressStatus.ok, priority: 5),
      ]);
      // 锁定地址被恢复为活跃；getNextAvailable 只找未锁定的 ok。
      expect(pool.getNextAvailable()?.id, 'free');
      await pool.probeAll();
    });

    test('无 ok 地址时回退到活跃地址的下一个', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll(); // 都 ok → active a
      pool.markFailed(addr(id: 'a'));
      pool.markFailed(addr(id: 'b'));
      final next = pool.getNextAvailable();
      // 无 ok → 从活跃地址 a 之后继续找 → b（即使 failed）。
      expect(next?.id, 'b');
    });

    test('无活跃地址且无 ok 地址时回退到列表第一个', () {
      final fresh = AddressPool(dio);
      // setAddresses 内部触发后台探测，同步断言时 active 仍为 null。
      fresh.setAddresses([addr(id: 'first'), addr(id: 'second')]);
      expect(fresh.activeAddress, isNull);
      expect(fresh.getNextAvailable()?.id, 'first');
    });
  });

  group('setManualMode / setAutoMode / lockAddress', () {
    test('setManualMode：锁定目标、解锁其余、活跃地址回调', () async {
      pool.setAddresses([
        addr(id: 'a', isLocked: true),
        addr(id: 'b'),
      ]);
      await pool.probeAll();
      activeCallbacks.clear();
      await pool.setManualMode(pool.addresses.lastWhere((a) => a.id == 'b'));
      final byId = {for (final a in pool.addresses) a.id: a};
      expect(byId['b']!.isLocked, isTrue);
      expect(byId['a']!.isLocked, isFalse);
      expect(pool.activeAddress?.id, 'b');
      expect(pool.isManualMode, isTrue);
      expect(activeCallbacks.map((a) => a?.id), contains('b'));
      expect(updatedCallbacks, isNotEmpty);
    });

    test('setAutoMode：解锁全部并重新探测选优', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll();
      await pool.setManualMode(pool.addresses.lastWhere((a) => a.id == 'b'));
      expect(pool.isManualMode, isTrue);
      await pool.setAutoMode();
      expect(pool.addresses.every((a) => !a.isLocked), isTrue);
      expect(pool.isManualMode, isFalse);
      expect(pool.activeAddress?.id, 'a', reason: '自动模式按优先级选回 a');
    });

    test('lockAddress 等价于 setManualMode', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll();
      pool.lockAddress(pool.addresses.last);
      await pumpEventQueue(); // lockAddress 内部为 fire-and-forget 异步
      expect(pool.activeAddress?.id, 'b');
      expect(pool.activeAddress?.isLocked, isTrue);
      expect(pool.isManualMode, isTrue);
    });
  });

  group('switchTo', () {
    test('manual=true：探测成功返回 true 并锁定', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll();
      final ok = await pool.switchTo(pool.addresses.last);
      expect(ok, isTrue);
      expect(pool.activeAddress?.id, 'b');
      expect(pool.activeAddress?.isLocked, isTrue);
    });

    test('manual=true：探测失败返回 false', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll();
      headResponse = 500;
      final ok = await pool.switchTo(pool.addresses.last);
      expect(ok, isFalse);
    });

    test('manual=false：解锁切换，成功返回 true', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll();
      await pool.setManualMode(pool.addresses.first);
      activeCallbacks.clear();
      final ok = await pool.switchTo(
        pool.addresses.last,
        manual: false,
      );
      expect(ok, isTrue);
      expect(pool.activeAddress?.id, 'b');
      expect(pool.activeAddress?.isLocked, isFalse, reason: 'auto 切换不锁定');
      expect(
        pool.addresses.where((a) => a.isLocked),
        isEmpty,
        reason: '其余地址应被解锁',
      );
      expect(activeCallbacks, isNotEmpty);
    });

    test('manual=false：切换到同一地址时无重复回调', () async {
      pool.setAddresses([addr(id: 'a'), addr(id: 'b')]);
      await pool.probeAll();
      await pool.setManualMode(pool.addresses.last);
      activeCallbacks.clear();
      final ok = await pool.switchTo(pool.addresses.last, manual: false);
      expect(ok, isTrue);
      expect(activeCallbacks, isEmpty, reason: '同 id 切换不应触发 changed 回调');
    });
  });

  group('updateProbedAddress', () {
    test('把外部探测结果回写到池中并触发回调', () async {
      pool.setAddresses([addr(id: 'a', status: ServerAddressStatus.ok)]);
      await pool.probeAll();
      updatedCallbacks.clear();
      pool.updateProbedAddress(
        addr(id: 'a', status: ServerAddressStatus.ok, priority: 0),
      );
      expect(updatedCallbacks.single.id, 'a');
      expect(pool.activeAddress?.id, 'a');
    });

    test('未知 id 的探测结果被忽略', () {
      pool.setAddresses([addr(id: 'a', status: ServerAddressStatus.ok)]);
      updatedCallbacks.clear();
      pool.updateProbedAddress(addr(id: 'ghost', status: ServerAddressStatus.ok));
      expect(updatedCallbacks, isEmpty);
    });
  });
}
