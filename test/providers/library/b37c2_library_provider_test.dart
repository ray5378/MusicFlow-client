// batch37 C(2) —— `lib/providers/library/library_provider.dart` 剩余未覆盖分支。
//
// 既有 b33b_library_provider_test 覆盖：空库→null / 活跃库 / 无活跃标志回落首库 /
// 流错误→null / loading→null / 同库重复发射同一实例。
// 本文件补深分支：
//   * 有库切到空库 → 走「no libraries available」日志分支（84-86）；
//   * 活跃库 id 变化 → 返回新库并走「active library -> name」日志（112-114）；
//   * _libraryKeyFieldsEqual 的 extensions 深比较（_deepEquals）分支：
//       - 同一 Map 引用（identical 短路，55）；
//       - 标量相等（a == b，74）；
//       - 嵌套 Map 长度不等 / key 缺失 / 值不等（56-63）；
//       - List 长度不等 / 元素不等（65-72）；
//   * addresses 关键字段比较 _addressKeyFieldsEqual（19-26）：
//       - 仅 latency/status 变化 → 视为相等 → 返回同一实例；
//       - label/url/priority/isLocked 变化 → 视为不等 → 返回新实例。
//
// 说明：`_lastActiveLibrary` 是文件级全局可变状态；本文件每个用例都从一条
// 明确的发射序列开始，结论只依赖该序列内的相对行为，避免用例间串味。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

class _FakeLibraryRepository extends Mock implements LibraryRepository {}

