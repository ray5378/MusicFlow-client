// b41a · SWR「内容没变就不重建」护栏（首页闪烁修复的行为钉子）
//
// 背景（用户报「首页先闪一下」）：
//   cache-first SWR 的后台刷新成功后**无条件** `ref.invalidateSelf()`，即便拉回来
//   的数据和缓存里一模一样。重建会让整块走过一帧 `AsyncLoading(previous)`，
//   观感就是「明明内容没变，还是闪了一下」。
//
// 修复口径（本文件把它钉死）：
//   只有「两个指纹都非 null 且相等」才跳过重建；任一为 null 一律判成「变了」，
//   继续走原来的 `invalidateSelf()`。
//
// 为什么必须同时钉「null → 重建」：
//   那是这条优化唯一的致命向：如果有人把 `freshPrint != null` 这几个条件简化成
//   「两个指纹相等才重建」，任何不可 `jsonEncode` 的载荷就会**永远不再上屏**
//   （数据变了却不刷新），比闪一下严重得多。第四条用例专门守这个向。
//
// 为什么载荷用 `List<Playlist>`：
//   它就是真实调用点（`recentPlaylistsProvider`）的类型，有 `toJson()`、没有
//   本地生成的时间戳字段。用自定义「简单模型」做测试会掩盖真实模型里可能存在的
//   `toString()` / `operator ==` 陷阱。
//
// 断言口径：把 `fetchWithCacheFallback` 包进一个 `FutureProvider`，用自增计数器
// 记录 **provider body 执行次数**（等价于「重建次数」）与 `fetch` 调用次数。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';

final StateProvider<bool> _failedProvider = StateProvider<bool>((ref) => false);

ServerAddress _address() => ServerAddress(
      id: 'addr-1',
      libraryId: 'lib-1',
      label: 'Home',
      url: 'https://example.test',
      priority: 0,
    );

Playlist _pl(String id, String name) => Playlist(
      id: id,
      name: name,
      songCount: 3,
      duration: 180,
    );

/// 一条用例的全部可观测量。
class _Harness {
  _Harness({required this.cached, required this.next});

  /// 缓存里已有的载荷（首帧会立刻交出去）。
  List<Playlist> cached;

  /// `fetch` 返回的载荷。
  List<Playlist> next;

  /// provider body 执行次数 —— 等价于「重建次数」。
  int bodyRuns = 0;

  /// 远程请求次数。
  int fetchCalls = 0;

  /// 缓存写入次数（证明「跳过重建」不等于「跳过写缓存」）。
  int cacheWrites = 0;

  /// 最后一次落盘的载荷。
  List<Playlist>? lastWritten;
}

final Provider<_Harness> _harnessProvider =
    Provider<_Harness>((ref) => throw UnimplementedError('测试必须 override'));

/// 被测 provider：body 里计数，再完整走 `fetchWithCacheFallback` 的 cache-first
/// 路径（刻意**不** override 它本身，让真实 SWR 逻辑参与）。
final FutureProvider<List<Playlist>> _swrProvider =
    FutureProvider<List<Playlist>>((ref) async {
  final h = ref.watch(_harnessProvider);
  h.bodyRuns += 1;
  return fetchWithCacheFallback<List<Playlist>>(
    ref: ref,
    label: 'b41a-pl',
    cacheFirst: true,
    fetch: () async {
      h.fetchCalls += 1;
      return h.next;
    },
    cacheWrite: (data) async {
      h.cacheWrites += 1;
      h.cached = data;
      h.lastWritten = data;
    },
    cacheRead: () async =>
        h.cached.isEmpty ? null : List<Playlist>.of(h.cached),
    failedProvider: _failedProvider,
    errorMessage: 'net-err',
    emptyValue: const <Playlist>[],
  );
});

/// 无 `toJson()` 的私有载荷：`jsonEncode` 必抛 `JsonUnsupportedObjectError`
/// ⇒ `_payloadFingerprintOf` 返回 null ⇒ 必须判成「变了」。
class _Opaque {
  const _Opaque(this.value);
  final int value;
}

class _OpaqueHarness {
  _OpaqueHarness({required this.cached, required this.next});

  List<_Opaque> cached;
  List<_Opaque> next;
  int bodyRuns = 0;
  int fetchCalls = 0;
  int cacheWrites = 0;
}

final Provider<_OpaqueHarness> _opaqueHarnessProvider = Provider<_OpaqueHarness>(
  (ref) => throw UnimplementedError('测试必须 override'),
);

final FutureProvider<List<_Opaque>> _opaqueSwrProvider =
    FutureProvider<List<_Opaque>>((ref) async {
  final h = ref.watch(_opaqueHarnessProvider);
  h.bodyRuns += 1;
  return fetchWithCacheFallback<List<_Opaque>>(
    ref: ref,
    label: 'b41a-opaque',
    cacheFirst: true,
    fetch: () async {
      h.fetchCalls += 1;
      return h.next;
    },
    cacheWrite: (data) async {
      h.cacheWrites += 1;
      h.cached = data;
    },
    cacheRead: () async =>
        h.cached.isEmpty ? null : List<_Opaque>.of(h.cached),
    failedProvider: _failedProvider,
    errorMessage: 'net-err',
    emptyValue: const <_Opaque>[],
  );
});

