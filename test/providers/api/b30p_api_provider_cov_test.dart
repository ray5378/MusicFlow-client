import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

class _FakeLibraryRepository extends Mock implements LibraryRepository {}

/// 可控的地址池假实现：不发起任何探测，完全由测试驱动内部状态。
class _FakePool extends AddressPool {
  _FakePool() : super(Dio());

  final List<ServerAddress> _addresses = <ServerAddress>[];
  ServerAddress? nextAvailable;

  @override
  List<ServerAddress> get addresses => List<ServerAddress>.of(_addresses);

  @override
  void setAddresses(List<ServerAddress> newAddresses) {
    _addresses
      ..clear()
      ..addAll(newAddresses);
  }

  @override
  ServerAddress? getNextAvailable() => nextAvailable;

  @override
  Future<ServerAddress?> probeAll() async => null;

  @override
  Future<ServerAddress?> waitForActiveAddress([
    Duration timeout = const Duration(milliseconds: 300),
  ]) async =>
      null;
}

/// 指向本机必然拒绝连接的端口：探测瞬间失败，测试无需等待超时。
ServerAddress _address(
  String id, {
  ServerAddressStatus status = ServerAddressStatus.unknown,
}) =>
    ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: 'addr-$id',
      url: 'http://127.0.0.1:9',
      priority: 0,
      status: status,
    );

MusicLibrary _library({List<ServerAddress> addresses = const <ServerAddress>[]}) =>
    MusicLibrary(
      id: 'lib-1',
      name: 'Test Library',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      addresses: addresses,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(_address('fallback'));

  test('已有活跃地址时 ensureActiveAddress 立即返回该地址', () async {
    final addr = _address('a1');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(activeAddressProvider.notifier).state = addr;
    final result = await container.read(ensureActiveAddressProvider.future);

    expect(result.id, 'a1');
  });

  test('预算内未就绪但已配置服务器时回退到最优地址', () async {
    final best = _address('best');
    final pool = _FakePool()
      ..nextAvailable = best
      ..setAddresses([_address('a1'), best]);
    final container = ProviderContainer(
      overrides: <Override>[addressPoolProvider.overrideWithValue(pool)],
    );
    addTearDown(container.dispose);

    final result = await container.read(ensureActiveAddressProvider.future);

    expect(result.id, 'best');
  });

  test('预算内未就绪且无最优地址时回退到地址池首个地址', () async {
    final pool = _FakePool()..setAddresses([_address('a1'), _address('a2')]);
    final container = ProviderContainer(
      overrides: <Override>[addressPoolProvider.overrideWithValue(pool)],
    );
    addTearDown(container.dispose);

    final result = await container.read(ensureActiveAddressProvider.future);

    expect(result.id, 'a1');
  });

  test('完全没有配置服务器时 ensureActiveAddress 抛 StateError', () async {
    final pool = _FakePool();
    final container = ProviderContainer(
      overrides: <Override>[addressPoolProvider.overrideWithValue(pool)],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(ensureActiveAddressProvider.future),
      throwsA(isA<StateError>()),
    );
  });

  test('活跃地址变更回调：同步 UI 状态并切换 dio baseUrl', () async {
    final repository = _FakeLibraryRepository();
    when(() => repository.updateAddress(any())).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    // 直接驱动 addressPoolProvider 注入的回调，避免 setAddresses 触发真实探测
    // （探测结果会在 test 结束后异步回写已 dispose 的 container）。
    final pool = container.read(addressPoolProvider);
    pool.onActiveAddressChanged?.call(
      _address('ok-1', status: ServerAddressStatus.ok),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(activeAddressProvider)?.id, 'ok-1');
    final baseUrl = container.read(dioProvider).options.baseUrl;
    expect(baseUrl, isNotEmpty);
    expect(baseUrl, startsWith('http://127.0.0.1:9'));
    // 归一化去尾斜杠，不能拼出 '//rest/...'
    expect(baseUrl, isNot(endsWith('/')));
  });

  test('地址更新回调：持久化到库仓库', () async {
    final repository = _FakeLibraryRepository();
    final updated = <ServerAddress>[];
    when(() => repository.updateAddress(any())).thenAnswer((invocation) async {
      updated.add(invocation.positionalArguments.first as ServerAddress);
    });

    final container = ProviderContainer(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final pool = container.read(addressPoolProvider);
    pool.onAddressUpdated?.call(_address('a1'));

    expect(updated.map((e) => e.id).toList(), contains('a1'));
  });

  test('地址更新回调：库仓库写入失败只记日志不冒泡', () async {
    final repository = _FakeLibraryRepository();
    var calls = 0;
    when(() => repository.updateAddress(any())).thenAnswer((_) async {
      calls++;
      throw StateError('drift write failed');
    });

    final container = ProviderContainer(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final pool = container.read(addressPoolProvider);

    expect(() => pool.onAddressUpdated?.call(_address('a1')), returnsNormally);
    expect(() => pool.onAddressUpdated?.call(_address('a2')), returnsNormally);
    expect(calls, 2);
  });

  test('活跃库同步器：有活跃库时把其地址灌入地址池', () {
    final container = ProviderContainer(
      overrides: <Override>[
        activeLibraryProvider.overrideWithValue(_library()),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeLibrarySynchronizerProvider);

    expect(container.read(addressPoolProvider).addresses, isEmpty);
  });

  test('活跃库同步器：无活跃库时清空地址池', () {
    final container = ProviderContainer(
      overrides: <Override>[activeLibraryProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    final pool = container.read(addressPoolProvider);
    container.read(activeLibrarySynchronizerProvider);

    expect(pool.addresses, isEmpty);
    expect(pool.activeAddress, isNull);
  });
}
