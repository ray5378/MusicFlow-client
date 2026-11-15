// 批 B3 · 首屏缓存优先（SWR）：有缓存就立刻交出旧值，再在后台拉新值。
//
// 三条硬判据：
//   1. **首帧不发请求** —— 后台刷新必须推到事件队列，否则「缓存优先」又变回
//      远程优先（`_scheduleBackgroundRefresh` 里的 `Future<void>(() async {...})`
//      就是为此存在，这里的 `fetchCalls == 0` 断言是它的唯一守卫）；
//   2. **闸生效** —— 同一 `label|refreshKey` 在 10s TTL 窗口内只刷一次，
//      否则 `invalidateSelf` → provider 重跑 → 再刷新就是自我触发的死循环；
//      TTL 窗口过后显式刷新放行（一次性 Set 会把手动/下拉刷新永久挡死）；
//   3. **后台失败静默** —— 用户已经看到内容了，不能再弹「网络异常」，也不能
//      把整块打成失败态。这条必须先 `NetworkErrorNotifier.resetForTest()`
//      再断言，否则 20s 节流会让它恒绿（假绿）。

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_message.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';

final _flagProvider = StateProvider<bool>((ref) => true);

ServerAddress _address() => ServerAddress(
      id: 'addr-1',
      libraryId: 'lib-1',
      label: 'Home',
      url: 'https://example.test',
      priority: 0,
    );

ProviderContainer _container() => ProviderContainer(
      overrides: <Override>[
        ensureActiveAddressProvider.overrideWith((ref) async => _address()),
      ],
    );

/// 拿到一个仍然存活的 [Ref]：外部 provider 被 listen 持有，不会中途 dispose。
Ref _liveRef(ProviderContainer container) {
  final refProvider = Provider<Ref>((ref) => ref);
  return container.listen(refProvider, (_, _) {}).read();
}

Widget _toastHost() => MaterialApp(
      navigatorKey: rootNavigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: SizedBox.shrink()),
    );

