import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/services/apk_cache_paths.dart';
import 'package:musicflow_client/core/services/apk_download_manager.dart';
import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/services/update_checker.dart';

/// 假 HTTP 适配器：不碰网络，直接把 [bytes] 当成 200 响应体。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.bytes, {this.statusCode = 200});

  final List<int> bytes;
  final int statusCode;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    return ResponseBody.fromBytes(
      bytes,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentLengthHeader: <String>['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 合法 apk（zip）头部。
const List<int> _zipHeader = <int>[0x50, 0x4B, 0x03, 0x04];

List<int> _apkBytes(int length) => <int>[
  ..._zipHeader,
  ...List<int>.filled(length - _zipHeader.length, 0x00),
];

/// HTML 错误页（GitHub 限流 / 代理登录页的典型形态）。
const String _htmlError =
    '<!DOCTYPE html><html><body>rate limited</body></html>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('apk_download_test');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ApkDownloadManager.channel, null);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  String pathIn(String name) => '${dir.path}${Platform.pathSeparator}$name';

  /// 装一个 DownloadManager 通道的假实现，返回各方法的调用计数。
  Map<String, int> mockManager({
    required bool available,
    int enqueueResult = 42,
    List<Map<String, Object?>?> queryResults = const <Map<String, Object?>?>[],
    void Function(String fileName)? onCreateFile,
    bool cancelResult = true,
  }) {
    final calls = <String, int>{
      'isAvailable': 0,
      'enqueue': 0,
      'query': 0,
      'cancel': 0,
    };
    var queryIndex = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ApkDownloadManager.channel, (call) async {
          calls[call.method] = (calls[call.method] ?? 0) + 1;
          switch (call.method) {
            case 'isAvailable':
              return available;
            case 'enqueue':
              final args = call.arguments as Map<Object?, Object?>;
              onCreateFile?.call('${args['fileName']}');
              return enqueueResult;
            case 'query':
              if (queryResults.isEmpty) return null;
              final at = queryIndex < queryResults.length
                  ? queryIndex
                  : queryResults.length - 1;
              queryIndex += 1;
              return queryResults[at];
            case 'cancel':
              return cancelResult;
          }
          return null;
        });
    return calls;
  }

  ApkDownloadService dioService(List<int> bytes, {int statusCode = 200}) {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter(bytes, statusCode: statusCode);
    return ApkDownloadService(
      dio: dio,
      platform: TargetPlatform.linux,
      isWeb: false,
      downloadsDirProvider: () async => dir,
      cacheDirProvider: () async => dir,
      pollInterval: Duration.zero,
    );
  }

  ApkDownloadService managerService() => ApkDownloadService(
    platform: TargetPlatform.android,
    isWeb: false,
    downloadsDirProvider: () async => dir,
    cacheDirProvider: () async => dir,
    pollInterval: Duration.zero,
  );

  group('dio 引擎（DownloadManager 不可用时的兜底）', () {
    test('下载成功：落盘 + 校验通过 + 写旁车 meta', () async {
      final bytes = _apkBytes(2048);
      final service = dioService(bytes);
      final file = await service.download(
        ReleaseAsset(
          name: 'MusicFlow-v5141-android.apk',
          downloadUrl: 'https://example.test/a.apk',
          size: bytes.length,
        ),
        version: '5.15.0',
      );

      expect(service.lastEngine, 'dio');
      expect(await file.exists(), isTrue);
      expect(await file.length(), bytes.length);
      final meta = await readApkMeta(file.path);
      expect(meta, isNotNull);
      expect(meta!.version, '5.15.0', reason: '版本来自 latestVersion，不是文件名');
    });

    test('落盘大小与 asset.size 不符 → 删文件并抛', () async {
      final bytes = _apkBytes(1024);
      final service = dioService(bytes);

      await expectLater(
        service.download(
          ReleaseAsset(
            name: 'half.apk',
            downloadUrl: 'https://example.test/a.apk',
            // 声明比实际大：模拟被截断的下载。
            size: bytes.length + 4096,
          ),
        ),
        throwsA(isA<ApkDownloadException>()),
      );
      expect(
        await File(pathIn('half.apk')).exists(),
        isFalse,
        reason: '半截包必须删掉',
      );
    });

    test('返回 HTML 错误页（魔数不对）→ 删文件并抛', () async {
      final service = dioService(_htmlError.codeUnits);

      await expectLater(
        service.download(
          const ReleaseAsset(
            name: 'error.apk',
            downloadUrl: 'https://example.test/a.apk',
            // size=0 ⇒ 跳过大小校验，只靠魔数拦。
            size: 0,
          ),
        ),
        throwsA(isA<ApkDownloadException>()),
      );
      expect(await File(pathIn('error.apk')).exists(), isFalse);
    });
  });

  group('DownloadManager 引擎（Android 首选）', () {
    test('isAvailable == false → 回落 dio，且一次都不 enqueue', () async {
      final calls = mockManager(available: false);
      final bytes = _apkBytes(512);
      final dio = Dio()..httpClientAdapter = _FakeAdapter(bytes);
      final service = ApkDownloadService(
        dio: dio,
        platform: TargetPlatform.android,
        isWeb: false,
        downloadsDirProvider: () async => dir,
        cacheDirProvider: () async => dir,
        pollInterval: Duration.zero,
      );

      final file = await service.download(
        ReleaseAsset(
          name: 'fallback.apk',
          downloadUrl: 'https://example.test/a.apk',
          size: bytes.length,
        ),
      );

      expect(calls['isAvailable'], 1);
      expect(
        calls['enqueue'],
        0,
        reason: 'Available 为假时绝不能碰 DownloadManager，否则会留下一个永不完成的 id',
      );
      expect(service.lastEngine, 'dio');
      expect(await file.exists(), isTrue);
    });

    test('轮询到 successful → 校验通过 + 写 meta + 清 pending id', () async {
      final bytes = _apkBytes(4096);
      final target = pathIn('dm.apk');
      final calls = mockManager(
        available: true,
        onCreateFile: (name) {
          File(pathIn(name)).writeAsBytesSync(bytes);
        },
        queryResults: <Map<String, Object?>?>[
          <String, Object?>{
            'status': 'running',
            'downloaded': 1024,
            'total': bytes.length,
            'localUri': null,
            'reason': 0,
          },
          <String, Object?>{
            'status': 'successful',
            'downloaded': bytes.length,
            'total': bytes.length,
            'localUri': 'file://$target',
            'reason': 0,
          },
        ],
      );
      final service = managerService();
      addTearDown(() => ApkDownloadService.clearPendingDownloadId());

      final progress = <ApkDownloadProgress>[];
      final file = await service.download(
        ReleaseAsset(
          name: 'dm.apk',
          downloadUrl: 'https://example.test/a.apk',
          size: bytes.length,
        ),
        version: '5.15.0',
        notificationTitle: 'MusicFlow 5.15.0',
        notificationDescription: '正在下载',
        onProgress: progress.add,
      );

      expect(service.lastEngine, 'downloadManager');
      expect(calls['enqueue'], 1);
      expect(calls['cancel'], 0, reason: '成功了不该取消');
      expect(file.path, target);
      expect(progress, isNotEmpty, reason: '轮询必须把进度回调出去，否则进度条不走');
      expect(progress.last.fraction, 1.0);
      final meta = await readApkMeta(target);
      expect(meta?.version, '5.15.0');
      expect(
        await ApkDownloadService.pendingDownloadId(),
        isNull,
        reason: '下载收尾后必须清掉持久化的 id',
      );
    });

    test('轮询到 failed → 取消 + 清理 + 抛（带系统 reason）', () async {
      final calls = mockManager(
        available: true,
        queryResults: <Map<String, Object?>?>[
          <String, Object?>{
            'status': 'failed',
            'downloaded': 10,
            'total': 4096,
            'localUri': null,
            'reason': 1006,
          },
        ],
      );
      final service = managerService();
      addTearDown(() => ApkDownloadService.clearPendingDownloadId());

      await expectLater(
        service.download(
          const ReleaseAsset(
            name: 'fail.apk',
            downloadUrl: 'https://example.test/a.apk',
            size: 4096,
          ),
        ),
        throwsA(
          // 系统给的原因码要透出来，便于日志定位（空间不足 / 网络中断…）。
          isA<ApkDownloadException>().having((e) => e.reason, 'reason', 1006),
        ),
      );
      expect(calls['cancel'], 1, reason: '失败必须把系统里的任务 remove 掉');
      expect(await File(pathIn('fail.apk')).exists(), isFalse);
      expect(await ApkDownloadService.pendingDownloadId(), isNull);
    });

    test('开始前就被取消 → 直接抛，且不 enqueue', () async {
      final calls = mockManager(available: true);
      final service = managerService();
      final token = CancelToken()..cancel();

      await expectLater(
        service.download(
          const ReleaseAsset(
            name: 'cancel.apk',
            downloadUrl: 'https://example.test/a.apk',
            size: 4096,
          ),
          cancelToken: token,
        ),
        throwsA(isA<ApkDownloadException>()),
      );
      expect(calls['enqueue'], 0, reason: '已经取消就别再交给系统下载');
    });
  });

  group('安装后复查（时机三）', () {
    test('运行版本已变高 → 删包并返回 true', () async {
      final apk = File(pathIn('installed.apk'));
      await apk.writeAsBytes(_apkBytes(256));
      final service = ApkDownloadService(
        platform: TargetPlatform.android,
        currentVersionReader: () async => '5.15.0',
        downloadsDirProvider: () async => dir,
        cacheDirProvider: () async => dir,
      );

      final applied = await service.recheckInstalledVersion(
        apkPath: apk.path,
        previousVersion: '5.14.1',
      );

      expect(applied, isTrue);
      expect(await apk.exists(), isFalse, reason: '装成功了包就没用了');
    });

    test('运行版本没变（用户点了取消）→ 留着包，返回 false', () async {
      final apk = File(pathIn('pending.apk'));
      await apk.writeAsBytes(_apkBytes(256));
      final service = ApkDownloadService(
        platform: TargetPlatform.android,
        currentVersionReader: () async => '5.14.1',
        downloadsDirProvider: () async => dir,
        cacheDirProvider: () async => dir,
      );

      final applied = await service.recheckInstalledVersion(
        apkPath: apk.path,
        previousVersion: '5.14.1',
      );

      expect(applied, isFalse);
      expect(await apk.exists(), isTrue, reason: '留 24h 让用户直接重试，不必重下几十 MB');
    });
  });
}
