// 批 B2 · 时间收口（后半）：T6 请求总预算 / T7 cache-first SWR。
//
// T6：批 A 的同地址重试把黑洞场景的单请求拖到 ~33s。这里在 provider 层用
// `Future.timeout` 截断（默认 5s，全量歌单 8s），用户最多等这么久就走缓存/
// 失败态。**唯一的新风险面是「预算超时后底层再抛错」不能变成未捕获异常**，
// 所以有一条专门的 runZonedGuarded 用例。
//

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/server_address.dart';
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


void main() {
  // fetchWithCacheFallback 的「无缓存兜底」会走 NetworkErrorNotifier.show →
  // ToastNotifier（读 rootNavigatorKey.currentState），需要绑定已初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NetworkErrorNotifier.resetForTest();
  });

  tearDown(NetworkErrorNotifier.resetForTest);

  group('T6 请求总预算', () {
    test('默认预算就是 5s（黑洞场景 33s 长尾的上限）', () {
      expect(kDefaultRequestBudget, const Duration(seconds: 5));
    });

    test('fetch 永不完成 → 5s 到点落失败态，而不是一直挂着', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        final never = Completer<String>();
        var done = false;
        Object? value;

        unawaited(
          fetchWithCacheFallback<String>(
            ref: ref,
            label: 'b-budget-never',
            fetch: () => never.future,
            cacheWrite: (_) async {},
            cacheRead: () async => null,
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: '',
          ).then((v) {
            value = v;
            done = true;
          }),
        );

        async.elapse(const Duration(milliseconds: 4900));
        async.flushMicrotasks();
        expect(done, isFalse, reason: '4.9s 前不该放弃');

        async.elapse(const Duration(milliseconds: 200));
        async.flushMicrotasks();
        expect(done, isTrue, reason: '5s 预算必须把它截断');
        expect(value, '');
        expect(container.read(_flagProvider), isTrue);
      });
    });

    test('3s 才返回的快请求不会被砍（预算不是超时时间的一刀切）', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        var done = false;
        Object? value;

        unawaited(
          fetchWithCacheFallback<String>(
            ref: ref,
            label: 'b-budget-slow-ok',
            fetch: () async {
              await Future<void>.delayed(const Duration(seconds: 3));
              return 'slow-but-ok';
            },
            cacheWrite: (_) async {},
            cacheRead: () async => null,
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: '',
          ).then((v) {
            value = v;
            done = true;
          }),
        );

        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(value, 'slow-but-ok');
        expect(container.read(_flagProvider), isFalse);
      });
    });

    test('per-call 放宽到 8s → 6s 才回来的请求仍成功', () {
      fakeAsync((async) {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        Object? value;

        unawaited(
          fetchWithCacheFallback<String>(
            ref: ref,
            label: 'b-budget-8s',
            budget: const Duration(seconds: 8),
            fetch: () async {
              await Future<void>.delayed(const Duration(seconds: 6));
              return 'playlists-ok';
            },
            cacheWrite: (_) async {},
            cacheRead: () async => null,
            failedProvider: _flagProvider,
            errorMessage: 'net-err',
            emptyValue: '',
          ).then((v) => value = v),
        );

        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(value, 'playlists-ok', reason: 'playlistsProvider 传的 8s 必须生效');
        expect(container.read(_flagProvider), isFalse);
      });
    });

    test('预算超时后底层再抛错 → 不产生未捕获异常', () async {
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final container = _container();
        addTearDown(container.dispose);
        final ref = _liveRef(container);
        final completer = Completer<String>();

        final result = await fetchWithCacheFallback<String>(
          ref: ref,
          label: 'b-budget-late-error',
          // 用短预算代替真等 5s：被测的是「超时之后源 future 再报错」这条路径，
          // 与预算具体多长无关。
          budget: const Duration(milliseconds: 50),
          fetch: () => completer.future,
          cacheWrite: (_) async {},
          cacheRead: () async => null,
          failedProvider: _flagProvider,
          errorMessage: 'net-err',
          emptyValue: 'fallback',
        );
        expect(result, 'fallback');
        expect(container.read(_flagProvider), isTrue);

        // 预算已经超时，底层此刻才报错 —— 这一条若冒成 uncaught 就会挂进程。
        completer.completeError(StateError('late boom'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }, (e, s) => zoneErrors.add(e));

      expect(
        zoneErrors,
        isEmpty,
        reason: 'Future.timeout 之后源 future 的错误必须被安静吞掉',
      );
    });
  });

}