MusicLibrary _lib(
  String id, {
  String? name,
  bool active = false,
  Map<String, dynamic>? extensions,
  List<ServerAddress>? addresses,
}) =>
    MusicLibrary(
      id: id,
      name: name ?? 'Lib $id',
      isActive: active,
      extensions: extensions ?? const <String, dynamic>{},
      addresses: addresses ?? const <ServerAddress>[],
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

ServerAddress _addr(
  String id, {
  String libraryId = 'lib',
  String label = '默认',
  String url = 'http://h',
  int priority = 0,
  bool locked = false,
  int? latency,
  ServerAddressStatus status = ServerAddressStatus.unknown,
}) =>
    ServerAddress(
      id: id,
      libraryId: libraryId,
      label: label,
      url: url,
      priority: priority,
      isLocked: locked,
      lastLatencyMs: latency,
      status: status,
    );

class _Harness {
  _Harness() {
    when(() => repo.watchLibraries()).thenAnswer((_) => ctrl.stream);
    container = ProviderContainer(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    // 预先订阅 librariesProvider：StreamProvider 只在首次被读/监听时才订阅
    // ctrl.stream；若先 add 再首次读，首个事件会因「读发生在订阅前」而错过。
    container.listen(librariesProvider, (_, _) {});
    addTearDown(ctrl.close);
    addTearDown(container.dispose);
  }

  final _FakeLibraryRepository repo = _FakeLibraryRepository();
  final StreamController<List<MusicLibrary>> ctrl =
      StreamController<List<MusicLibrary>>();
  late final ProviderContainer container;

  /// 发射一批库并等待 activeLibraryProvider 重算。
  Future<MusicLibrary?> emit(List<MusicLibrary> libs) async {
    ctrl.add(libs);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return container.read(activeLibraryProvider);
  }
}

void main() {
  test('有库切到空库 → 返回 null（走 no libraries available 分支）', () async {
    final h = _Harness();
    final first = await h.emit(<MusicLibrary>[_lib('a', active: true)]);
    expect(first?.id, 'a');

    final afterEmpty = await h.emit(<MusicLibrary>[]);
    expect(afterEmpty, isNull, reason: '非空切空 → 活跃库置空');
  });

  test('活跃库 id 变化 → 返回新库实例（走 active library -> name 分支）', () async {
    final h = _Harness();
    final a = await h.emit(<MusicLibrary>[_lib('a', active: true)]);
    final b = await h.emit(<MusicLibrary>[_lib('b', active: true, name: '二号库')]);

    expect(a?.id, 'a');
    expect(b?.id, 'b');
    expect(identical(a, b), isFalse, reason: '不同库 id 必返回新实例');
  });

  test('extensions 深比较：同一引用/标量相等/嵌套相等 → 返回同一实例', () async {
    final h = _Harness();

    // 同一 Map 引用：identical 短路。
    final shared = <String, dynamic>{'same': 1};
    final first = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: shared),
    ]);
    final same = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: shared),
    ]);
    expect(identical(first, same), isTrue, reason: 'extensions 同引用 → identical');

    // 标量相等（a == b）。
    final scalarA = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{'n': 5}),
    ]);
    final scalarB = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{'n': 5}),
    ]);
    expect(identical(scalarA, scalarB), isTrue, reason: 'extensions 标量相等 → 同一实例');

    // 嵌套 Map/List 深度相等（非同一引用）。
    final nestedA = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{
        'k': <String, dynamic>{
          'nested': <int>[1, 2],
        },
      }),
    ]);
    final nestedB = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{
        'k': <String, dynamic>{
          'nested': <int>[1, 2],
        },
      }),
    ]);
    expect(identical(nestedA, nestedB), isTrue, reason: '嵌套 Map/List 深度相等 → 同一实例');
  });

  test('extensions 深度不等（key 缺失 / 长度 / 值 / List 元素）→ 返回新实例', () async {
    final h = _Harness();
    final base = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{'k': 1}),
    ]);

    // key 缺失（b 不含 a 的 key）。
    final missingKey = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{'j': 1}),
    ]);
    expect(identical(base, missingKey), isFalse, reason: 'key 缺失 → 不等');

    // 长度不等。
    final lenDiff = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{'k': 1, 'j': 2}),
    ]);
    expect(identical(base, lenDiff), isFalse, reason: 'Map 长度不等 → 不等');

    // 值不等。
    final valDiff = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{'k': 2}),
    ]);
    expect(identical(base, valDiff), isFalse, reason: '值不等 → 不等');

    // List 元素不等。
    final listBase = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{
        'l': <int>[1, 2],
      }),
    ]);
    final listDiff = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{
        'l': <int>[1, 3],
      }),
    ]);
    expect(identical(listBase, listDiff), isFalse, reason: 'List 元素不等 → 不等');

    // List 长度不等。
    final listLen = await h.emit(<MusicLibrary>[
      _lib('a', active: true, extensions: <String, dynamic>{
        'l': <int>[1, 2, 3],
      }),
    ]);
    expect(identical(listDiff, listLen), isFalse, reason: 'List 长度不等 → 不等');
  });

  test('addresses 仅 latency/status 变化 → 返回同一实例（忽略探测数据）', () async {
    final h = _Harness();
    final first = await h.emit(<MusicLibrary>[
      _lib('a', active: true, addresses: <ServerAddress>[_addr('ad1', latency: 5)]),
    ]);
    final second = await h.emit(<MusicLibrary>[
      _lib('a', active: true, addresses: <ServerAddress>[
        _addr('ad1', latency: 999, status: ServerAddressStatus.ok),
      ]),
    ]);
    expect(identical(first, second), isTrue,
        reason: '关键字段一致、仅 latency/status 变化 → 返回同一实例');
  });

  test('addresses 关键字段变化（label/url/priority/isLocked）→ 返回新实例', () async {
    final h = _Harness();
    final base = await h.emit(<MusicLibrary>[
      _lib('a', active: true, addresses: <ServerAddress>[_addr('ad1')]),
    ]);

    final labelDiff = await h.emit(<MusicLibrary>[
      _lib('a', active: true, addresses: <ServerAddress>[_addr('ad1', label: '改名')]),
    ]);
    expect(identical(base, labelDiff), isFalse, reason: 'label 变化 → 不等');

    final urlDiff = await h.emit(<MusicLibrary>[
      _lib('a', active: true, addresses: <ServerAddress>[_addr('ad1', url: 'http://x')]),
    ]);
    expect(identical(base, urlDiff), isFalse, reason: 'url 变化 → 不等');

    final prioDiff = await h.emit(<MusicLibrary>[
      _lib('a', active: true, addresses: <ServerAddress>[_addr('ad1', priority: 3)]),
    ]);
    expect(identical(base, prioDiff), isFalse, reason: 'priority 变化 → 不等');

    final lockDiff = await h.emit(<MusicLibrary>[
      _lib('a', active: true, addresses: <ServerAddress>[_addr('ad1', locked: true)]),
    ]);
    expect(identical(base, lockDiff), isFalse, reason: 'isLocked 变化 → 不等');
  });
}
