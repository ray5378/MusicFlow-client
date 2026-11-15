// 批 B3 · T4 的**接线**用例（补 B7 变异暴露的真缺口）。
//
// `b_b2_probe_network_down_test.dart` 覆盖的是 `probeActiveThrottled` 方法本身
// （三重限速都对），但**没有任何用例钉住「请求失败之后会被调用」这层接线**。
// 把 `fetch_with_cache_fallback` 里那行 `unawaited(_probeActiveQuietly(ref))`
// 删掉，整套测试依然全绿 —— 也就是说 T4 的收益（判死延迟 30~70s → ~10s）
// 在无人看守的状态下随时会静默失效。
//
// 这里只钉两件事：
//   1. 远程失败 → 池子里确实发生了一次点探测（HEAD 计数 +1）；
//   2. 远程成功 → 一次都不探（不能把正常路径也变成探测路径）。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';

typedef _Handler = Future<ResponseBody> Function(RequestOptions options);

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  _Handler handler;
  int headCount = 0;
  int getCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.method == 'HEAD') {
      headCount++;
    } else {
      getCount++;
    }
    return handler(options);
  }
}

ResponseBody _okBody() => ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

final _flagProvider = StateProvider<bool>((ref) => false);

ServerAddress _addr() => ServerAddress(
      id: 'a',
      libraryId: 'lib-1',
      label: 'a',
      url: 'https://a.example.com',
      priority: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio poolDio;
  late _StubAdapter poolAdapter;
  late AddressPool pool;
  late Duration savedInterval;

  setUp(() async {
    NetworkErrorNotifier.resetForTest();
    savedInterval = AddressPool.onDemandProbeInterval;
    AddressPool.onDemandProbeInterval = const Duration(seconds: 5);

    poolDio = Dio();
    poolAdapter = _StubAdapter((_) async => _okBody());
    poolDio.httpClientAdapter = poolAdapter;
    pool = AddressPool(poolDio);
    pool.setAddresses([_addr()]);
    await pumpEventQueue(); // 排空 setAddresses 自己触发的那次全量探测
    poolAdapter.headCount = 0;
  });

  tearDown(() {
    AddressPool.onDemandProbeInterval = savedInterval;
    NetworkErrorNotifier.resetForTest();
  });

  ProviderContainer container() => ProviderContainer(
        overrides: <Override>[
          addressPoolProvider.overrideWithValue(pool),
          ensureActiveAddressProvider.overrideWith((ref) async => _addr()),
        ],
      );

  /// 拿到一个仍然存活的 [Ref]：外部 provider 被 listen 持有，不会中途 dispose。
  Ref liveRef(ProviderContainer c) {
    final refProvider = Provider<Ref>((ref) => ref);
    return c.listen(refProvider, (_, _) {}).read();
  }

  test('远程失败 → 触发一次点探测（T4 的接线不能静默断掉）', () async {
    final c = container();
    addTearDown(c.dispose);
    final ref = liveRef(c);

    await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'b-probe-wiring-fail',
      fetch: () async => throw StateError('remote boom'),
      cacheWrite: (_) async {},
      cacheRead: () async => 'cached',
      failedProvider: _flagProvider,
      errorMessage: 'net-err',
      emptyValue: '',
    );
    // 探测是 unawaited 的，必须让事件队列转完才看得到 HEAD。
    await pumpEventQueue();

    expect(
      poolAdapter.headCount,
      1,
      reason: '删掉 `unawaited(_probeActiveQuietly(ref))` 后这里会是 0 —— '
          'T4 的判死加速就静默失效了',
    );
  });

  test('远程成功 → 一次都不探（正常路径不能被拖进探测路径）', () async {
    final c = container();
    addTearDown(c.dispose);
    final ref = liveRef(c);

    final value = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'b-probe-wiring-ok',
      fetch: () async => 'fresh',
      cacheWrite: (_) async {},
      cacheRead: () async => null,
      failedProvider: _flagProvider,
      errorMessage: 'net-err',
      emptyValue: '',
    );
    await pumpEventQueue();

    expect(value, 'fresh');
    expect(poolAdapter.headCount, 0, reason: '成功路径不该产生任何探测请求');
  });

  test('缓存兜底命中时仍然探测（失败已发生，与是否有缓存无关）', () async {
    final c = container();
    addTearDown(c.dispose);
    final ref = liveRef(c);

    final value = await fetchWithCacheFallback<String>(
      ref: ref,
      label: 'b-probe-wiring-cache',
      fetch: () async => throw StateError('remote boom'),
      cacheWrite: (_) async {},
      cacheRead: () async => 'cached',
      failedProvider: _flagProvider,
      errorMessage: 'net-err',
      emptyValue: '',
    );
    await pumpEventQueue();

    expect(value, 'cached');
    expect(
      poolAdapter.headCount,
      1,
      reason: '有缓存兜底不代表线路是好的，仍应探测一次',
    );
  });
}
