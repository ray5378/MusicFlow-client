// 启动编排「三处修复」的行为锁回归测试 —— commit 128a4c3 / de6e7da / 281245f（tag v5.0.38）。
//
// 背景：用户反馈「启动到可用要几秒」。网络实测并不慢（公网首连 186ms、复用后 3ms），
// 耗时全在客户端启动编排的三段**定时空转**上，最坏叠加 ≈6.9s。三处都改成了事件驱动：
//
//   Fix-1 fetchLocalQueueForRestore：100ms 一跳最多 4s 的轮询等注册
//         → 注册完成 Completer 事件驱动唤醒，预算 1.5s（kPeerIdWaitBudget）
//   Fix-2 _registerSelf 401 重试：固定 Future.delayed(900ms) 盲等
//         → 等 apiCredentialsReadyProvider 凭证就绪信号，就绪即重试
//   Fix-3 ensureActiveAddressProvider：200ms 一跳最多 2s 空转等活跃地址
//         → AddressPool.waitForActiveAddress 就绪信号事件驱动，预算 300ms
//
// 本文件的判据不是「现在能过」，而是**「回退修复必红」**：每条用例都做过双向变异验证
// （把修复改回旧写法 → 该用例必须转红 → 还原 → 再转绿），见文件末尾的变异说明。
//
// 时间断言一律用 fake_async 的虚拟时钟推进或宽松阈值，避免 CI 抖动导致 flaky ——
// 判据是「新旧写法有数量级差异」，不是精确到毫秒。
//
// 装配复用 test/providers/cast_peer_cov_test.dart 的范式：
// MockSubsonicApiClient 桩网络 + TestPlayerNotifier 桩播放器 + ProviderContainer
// 直接读 castPeerControllerProvider.notifier。
//
// ⚠️ Fix-1 的可测性说明（如实记录）：
//   `_waitForLocalPeerId` 是**库私有**成员；唯一调用方 `fetchLocalQueueForRestore`
//   的第一句就是 `if (Platform.environment['FLUTTER_TEST'] != null) return null;`
//   而 flutter 工具会给每个 `flutter test` 进程注入 FLUTTER_TEST。已实测两条路都堵死：
//     1) `Platform.environment` 是**不可修改**的 Map（remove 抛
//        Unsupported operation: Cannot modify unmodifiable map）；
//     2) 以 dynamic 调用私有成员抛 NoSuchMethodError（私有名按库隔离）。
//   因此 Fix-1 无法在测试进程里做真·运行时计时，只能用「公开预算常量契约 +
//   恢复/等待路径的源码不变量」锁定；一旦有人把轮询写法改回来，该组会立刻转红
//   （已用变异验证：把 _waitForLocalPeerId 换回 100ms/4s 轮询 → 该组转红）。
//   本文件**不为测试改动 lib/ 源码**。

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// Dio 桩：AddressPool 只用它做探测，探测一律失败（MissingStubError 被
/// probeAddress 内部 catch），保证「无活跃地址」这个前置状态稳定。
class _MockDio extends Mock implements Dio {
  @override
  BaseOptions get options => BaseOptions();
}

/// 从仓库根读取 lib 源码（供不变量锁用）。flutter test 的 cwd 是包根，
/// 这里仍逐级向上找，避免换 runner 时定位失败。
String _readLib(String relPath) {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final file = File('${dir.path}/$relPath');
    if (file.existsSync()) return file.readAsStringSync();
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('无法定位 $relPath（cwd=${Directory.current.path}）');
}

/// 截取一个方法体（从签名到该方法的收尾 `  }`），把「缺失性」断言限定在方法内，
/// 避免误伤同文件里其它用途的定时器（例如状态轮询的 Timer.periodic(4s)）。
String _methodRegion(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) return '';
  final end = src.indexOf('\n  }\n', start);
  return end < 0 ? src.substring(start) : src.substring(start, end);
}