void main() {
  // fetchWithCacheFallback 的「无缓存兜底」会走 NetworkErrorNotifier.show →
  // ToastNotifier（读 rootNavigatorKey.currentState），需要绑定已初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NetworkErrorNotifier.resetForTest();
    refreshClockForTest = DateTime.now;
    resetRefreshGateForTest();
  });

  tearDown(NetworkErrorNotifier.resetForTest);

  group('T7 cache-first SWR', () {
    test('有缓存：首帧不发请求、立刻吐出缓存值、不置失败标记', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var fetchCalls = 0;
        Object? result;

        unawaited(
          fetchWithCacheFallback<List<String>>(
            ref: ref,
            label: 'b-swr',
            cacheFirst: true,
            fetch: () async {
              fetchCalls++;
              return <String>['fresh'];
            },
            cacheWrite: (_) async {},
            cacheRead: () async => <String>['cached'],
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: const <String>[],
          ).then((v) => result = v),
        );

        async.flushMicrotasks(); // 假时钟一格都不推进 = 「<100ms」
        expect(result, <String>['cached']);
        expect(
          fetchCalls,
          0,
          reason: '后台刷新必须推到事件队列之后，否则等于又变回远程优先',
        );
        expect(container.read(_flagProvider), isFalse);

        async.elapse(Duration.zero); // 事件队列转一圈 → 后台刷新开跑
        async.flushMicrotasks();
        expect(fetchCalls, 1);
      });
    });

    test('闸生效：同一 label 第二次不再刷新；reset 之后才允许', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var fetchCalls = 0;

        Future<List<String>> run() => fetchWithCacheFallback<List<String>>(
              ref: ref,
              label: 'b-swr-gate',
              cacheFirst: true,
              fetch: () async {
                fetchCalls++;
                return <String>['fresh'];
              },
              cacheWrite: (_) async {},
              cacheRead: () async => <String>['cached'],
              failedProvider: _flagProvider,
              errorMessage: 'net-err',
              emptyValue: const <String>[],
            );

        unawaited(run());
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(fetchCalls, 1);

        // 第二次（等价于 invalidateSelf → provider 重跑）：闸挡住，不得再发。
        unawaited(run());
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(
          fetchCalls,
          1,
          reason: '没有 _refreshedLabels 闸，刷新会变成自我触发的死循环',
        );

        resetRefreshGateForTest();
        unawaited(run());
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(fetchCalls, 2, reason: 'resetRefreshGateForTest 之后应重新放行');
      });
    });

    test('后台刷新成功 → 写回缓存；失败 → 静默、不置失败标记', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var written = <String>[];

        unawaited(
          fetchWithCacheFallback<List<String>>(
            ref: ref,
            label: 'b-swr-write',
            cacheFirst: true,
            fetch: () async => <String>['fresh'],
            cacheWrite: (d) async => written = d,
            cacheRead: () async => <String>['cached'],
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: const <String>[],
          ),
        );
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(written, <String>['fresh']);

        // 失败分支
        resetRefreshGateForTest();
        unawaited(
          fetchWithCacheFallback<List<String>>(
            ref: ref,
            label: 'b-swr-fail',
            cacheFirst: true,
            fetch: () async => throw StateError('background boom'),
            cacheWrite: (_) async {},
            cacheRead: () async => <String>['cached'],
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: const <String>[],
          ),
        );
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(
          container.read(_flagProvider),
          isFalse,
          reason: '后台刷新失败不该让整块显示失败态',
        );
      });
    });

    test('无缓存：行为与今天完全一致（走远程，只发 1 次）', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var fetchCalls = 0;
        Object? result;

        unawaited(
          fetchWithCacheFallback<List<String>>(
            ref: ref,
            label: 'b-swr-nocache',
            cacheFirst: true,
            fetch: () async {
              fetchCalls++;
              return <String>['remote'];
            },
            cacheWrite: (_) async {},
            cacheRead: () async => null,
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: const <String>[],
          ).then((v) => result = v),
        );

        async.flushMicrotasks();
        expect(result, <String>['remote']);
        expect(fetchCalls, 1, reason: '无缓存时不得再多发一次后台刷新');
      });
    });

    test('空缓存（空列表）不算「有缓存」', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var fetchCalls = 0;
        Object? result;

        unawaited(
          fetchWithCacheFallback<List<String>>(
            ref: ref,
            label: 'b-swr-empty-cache',
            cacheFirst: true,
            fetch: () async {
              fetchCalls++;
              return <String>['remote'];
            },
            cacheWrite: (_) async {},
            cacheRead: () async => <String>[],
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: const <String>[],
          ).then((v) => result = v),
        );

        async.flushMicrotasks();
        expect(
          result,
          <String>['remote'],
          reason: '空列表当「有缓存」会让首装永远显示空区块',
        );
        expect(fetchCalls, 1);
      });
    });

    testWidgets('后台刷新失败不弹 toast（宿主可用性由同一条用例的正向对照证明）',
        (tester) async {
      await tester.pumpWidget(_toastHost());
      NetworkErrorNotifier.resetForTest();
      resetRefreshGateForTest();

      final container = _container();
      addTearDown(container.dispose);
      final ref = _liveRef(container);
      var fetchCalls = 0;

      final result = await fetchWithCacheFallback<List<String>>(
        ref: ref,
        label: 'b-swr-no-toast',
        cacheFirst: true,
        fetch: () async {
          fetchCalls++;
          throw StateError('background boom');
        },
        cacheWrite: (_) async {},
        cacheRead: () async => <String>['cached'],
        failedProvider: _flagProvider,
        errorMessage: 'net-err',
        emptyValue: const <String>[],
      );

      expect(result, <String>['cached']);
      // 后台刷新挂在事件队列上（Timer 0）。`tester.pump()` 不带时长**不推进
      // 假时钟**，零时长 Timer 不会触发；必须显式给 1ms 才会跑到它。
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(fetchCalls, 1);
      expect(container.read(_flagProvider), isFalse);
      expect(
        find.byType(MusicFlowMessage),
        findsNothing,
        reason: '用户已经看到内容了，后台刷新失败弹「网络异常」正是批 A 要消灭的症状',
      );

      // 正向对照：此刻 toast 宿主确实是可用的，上面的 findsNothing 才有意义。
      NetworkErrorNotifier.show('control-toast');
      await tester.pump();
      expect(find.text('control-toast'), findsOneWidget);

      await tester.pump(const Duration(seconds: 31));
    });

    test('P0-1 闸键带 label 命名空间：两个区块同一 refreshKey 各刷一次', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var fetchCalls = 0;

        // 模拟两个首屏区块：label 不同，但传的是同一个 libraryId。
        Future<List<String>> run(String label) =>
            fetchWithCacheFallback<List<String>>(
          ref: ref,
          label: label,
          refreshKey: 'lib-1',
          cacheFirst: true,
          fetch: () async {
            fetchCalls++;
            return <String>['fresh'];
          },
          cacheWrite: (_) async {},
          cacheRead: () async => <String>['cached'],
          failedProvider: _flagProvider,
          errorMessage: 'net-err',
          emptyValue: const <String>[],
        );

        unawaited(run('blockA'));
        unawaited(run('blockB'));
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(
          fetchCalls,
          2,
          reason: '闸键只按业务 refreshKey 去重时，先 build 的区块会吃掉'
              '另一个区块整会话的刷新机会（P0-1）',
        );
      });
    });

    test('P0-2 TTL 闸：窗口内不重复刷新，推进 >10s 后可再次刷新', () {
      DateTime fakeNow = DateTime(2024, 1, 1);
      refreshClockForTest = () => fakeNow;
      addTearDown(() => refreshClockForTest = DateTime.now);

      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var fetchCalls = 0;

        Future<List<String>> run() =>
            fetchWithCacheFallback<List<String>>(
          ref: ref,
          label: 'b-swr-ttl',
          refreshKey: 'lib-1',
          cacheFirst: true,
          fetch: () async {
            fetchCalls++;
            return <String>['fresh'];
          },
          cacheWrite: (_) async {},
          cacheRead: () async => <String>['cached'],
          failedProvider: _flagProvider,
          errorMessage: 'net-err',
          emptyValue: const <String>[],
        );

        unawaited(run());
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(fetchCalls, 1, reason: '首次放行');

        // 窗口内（+5s）：invalidateSelf 触发的重跑仍被挡，不能形成死循环。
        fakeNow = fakeNow.add(const Duration(seconds: 5));
        unawaited(run());
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(fetchCalls, 1, reason: '10s 窗口内不重复刷新');

        // 推进超过 TTL（累计 11s）：用户显式刷新必须重新发出远程请求。
        fakeNow = fakeNow.add(const Duration(seconds: 6));
        unawaited(run());
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(
          fetchCalls,
          2,
          reason: '一次性 Set 会永久挡住 —— 手动/下拉刷新零远程请求（P0-2）',
        );
      });
    });
  });
}
