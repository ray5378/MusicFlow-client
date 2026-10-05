import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

ProviderContainer _container({bool addressOk = true}) {
  return ProviderContainer(
    overrides: <Override>[
      ensureActiveAddressProvider.overrideWith((ref) async {
        if (!addressOk) {
          throw StateError('no active address');
        }
        return _address();
      }),
    ],
  );
}

/// 拿到一个仍然存活的 [Ref]：外部 provider 被 listen 持有，不会中途 dispose。
Ref _liveRef(ProviderContainer container) {
  final refProvider = Provider<Ref>((ref) => ref);
  return container.listen(refProvider, (_, __) {}).read();
}

void main() {
  // fetchWithCacheFallback 在无缓存兜底时会走 NetworkErrorNotifier.show →
  // ToastNotifier（读 rootNavigatorKey.currentState），需要绑定已初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('远程成功：写缓存、清失败标记并返回远程数据', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ref = _liveRef(container);

    final written = <String>[];
    final result = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'probe-remote',
      fetch: () async => 'remote-value',
      cacheWrite: (data) async {
        written.add(data);
      },
      cacheRead: () async => null,
      failedProvider: _flagProvider,
      errorMessage: 'network down',
      emptyValue: '',
    );

    expect(result, 'remote-value');
    expect(written, <String>['remote-value']);
    expect(container.read(_flagProvider), isFalse);
  });

  test('缓存写入失败绝不反噬远程结果', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ref = _liveRef(container);

    final result = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'probe-write-fail',
      fetch: () async => 'remote-value',
      cacheWrite: (data) async {
        throw FormatException('shared prefs cannot encode $data');
      },
      cacheRead: () async => null,
      failedProvider: _flagProvider,
      errorMessage: 'network down',
      emptyValue: '',
    );

    expect(result, 'remote-value');
    expect(container.read(_flagProvider), isFalse);
  });

  test('远程失败且有缓存：回落缓存并清失败标记', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ref = _liveRef(container);

    container.read(_flagProvider.notifier).state = true;

    final result = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'probe-fallback',
      fetch: () async => throw StateError('offline'),
      cacheWrite: (data) async {},
      cacheRead: () async => 'cached-value',
      failedProvider: _flagProvider,
      errorMessage: 'network down',
      emptyValue: '',
    );

    expect(result, 'cached-value');
    expect(container.read(_flagProvider), isFalse);
  });

  test('远程失败且缓存读取抛异常：降级为空值并标记失败', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ref = _liveRef(container);

    final result = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'probe-read-throws',
      fetch: () async => throw StateError('offline'),
      cacheWrite: (data) async {},
      cacheRead: () async => throw StateError('corrupted cache file'),
      failedProvider: _flagProvider,
      errorMessage: 'network down',
      emptyValue: 'empty',
    );

    expect(result, 'empty');
    expect(container.read(_flagProvider), isTrue);
  });

  test('远程失败且无缓存：返回空值并标记失败', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ref = _liveRef(container);

    final result = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'probe-cache-miss',
      fetch: () async => throw StateError('offline'),
      cacheWrite: (data) async {},
      cacheRead: () async => null,
      failedProvider: _flagProvider,
      errorMessage: 'network down',
      emptyValue: 'empty',
    );

    expect(result, 'empty');
    expect(container.read(_flagProvider), isTrue);
  });

  test('活跃地址获取失败即视为远程失败，走缓存兜底', () async {
    final container = _container(addressOk: false);
    addTearDown(container.dispose);
    final ref = _liveRef(container);

    var fetchCalled = false;
    final result = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'probe-no-address',
      fetch: () async {
        fetchCalled = true;
        return 'remote-value';
      },
      cacheWrite: (data) async {},
      cacheRead: () async => 'cached-value',
      failedProvider: _flagProvider,
      errorMessage: 'network down',
      emptyValue: '',
    );

    expect(fetchCalled, isFalse);
    expect(result, 'cached-value');
    expect(container.read(_flagProvider), isFalse);
  });
}