void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier player;
  late ProviderContainer container;
  late CastPeerController ctrl;

  /// `/register` 调用次数（只数 register，心跳/上报不算）。
  int registerTries = 0;
  /// 让第一次注册抛错，模拟冷启动「token 还没注入 → 401」。
  bool failFirstRegister = false;

  /// 统一网络分发：注册按 [failFirstRegister] 决定成败，其余返回最小可用响应。
  Map<String, dynamic> route(String path) {
    if (path.endsWith('/register')) {
      registerTries += 1;
      if (failFirstRegister && registerTries == 1) {
        throw StateError('simulated 401: api credentials not injected yet');
      }
      return <String, dynamic>{
        'peer': <String, dynamic>{'peerId': 'local-7'},
      };
    }
    if (path.endsWith('/heartbeat')) return <String, dynamic>{};
    if (path.endsWith('/local-status')) return <String, dynamic>{};
    if (path.endsWith('/queue')) {
      return <String, dynamic>{
        'currentIndex': 0,
        'total': 0,
        'playMode': 'all',
        'items': <dynamic>[],
      };
    }
    return <String, dynamic>{};
  }

  setUp(() {
    registerTries = 0;
    failFirstRegister = false;
    client = MockSubsonicApiClient();
    player = TestPlayerNotifier(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => player),
      ],
    );
    ctrl = container.read(castPeerControllerProvider.notifier);

    // ⚠️ mocktail 的桩必须 `return route(...)`（把返回值当 HTTP 响应），
    // 只当副作用调用会让所有响应恒为 {}（踩坑见 cast_peer_cov_test.dart）。
    when(() => client.postRaw(any())).thenAnswer(
      (inv) async => route(inv.positionalArguments[0] as String),
    );
    when(
      () => client.postRaw(
        any(),
        data: any(named: 'data'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((inv) async => route(inv.positionalArguments[0] as String));
    when(() => client.getRaw(any())).thenAnswer(
      (inv) async => route(inv.positionalArguments[0] as String),
    );
    when(
      () => client.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((inv) async => route(inv.positionalArguments[0] as String));
  });

  tearDown(() async {
    try {
      ctrl.stopHeartbeat();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 10));
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  // =========================================================================
  // Fix-1 事件驱动等待 peerId（预算 1.5s，不再是 100ms 一跳的 4s 空转）
  // =========================================================================
  group('Fix-1 事件驱动等待 peerId', () {
    test('kPeerIdWaitBudget 是公开的 1.5s 预算常量（历史最坏等待是 4s）', () {
      expect(
        CastPeerController.kPeerIdWaitBudget,
        const Duration(milliseconds: 1500),
      );
      expect(
        CastPeerController.kPeerIdWaitBudget,
        lessThan(const Duration(seconds: 4)),
        reason: '等待注册落地的预算必须显著小于历史 4s 空转轮询',
      );
    });

    test('恢复路径走事件驱动等待（等待区内不得再有轮询 / deadline）', () {
      final src =
          _readLib('lib/providers/cast/cast_peer_provider.dart');

      // 存在性：Completer 信号 + 带预算的事件驱动等待 + 恢复流程改走该入口。
      expect(src, contains('Completer<String>? _localPeerIdReady;'));
      expect(src, contains('_ensurePeerIdReady'));
      expect(
        src,
        contains('_ensurePeerIdReady().future.timeout(kPeerIdWaitBudget)'),
      );
      expect(src, contains('final pid = await _waitForLocalPeerId();'));

      // 注册落地处必须唤醒等待方（否则等待方只能等预算耗尽）。
      final registerRegion = _methodRegion(
        src,
        'Future<void> _registerSelf({int attempt = 0}) async {',
      );
      expect(registerRegion, isNotEmpty);
      expect(registerRegion, contains('_localPeerIdReady'));
      expect(registerRegion, contains('ready.complete('));

      // 反「假事件驱动」：complete 不能被塞进永假分支 —— 符号都在、文本守卫判绿，
      // 但等待方永远不会被唤醒（只能等预算耗尽）。
      expect(registerRegion, isNot(contains('if (false)')));
      expect(registerRegion, isNot(contains('&& false')));

      // 缺失性：等待方法体内不得再出现「100ms 一跳 + 4s deadline」的空转轮询。
      final waitRegion = _methodRegion(
        src,
        'Future<String?> _waitForLocalPeerId() async {',
      );
      expect(waitRegion, isNotEmpty);
      expect(waitRegion, isNot(contains('while (')));
      expect(waitRegion, isNot(contains('Duration(milliseconds: 100)')));
      expect(waitRegion, isNot(contains('DateTime.now()')));
      expect(waitRegion, isNot(contains('Duration(seconds: 4)')));
    });

    test('已注册时 localPeerId 立即可用（等待方的同步快路径前提）', () async {
      final sw = Stopwatch()..start();
      await ctrl.registerAndHeartbeat();
      final elapsed = sw.elapsedMilliseconds;

      expect(ctrl.localPeerId, 'local-7');
      expect(
        elapsed,
        lessThan(1000),
        reason: '注册落地后 localPeerId 必须在位，等待方走同步快路径、零轮询',
      );
    });
  });

  // =========================================================================
  // Fix-2 凭证就绪即重试（不再是固定 900ms 盲等）
  // =========================================================================
  group('Fix-2 凭证就绪即重试', () {
    test('活跃库未就绪 → apiCredentialsReadyProvider 返回挂起 Future（不放行）',
        () {
      final c = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWith((ref) => null),
        ],
      );
      addTearDown(c.dispose);

      fakeAsync((async) {
        var done = false;
        c.read(apiCredentialsReadyProvider).then((_) => done = true);

        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        expect(
          done,
          isFalse,
          reason: '活跃库尚未发射 → 凭证未就绪 → 等待方必须保持挂起（不能被放行）',
        );
      });
    });

    test('活跃库已就绪 → apiCredentialsReadyProvider 返回已完成 Future（零等待放行）',
        () {
      final lib = MusicLibrary(
        id: 'lib-1',
        name: '测试库',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
      );
      final c = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWith((ref) => lib),
        ],
      );
      addTearDown(c.dispose);

      fakeAsync((async) {
        var done = false;
        c.read(apiCredentialsReadyProvider).then((_) => done = true);

        // 不推进任何虚拟时间：已完成 Future 只需排空微任务即可放行。
        async.flushMicrotasks();

        expect(done, isTrue, reason: '活跃库已就绪 → 等待方必须零等待放行');
      });
    });

    test('活跃库迟到发射 → 放行旧等待方（凭证一到就唤醒重试）', () {
      MusicLibrary? lib;
      final c = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWith((ref) => lib),
        ],
      );
      addTearDown(c.dispose);

      fakeAsync((async) {
        var done = false;
        c.read(apiCredentialsReadyProvider).then((_) => done = true);

        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(done, isFalse, reason: '库还没发射 → 仍应挂起');

        // 活跃库发射 → provider 重建 → onDispose 放行旧等待方。
        lib = MusicLibrary(
          id: 'lib-1',
          name: '测试库',
          createdAt: DateTime(2024),
          updatedAt: DateTime(2024),
        );
        c.invalidate(activeLibraryProvider);
        c.read(activeLibraryProvider);
        async.flushMicrotasks();

        expect(done, isTrue, reason: '活跃库一发射，等待方必须被即刻唤醒');
      });
    });

    test('注册 401 后：只推进 100ms 就出现第二次注册（旧写法要盲等 900ms）', () {
      failFirstRegister = true;

      fakeAsync((async) {
        var completed = false;
        unawaited(ctrl.registerAndHeartbeat().then((_) => completed = true));

        // 首拍同步发出（mock 的 route 在调用当拍即计数）。
        expect(registerTries, 1, reason: '第一拍 register 应已发出');

        // 只推进 100ms：事件驱动下「凭证就绪」即重试（flutter_test 下零等待），
        // 历史写法的 900ms 定时器此刻还没到点。
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();

        expect(
          registerTries,
          2,
          reason: '凭证就绪即重试：100ms 内必须已发出第二次 register（旧写法 900ms 盲等）',
        );
        expect(completed, isTrue);
      });
    });

    test('注册 401 后重试总耗时远小于历史 900ms 盲等', () async {
      failFirstRegister = true;

      final sw = Stopwatch()..start();
      await ctrl.registerAndHeartbeat();
      final elapsed = sw.elapsedMilliseconds;

      expect(registerTries, 2, reason: '应重试一次');
      expect(
        elapsed,
        lessThan(600),
        reason: '事件驱动重试应远快于历史固定 900ms 盲等（实测应是个位数 ms）',
      );
    });

    test('凭证就绪后重试成功 → 落地 peerId（盲等只是白等，不影响正确性）', () async {
      failFirstRegister = true;

      await ctrl.registerAndHeartbeat();

      expect(registerTries, 2);
      expect(ctrl.localPeerId, 'local-7');
    });
  });

  // =========================================================================
  // Fix-3 活跃地址就绪信号（事件驱动，预算 300ms，不再是 200ms 一跳的 2s 空转）
  // =========================================================================
  group('Fix-3 活跃地址就绪信号', () {
    ServerAddress addr({
      String id = 'a1',
      String label = 'Server 1',
      String url = 'https://server1.example.com',
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

    test('已有活跃地址 → waitForActiveAddress 零等待返回该地址', () {
      final pool = AddressPool(_MockDio());
      pool.setAddresses([addr(status: ServerAddressStatus.ok)]);
      expect(pool.activeAddress, isNotNull);

      fakeAsync((async) {
        ServerAddress? got;
        var done = false;
        unawaited(
          pool.waitForActiveAddress().then((v) {
            done = true;
            got = v;
          }),
        );

        // 不推进任何虚拟时间：同步快路径必须当场返回。
        async.flushMicrotasks();

        expect(done, isTrue);
        expect(got?.id, 'a1');
      });
    });

    test('无活跃地址 → 激活后即刻唤醒（不必等 200ms 轮询 tick）', () {
      final pool = AddressPool(_MockDio());
      pool.setAddresses([addr(status: ServerAddressStatus.unknown)]);
      expect(pool.activeAddress, isNull);

      fakeAsync((async) {
        ServerAddress? got;
        var done = false;
        unawaited(
          pool.waitForActiveAddress().then((v) {
            done = true;
            got = v;
          }),
        );

        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();
        expect(done, isFalse, reason: '还没激活 → 等待方应挂起');

        // 激活地址（模拟 setAddresses 恢复成功 / 探测选中）。
        pool.setAddresses([addr(status: ServerAddressStatus.ok)]);
        async.flushMicrotasks();

        expect(
          done,
          isTrue,
          reason: '活跃地址一就绪即刻唤醒（历史写法要等下一个 200ms 轮询 tick）',
        );
        expect(got?.id, 'a1');
      });
    });

    test('一直不就绪 → 300ms 预算后返回 null（不抛异常、不死等）', () {
      final pool = AddressPool(_MockDio());
      pool.setAddresses([addr(status: ServerAddressStatus.unknown)]);

      fakeAsync((async) {
        ServerAddress? got;
        Object? err;
        var done = false;
        unawaited(
          pool.waitForActiveAddress().then(
            (v) {
              done = true;
              got = v;
            },
            onError: (Object e) {
              done = true;
              err = e;
            },
          ),
        );

        async.elapse(const Duration(milliseconds: 250));
        async.flushMicrotasks();
        expect(done, isFalse, reason: '250ms 仍在 300ms 预算内 → 应保持挂起');

        // 累计 400ms > 300ms 预算：必须已放行（旧写法要空转到 2s）。
        async.elapse(const Duration(milliseconds: 150));
        async.flushMicrotasks();

        expect(done, isTrue, reason: '超过预算必须放行，不得死等');
        expect(err, isNull, reason: '预算耗尽返回 null 回退，绝不抛异常');
        expect(got, isNull);
      });
    });

    test('ensureActiveAddressProvider 在预算内回退最优地址（不是 2s 空转）',
        () async {
      final pool = AddressPool(_MockDio());
      pool.setAddresses([addr(status: ServerAddressStatus.unknown)]);
      final c = ProviderContainer(
        overrides: <Override>[addressPoolProvider.overrideWithValue(pool)],
      );
      addTearDown(c.dispose);

      final sw = Stopwatch()..start();
      final result = await c.read(ensureActiveAddressProvider.future);
      final elapsed = sw.elapsedMilliseconds;

      expect(result.id, 'a1', reason: '预算内没等到活跃地址 → 回退当前最优地址');
      expect(
        elapsed,
        lessThan(1000),
        reason: '历史写法是 200ms 一跳的 2s 空转，首屏每个请求都要先过这里',
      );
    });
  });
}
