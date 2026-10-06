import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

class _FakeLibraryRepository extends Mock implements LibraryRepository {}

MusicLibrary _lib(String id, {bool active = false}) => MusicLibrary(
      id: id,
      name: 'Lib $id',
      isActive: active,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

ProviderContainer _container(LibraryRepository repo) => ProviderContainer(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );

/// 等待 librariesProvider 真正收到首条数据, 再读取 activeLibraryProvider。
Future<void> _pumpUntilData(ProviderContainer container) async {
  await container.read(librariesProvider.future);
}

void main() {
  test('activeLibraryProvider: 空库列表 → null', () async {
    final repo = _FakeLibraryRepository();
    final ctrl = StreamController<List<MusicLibrary>>();
    when(() => repo.watchLibraries()).thenAnswer((_) => ctrl.stream);
    addTearDown(ctrl.close);
    final container = _container(repo);
    addTearDown(container.dispose);

    ctrl.add(<MusicLibrary>[]);
    await _pumpUntilData(container);
    expect(container.read(activeLibraryProvider), isNull);
  });

  test('activeLibraryProvider: 有活跃库 → 返回活跃库', () async {
    final repo = _FakeLibraryRepository();
    final ctrl = StreamController<List<MusicLibrary>>();
    when(() => repo.watchLibraries()).thenAnswer((_) => ctrl.stream);
    addTearDown(ctrl.close);
    final container = _container(repo);
    addTearDown(container.dispose);

    ctrl.add(<MusicLibrary>[
      _lib('a'),
      _lib('b', active: true),
      _lib('c'),
    ]);
    await _pumpUntilData(container);
    expect(container.read(activeLibraryProvider)?.id, 'b');
  });

  test('activeLibraryProvider: 无活跃标志 → 回退到首个库', () async {
    final repo = _FakeLibraryRepository();
    final ctrl = StreamController<List<MusicLibrary>>();
    when(() => repo.watchLibraries()).thenAnswer((_) => ctrl.stream);
    addTearDown(ctrl.close);
    final container = _container(repo);
    addTearDown(container.dispose);

    ctrl.add(<MusicLibrary>[_lib('a'), _lib('b'), _lib('c')]);
    await _pumpUntilData(container);
    expect(container.read(activeLibraryProvider)?.id, 'a');
  });

  test('activeLibraryProvider: 流错误 → null', () async {
    final repo = _FakeLibraryRepository();
    final ctrl = StreamController<List<MusicLibrary>>();
    when(() => repo.watchLibraries()).thenAnswer((_) => ctrl.stream);
    addTearDown(ctrl.close);
    final container = _container(repo);
    addTearDown(container.dispose);

    ctrl.addError(StateError('db'));
    await Future<void>.delayed(Duration(milliseconds: 20));
    expect(container.read(activeLibraryProvider), isNull);
  });

  test('activeLibraryProvider: 流尚未发射(loading) → null', () {
    final repo = _FakeLibraryRepository();
    final ctrl = StreamController<List<MusicLibrary>>();
    when(() => repo.watchLibraries()).thenAnswer((_) => ctrl.stream);
    addTearDown(ctrl.close);
    final container = _container(repo);
    addTearDown(container.dispose);

    // 还没有任何事件, librariesProvider 处于 loading, 活跃库为 null。
    expect(container.read(activeLibraryProvider), isNull);
  });

  test('activeLibraryProvider: 同一活跃库重复发射返回同一实例(避免重建)', () async {
    final repo = _FakeLibraryRepository();
    final ctrl = StreamController<List<MusicLibrary>>();
    when(() => repo.watchLibraries()).thenAnswer((_) => ctrl.stream);
    addTearDown(ctrl.close);
    final container = _container(repo);
    addTearDown(container.dispose);

    ctrl.add(<MusicLibrary>[_lib('b', active: true)]);
    await _pumpUntilData(container);
    final first = container.read(activeLibraryProvider);
    ctrl.add(<MusicLibrary>[_lib('b', active: true)]);
    await Future<void>.delayed(Duration(milliseconds: 20));
    final second = container.read(activeLibraryProvider);
    expect(first, isNotNull);
    expect(identical(first, second), isTrue);
  });
}