/// 建容器并**保持监听**：没有监听者时 `invalidateSelf()` 之后不会真重建，
/// `bodyRuns` 会停住 —— 那样第 2/3/4 条用例会变成恒绿（假绿）。
ProviderContainer _container({
  _Harness? harness,
  _OpaqueHarness? opaque,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      if (harness != null) _harnessProvider.overrideWithValue(harness),
      if (opaque != null) _opaqueHarnessProvider.overrideWithValue(opaque),
      ensureActiveAddressProvider.overrideWith((ref) async => _address()),
    ],
  );
  addTearDown(container.dispose);
  if (harness != null) {
    final sub = container.listen<AsyncValue<List<Playlist>>>(
      _swrProvider,
      (_, _) {},
    );
    addTearDown(sub.close);
  }
  if (opaque != null) {
    final sub = container.listen<AsyncValue<List<_Opaque>>>(
      _opaqueSwrProvider,
      (_, _) {},
    );
    addTearDown(sub.close);
  }
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NetworkErrorNotifier.resetForTest();
    refreshClockForTest = DateTime.now;
    resetRefreshGateForTest();
  });

  tearDown(() {
    NetworkErrorNotifier.resetForTest();
    refreshClockForTest = DateTime.now;
    resetRefreshGateForTest();
  });

  test('内容与顺序完全相同 → 只静默写缓存，不重建 provider', () async {
    final h = _Harness(
      cached: <Playlist>[_pl('p1', '歌单一'), _pl('p2', '歌单二')],
      // 不同对象实例、相同字段值 —— 若实现拿 `==` 或 `toString()` 判等，
      // 这里会分别得到「永不相等」/「永远相等」，两条都会被这条用例抓出来。
      next: <Playlist>[_pl('p1', '歌单一'), _pl('p2', '歌单二')],
    );
    final container = _container(harness: h);
    expect(
      identical(h.cached, h.next),
      isFalse,
      reason: '必须是不同对象实例，否则测的是对象地址而不是载荷指纹',
    );

    final first = await container.read(_swrProvider.future);
    expect(first.length, 2, reason: '首帧应立刻交出缓存');
    expect(h.bodyRuns, 1);
    expect(h.fetchCalls, 0, reason: '缓存优先：首帧不得先发远程请求');

    await pumpEventQueue(); // 后台刷新：fetch → cacheWrite → 指纹相等 → return
    await pumpEventQueue(); // 若真发生了 invalidateSelf，第二轮会跑出第二次 body

    expect(h.fetchCalls, 1, reason: '后台刷新必须真的发了一次远程请求');
    expect(
      h.cacheWrites,
      1,
      reason: '「跳过重建」不等于「跳过写缓存」：新拉到的值必须落盘',
    );
    expect(
      h.lastWritten?.length,
      2,
      reason: '落盘的应当是刚拉回来的新鲜载荷',
    );
    expect(
      h.bodyRuns,
      1,
      reason: '内容一模一样还 invalidateSelf ⇒ 整块闪一帧骨架，'
          '正是用户报的「首页闪一下」',
    );
  });

  test('内容不同 → 正常重建（新值必须真的上屏）', () async {
    final h = _Harness(
      cached: <Playlist>[_pl('p1', '歌单一'), _pl('p2', '歌单二')],
      next: <Playlist>[_pl('p1', '歌单一'), _pl('p2', '歌单二（改名了）')],
    );
    final container = _container(harness: h);

    final first = await container.read(_swrProvider.future);
    expect(first[1].name, '歌单二');
    expect(h.bodyRuns, 1);

    await pumpEventQueue();
    await pumpEventQueue();

    expect(h.fetchCalls, 1);
    expect(
      h.bodyRuns,
      2,
      reason: '内容变了却跳过重建 ⇒ 用户永远看不到更新（比闪一下更严重）',
    );
  });

  test('内容相同但顺序不同 → 视为不同，正常重建', () async {
    final h = _Harness(
      cached: <Playlist>[_pl('p1', '歌单一'), _pl('p2', '歌单二')],
      next: <Playlist>[_pl('p2', '歌单二'), _pl('p1', '歌单一')],
    );
    final container = _container(harness: h);

    await container.read(_swrProvider.future);
    expect(h.bodyRuns, 1);

    await pumpEventQueue();
    await pumpEventQueue();

    expect(
      h.bodyRuns,
      2,
      reason: '顺序变了就是「用户看到的东西变了」，必须重建（jsonEncode '
          '天然保留数组顺序，判等不该把顺序抹平）',
    );
  });

  test('指纹为 null（不可序列化载荷）→ 必须判成「变了」并重建', () async {
    final h = _OpaqueHarness(
      cached: <_Opaque>[const _Opaque(1), const _Opaque(2)],
      next: <_Opaque>[const _Opaque(1), const _Opaque(3)],
    );
    final container = _container(opaque: h);

    final first = await container.read(_opaqueSwrProvider.future);
    expect(first.length, 2);
    expect(h.bodyRuns, 1);

    await pumpEventQueue();
    await pumpEventQueue();

    expect(h.fetchCalls, 1);
    expect(
      h.bodyRuns,
      2,
      reason: '指纹为 null 时必须当成「变了」。否则任何不可 jsonEncode 的载荷'
          '（真实世界里有大量这种模型）会永远不再上屏',
    );
  });
}
