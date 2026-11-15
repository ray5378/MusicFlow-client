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

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/network/fallback_interceptor.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/player/favorite_scrobble_handler.dart';

class _MockConnectivityMonitor extends Mock implements ConnectivityMonitor {}

/// 一个「不发真网络、只把 RequestOptions 抓下来」的 client 装配结果。
class _CapturingSetup {
  _CapturingSetup(this.handler, this.captured);

  final FavoriteScrobbleHandler handler;
  final List<RequestOptions> captured;
}

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

  // `/rest/scrobble` 在规范里是 GET，**但语义是写**（播放计数 +1 / 正在播放
  // 状态），批 A 让单地址也会重放之后，必须显式关掉它的自动重放，否则一次
  // 抖动 = 播放计数虚高（用户可见）。这里钉的就是那一行 `allowFallbackRetry:
  // false`：删掉它，本组两条必须红。
  group('scrobble 关闭自动重放（有副作用的写操作）', () {
    _CapturingSetup setupCapturing() {
      final captured = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, interceptorHandler) {
            captured.add(options);
            // 直接短路：不真的发请求，只关心「调用方给 Dio 塞了什么 extra」。
            interceptorHandler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                data: <String, dynamic>{
                  'subsonic-response': <String, dynamic>{'status': 'ok'},
                },
              ),
            );
          },
        ),
      );
      final c = ProviderContainer(
        overrides: <Override>[
          connectivityMonitorProvider.overrideWith((ref) => connectivity),
          subsonicApiClientProvider.overrideWithValue(
            SubsonicApiClient(dio: dio),
          ),
        ],
      );
      addTearDown(c.dispose);
      return _CapturingSetup(c.read(_handlerProvider), captured);
    }

    test('submission: true（真实播放上报）→ allowFallbackRetry 必须为 false',
        () async {
      final setup = setupCapturing();

      await setup.handler.scrobble('song-1', submission: true);

      expect(setup.captured, hasLength(1));
      final options = setup.captured.single;
      expect(
        options.method,
        'GET',
        reason: '服务端只注册了 GET，换成 POST 会 404（2026-09-15 实测）',
      );
      expect(options.path, '/rest/scrobble');
      expect(options.queryParameters['submission'], 'true');
      expect(
        options.extra[FallbackInterceptor.allowRetryExtraKey],
        isFalse,
        reason: 'submission=true 重放一次就让服务端播放计数 +1（播放历史/推荐/'
            '统计全部虚高），必须关闭自动重放',
      );
    });

    test('submission: false（正在播放状态）→ 同样关闭自动重放', () async {
      final setup = setupCapturing();

      await setup.handler.scrobble('song-1', submission: false);

      final options = setup.captured.single;
      expect(options.queryParameters['submission'], 'false');
      expect(
        options.extra[FallbackInterceptor.allowRetryExtraKey],
        isFalse,
        reason: 'submission=false 也是写服务端「正在播放」状态，重放会把状态机'
            '推乱 —— 两个 submission 值共用同一处调用，一起关',
      );
    });
  });
}
