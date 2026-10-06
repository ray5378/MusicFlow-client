// batch37-A：`lib/providers/player/favorite_scrobble_handler.dart` 里唯一整段
// 未覆盖的方法 —— `recordMobileCacheSavedBytesForHit`（源码 53-86）。
//
// 覆盖目标（lcov 未命中行）：
//   59  libraryId 为空 → 直接 return（不碰连通性/文件）
//   62-65 网络类型非移动 → return
//   67 缓存文件不存在 → return
//   68-69 文件长度为 0 → return
//   71-78 命中：累计写入 LocalStorage 并落日志
//   79-85 任意异常（这里用「读连通性 provider 即抛」）→ catch 只记日志不外抛
//
// 说明：`ConnectivityMonitor` 是具体类，这里用 mocktail 子类型桩接管
// `currentNetworkType`；`fileExists` / `fileLength` 走真实 dart:io，
// 用临时文件造「存在且非空」的命中条件。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/favorite_scrobble_handler.dart';

class _MockConnectivityMonitor extends Mock implements ConnectivityMonitor {}

/// 通过一个 provider 拿到带合法 `Ref` 的处理器实例（`Handler` 的构造只吃 Ref）。
final _handlerProvider = Provider<FavoriteScrobbleHandler>(
  (ref) => FavoriteScrobbleHandler(ref),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  late _MockConnectivityMonitor connectivity;
  late ProviderContainer container;
  late FavoriteScrobbleHandler handler;

  setUp(() {
    connectivity = _MockConnectivityMonitor();
    when(() => connectivity.currentNetworkType).thenReturn(NetworkType.mobile);
    container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWith((ref) => connectivity),
      ],
    );
    handler = container.read(_handlerProvider);
  });

  tearDown(() => container.dispose());

  group('recordMobileCacheSavedBytesForHit', () {
    test('libraryId 为空 → 59 行早退，连通性与文件都不碰', () async {
      var touched = false;
      when(() => connectivity.currentNetworkType).thenAnswer((_) {
        touched = true;
        return NetworkType.mobile;
      });

      await handler.recordMobileCacheSavedBytesForHit(
        songId: 's1',
        cacheFilePath: '/definitely/missing.flac',
        libraryId: '',
      );

      expect(touched, isFalse, reason: '59 行必须在读连通性之前 return');
    });

    test('网络类型非移动 → 65 行 return，不写存储', () async {
      final dir = Directory.systemTemp.createTempSync('b37a_scrobble_wifi');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/cache.flac')..writeAsBytesSync(List<int>.filled(8, 7));
      when(() => connectivity.currentNetworkType).thenReturn(NetworkType.wifi);

      await handler.recordMobileCacheSavedBytesForHit(
        songId: 's1',
        cacheFilePath: f.path,
        libraryId: 'lib1',
      );

      expect(
        await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'),
        0,
        reason: '非移动网络不应记流量',
      );
    });

    test('缓存文件不存在 → 67 行 return', () async {
      await handler.recordMobileCacheSavedBytesForHit(
        songId: 's1',
        cacheFilePath: '/no/such/file.flac',
        libraryId: 'lib1',
      );

      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'), 0);
    });

    test('文件长度为 0 → 69 行 return', () async {
      final dir = Directory.systemTemp.createTempSync('b37a_scrobble_empty');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/empty.flac')..writeAsBytesSync(<int>[]);

      await handler.recordMobileCacheSavedBytesForHit(
        songId: 's1',
        cacheFilePath: f.path,
        libraryId: 'lib1',
      );

      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'), 0);
    });

    test('移动网络 + 非空缓存文件 → 71-78 行累计写入节省流量', () async {
      final dir = Directory.systemTemp.createTempSync('b37a_scrobble_hit');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/cache.flac')
        ..writeAsBytesSync(List<int>.filled(4096, 1));

      await handler.recordMobileCacheSavedBytesForHit(
        songId: 's1',
        cacheFilePath: f.path,
        libraryId: 'lib1',
      );

      expect(
        await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'),
        4096,
        reason: '命中路径必须把真实字节数记进对应库',
      );

      // 二次命中应叠加而非覆盖。
      await handler.recordMobileCacheSavedBytesForHit(
        songId: 's2',
        cacheFilePath: f.path,
        libraryId: 'lib1',
      );
      expect(
        await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'),
        8192,
      );
    });

    test('读连通性抛异常 → 79-85 行 catch 只吞日志，不外抛', () async {
      final throwing = ProviderContainer(
        overrides: <Override>[
          connectivityMonitorProvider.overrideWith(
            (ref) => throw StateError('connectivity boom'),
          ),
        ],
      );
      addTearDown(throwing.dispose);
      final h = throwing.read(_handlerProvider);

      await expectLater(
        h.recordMobileCacheSavedBytesForHit(
          songId: 's1',
          cacheFilePath: '/whatever.flac',
          libraryId: 'lib1',
        ),
        completes,
      );
    });
  });
}
