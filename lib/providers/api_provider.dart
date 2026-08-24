import 'dart:async';

import 'package:dio/dio.dart';
import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/core/network/health_checker.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/server_url_security.dart';

import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/library_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// 1. Basic Dio Provider
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: ApiConstants.connectTimeout,
      receiveTimeout: ApiConstants.receiveTimeout,
      responseType: ResponseType.json,
    ),
  );

  // Logging
  dio.interceptors.add(
    LogInterceptor(
      requestBody: true,
      responseBody: true,
      logPrint: (obj) => Logger.debug(obj.toString()),
    ),
  );

  return dio;
});

// State provider for UI to listen to active address changes
final activeAddressProvider = StateProvider<ServerAddress?>((ref) => null);

/// Ensure an active address is ready before making network requests.
/// 冷启动加速:活跃地址在 AddressPool.setAddresses 时已从持久化状态立即恢复,
/// 这里只做极短兜底(≤2s)等待探测结果;超时直接报错让调用方回退本地缓存,
/// 不再等待可能拖满 5s 的全量探测,避免把首屏拖到 5-6s。
final ensureActiveAddressProvider = FutureProvider<ServerAddress>((ref) async {
  final active = ref.read(activeAddressProvider);
  if (active != null) return active;

  Logger.warnWithTag('API', 'no active address, probing before request');
  final pool = ref.read(addressPoolProvider);
  unawaited(pool.probeAll());

  final start = DateTime.now();
  var ticks = 0;
  while (DateTime.now().difference(start) < const Duration(seconds: 2)) {
    final current = ref.read(activeAddressProvider);
    if (current != null) return current;

    if (ticks % 5 == 0 && pool.addresses.isNotEmpty) {
      unawaited(pool.probeAll());
    }
    ticks++;

    await Future.delayed(const Duration(milliseconds: 200));
  }

  // 未在预算内拿到活跃地址:直接报错,由调用方(缓存先行/回退)接管,不再等慢探测。
  Logger.errorWithTag(
    'API',
    'failed to acquire active server address within budget',
  );
  throw StateError('No active server address available');
});

// 自动回退开关 Provider
final autoFallbackProvider = StateProvider<bool>((ref) => true);

// 初始化自动回退设置（从本地存储读取）
final autoFallbackInitProvider = FutureProvider<bool>((ref) async {
  final value = await LocalStorage.getAutoFallback();
  ref.read(autoFallbackProvider.notifier).state = value;
  // 同步到 AddressPool
  ref.read(addressPoolProvider).autoFallback = value;
  Logger.infoWithTag('API', 'autoFallback initialized: $value');
  return value;
});

// 2. AddressPool Provider
// It listens to activeLibrary and updates addresses
final addressPoolProvider = Provider<AddressPool>((ref) {
  // final dio = ref.watch(dioProvider); // Use same dio or separate?
  // AddressPool needs to probe. It can use the same dio instance,
  // but we must be careful not to trigger FallbackInterceptor RECURSIVELY if we attach it to this dio.
  // Ideally AddressPool uses a clean Dio or a separate one for probing.

  // Let's create a separate simple dio for probing to avoid interference
  final probeDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  );

  final pool = AddressPool(
    probeDio,
    onAddressUpdated: (addr) {
      unawaited(
        ref.read(libraryRepositoryProvider).updateAddress(addr).catchError((e) {
          Logger.warnWithTag(
            'API',
            'failed to persist address update: ${addr.label}',
            e,
          );
        }),
      );
    },
    onActiveAddressChanged: (addr) {
      // Update UI state
      Future.microtask(() {
        ref.read(activeAddressProvider.notifier).state = addr;
      });

      if (addr != null) {
        // Update MAIN dio base URL
        // We can't access 'dioProvider' value inside this callback easily if not captured.
        // But we can use 'ref.read(dioProvider)'.
        // However, 'dioProvider' returns a Dio.
        final mainDio = ref.read(dioProvider);
        // 归一化去尾斜杠：封面/流 URL 复用 dio.options.baseUrl 做手工拼接,
        // 带尾斜杠会拼出 '//rest/...'（服务端返回 200 + SPA HTML → 静默全挂）。
        final normalized = normalizeServerBaseUrl(addr.url);
        if (mainDio.options.baseUrl != normalized) {
          mainDio.options.baseUrl = normalized;
          Logger.infoWithTag('API', 'switched base URL to: $normalized');
        }
      }
    },
  );

  return pool;
});

// 3. FallbackInterceptor Logic
// We need to attach the interceptor to the MAIN Dio.
// But Providers are lazy. modifying the provided object instance (Dio) inside another provider is tricky
// if dio is reused.
// A better way is to create a "configuredDioProvider".

final configuredDioProvider = Provider<Dio>((ref) {
  final dio = ref.watch(dioProvider);
  final addressPool = ref.watch(addressPoolProvider);

  // Avoid adding interceptor multiple times
  if (!dio.interceptors.any((i) => i is FallbackInterceptor)) {
    dio.interceptors.add(FallbackInterceptor(addressPool, dio));
    Logger.infoWithTag('API', 'fallback interceptor attached');
  }

  return dio;
});

// 4. Connectivity & Health Monitors
// These should be alive as long as the app is running or we are in a session.
// We can make a "NetworkManager" class or just effect providers.

final connectivityMonitorProvider = Provider<ConnectivityMonitor>((ref) {
  final pool = ref.watch(addressPoolProvider);
  final monitor = ConnectivityMonitor(pool);
  monitor.start();
  ref.onDispose(() => monitor.stop());
  return monitor;
});

final networkManagerProvider = Provider<void>((ref) {
  // 初始化自动回退设置
  ref.watch(autoFallbackInitProvider);

  // 使用共享的 ConnectivityMonitor
  ref.watch(connectivityMonitorProvider);

  final pool = ref.watch(addressPoolProvider);
  final healthChecker = HealthChecker(pool);
  healthChecker.start();
  Logger.infoWithTag('API', 'network manager started');

  ref.onDispose(() {
    healthChecker.stop();
    Logger.infoWithTag('API', 'network manager disposed');
  });
});

// 5. Wire Active Library to AddressPool
// This is an effect. When active library changes, we update the pool.
final activeLibrarySynchronizerProvider = Provider<void>((ref) {
  final activeLib = ref.watch(activeLibraryProvider);
  final pool = ref.watch(addressPoolProvider);

  if (activeLib != null) {
    Logger.infoWithTag(
      'API',
      'sync active library: ${activeLib.name} addresses=${activeLib.addresses.length}',
    );
    pool.setAddresses(activeLib.addresses);
  } else {
    Logger.warnWithTag('API', 'no active library, clear address pool');
    pool.setAddresses([]);
  }
});

// 6. SubsonicApiClient Provider
final subsonicApiClientProvider = Provider<SubsonicApiClient>((ref) {
  final dio = ref.watch(configuredDioProvider);

  // Ensure monitors are running
  ref.watch(networkManagerProvider);
  ref.watch(activeLibrarySynchronizerProvider);

  final client = SubsonicApiClient(dio: dio);

  // Set config from active library
  final activeLib = ref.watch(activeLibraryProvider);
  client.setLibrary(activeLib);
  Logger.debugWithTag(
    'API',
    'client bound to library=${activeLib?.id ?? 'none'}',
  );

  return client;
});
