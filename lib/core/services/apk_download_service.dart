import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/services/apk_cache_janitor.dart';
import 'package:musicflow_client/core/services/apk_cache_paths.dart';
import 'package:musicflow_client/core/services/apk_download_manager.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/utils/logger.dart';

const String _logTag = 'APK_DLOW';

/// 进度回调的最小间隔（Dio 引擎每收到一个 chunk 都会回调，直接刷 UI 会把
/// 主线程打满；200ms 已经足够让进度条看起来是连续的）。
const Duration kApkProgressThrottle = Duration(milliseconds: 200);

/// DownloadManager 引擎的轮询间隔。
const Duration kApkDownloadPollInterval = Duration(milliseconds: 500);

/// dio 引擎单次读取的超时（几十 MB 的包在慢网下远超默认 10s）。
const Duration kApkDioReceiveTimeout = Duration(seconds: 60);

/// 持久化「上一次没走完的下载 id」的 SharedPreferences 键。
const String kPendingApkDownloadIdKey = 'pending_apk_download_id';

/// zip（apk 就是 zip）本地文件头魔数。
const List<int> kZipMagicLocalHeader = <int>[0x50, 0x4B, 0x03, 0x04];

/// zip 空归档魔数（极少数打包工具会产出这种「只有中央目录」的包）。
const List<int> kZipMagicEmptyArchive = <int>[0x50, 0x4B, 0x05, 0x06];

/// 下载进度快照。
@immutable
class ApkDownloadProgress {
  const ApkDownloadProgress({
    required this.received,
    required this.total,
    this.speedBytesPerSec = 0,
  });

  final int received;

  /// 总字节数；未知时为 0。
  final int total;

  /// 估算速度（字节/秒）；无法估算时为 0。
  final double speedBytesPerSec;

  /// 0~1 的完成度；总量未知时为 0。
  double get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0.0;

  @override
  String toString() =>
      'ApkDownloadProgress($received/$total, ${fraction.toStringAsFixed(2)})';
}

/// 安装包下载失败（校验不过 / 通道失败 / 系统报错 / 被取消）。
///
/// 抛出前**一定**已经把半截文件删干净了 —— 调用方不需要再操心清理。
class ApkDownloadException implements Exception {
  const ApkDownloadException(this.message, {this.reason});

  final String message;

  /// DownloadManager 给的 `COLUMN_REASON`（非 DownloadManager 路径为 null）。
  final int? reason;

  @override
  String toString() => 'ApkDownloadException($message)';
}

/// 上一次下载的收尾状态（用于「App 被杀后再回来」的判定）。
enum ApkPendingOutcome {
  /// 没有待收尾的下载。
  none,

  /// 系统还在下（或排队中），保留 id 等下次续看。
  running,

  /// 下载已完成，文件已校验并写好 meta。
  completed,

  /// 下载失败/已取消，记录与文件都已清掉。
  discarded,
}

/// 安装包下载服务：**双引擎**，对外签名不变。
///
/// ## 引擎选择（不做「前台 dio / 后台 DownloadManager」的分叉）
///
/// Android 且 `DownloadManager.isAvailable()` → 系统 `DownloadManager`：
/// 通知栏进度条、杀进程不断、302 自动跟随、失败自动重试，全由系统负责。
/// 其余情况（桌面、异常 ROM）→ 原有 Dio 引擎。
///
/// 刻意**不**按「App 在前台还是后台」分叉：两套路径行为不一致，必然养出一个
/// 「偶发、只在某种切换顺序下复现」的诡异 bug。
///
/// ## 两道完整性校验（缺一不可）
///
/// 1. `asset.size > 0` 时，落盘大小必须**严格等于**它；
/// 2. 前 4 字节必须是 zip 魔数 —— 挡掉 GitHub 的 HTML 错误页、半截包、
///    代理注入的登录页。
///
/// 任一不过 → 删文件 + 抛 [ApkDownloadException]。
class ApkDownloadService {
  ApkDownloadService({
    ApkDownloadManager? downloadManager,
    Dio? dio,
    TargetPlatform? platform,
    bool? isWeb,
    Future<Directory?> Function()? downloadsDirProvider,
    Future<Directory?> Function()? cacheDirProvider,
    Future<String> Function()? currentVersionReader,
    Duration pollInterval = kApkDownloadPollInterval,
  }) : _manager = downloadManager ?? ApkDownloadManager(),
       _platform = platform,
       _isWeb = isWeb,
       _downloadsDirProvider = downloadsDirProvider ?? apkDownloadsDir,
       _cacheDirProvider = cacheDirProvider ?? apkCacheDir,
       _currentVersionReader = currentVersionReader ?? _defaultCurrentVersion,
       _pollInterval = pollInterval,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: kApkDioReceiveTimeout,
               followRedirects: true,
               maxRedirects: 8,
             ),
           );

  final ApkDownloadManager _manager;
  final Dio _dio;
  final TargetPlatform? _platform;
  final bool? _isWeb;
  final Future<Directory?> Function() _downloadsDirProvider;
  final Future<Directory?> Function() _cacheDirProvider;
  final Future<String> Function() _currentVersionReader;
  final Duration _pollInterval;

  /// 最近一次交给 DownloadManager 的 id（取消时要按它 remove）。
  @visibleForTesting
  int? activeDownloadId;

  /// 最近一次实际使用的引擎（测试断言用）。
  @visibleForTesting
  String? lastEngine;

  TargetPlatform get _target => _platform ?? defaultTargetPlatform;

  bool get _onAndroid =>
      !(_isWeb ?? kIsWeb) && _target == TargetPlatform.android;

  /// 下载 [asset] 并返回落盘文件。
  ///
  /// [version] 是**下这个包时**的最新版本号（`UpdateCheckResult.latestVersion`），
  /// 会写进旁车 meta 供启动清理判定。为 null 时不写 meta（该包会被当作孤儿，
  /// 下次启动清掉）—— 生产路径必须传。
  Future<File> download(
    ReleaseAsset asset, {
    void Function(ApkDownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
    String? version,
    String? notificationTitle,
    String? notificationDescription,
    Directory? overrideDir,
  }) async {
    if (asset.downloadUrl.trim().isEmpty) {
      throw const ApkDownloadException('empty download url');
    }
    if (await _useDownloadManager()) {
      return _downloadViaManager(
        asset,
        onProgress: onProgress,
        cancelToken: cancelToken,
        version: version,
        notificationTitle: notificationTitle,
        notificationDescription: notificationDescription,
        overrideDir: overrideDir,
      );
    }
    return _downloadViaDio(
      asset,
      onProgress: onProgress,
      cancelToken: cancelToken,
      version: version,
      overrideDir: overrideDir,
    );
  }

  // ───────────────────────── DownloadManager 引擎 ─────────────────────────

  Future<bool> _useDownloadManager() async {
    if (!_onAndroid) return false;
    final available = await _manager.isAvailable();
    if (!available) {
      Logger.infoWithTag(
        _logTag,
        'DownloadManager unavailable, falling back to dio engine',
      );
    }
    return available;
  }

  Future<File> _downloadViaManager(
    ReleaseAsset asset, {
    void Function(ApkDownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
    String? version,
    String? notificationTitle,
    String? notificationDescription,
    Directory? overrideDir,
  }) async {
    lastEngine = 'downloadManager';
    final dir = overrideDir ?? await _downloadsDirProvider();
    if (dir == null) {
      throw const ApkDownloadException('external files dir unavailable');
    }
    await _prepareDir(dir, asset: asset, version: version);

    if (cancelToken?.isCancelled ?? false) {
      throw const ApkDownloadException('cancelled before start');
    }

    final id = await _manager.enqueue(
      url: asset.downloadUrl,
      fileName: asset.name,
      title: notificationTitle ?? asset.name,
      description: notificationDescription ?? '',
    );
    if (id == null) {
      throw const ApkDownloadException('enqueue failed');
    }
    activeDownloadId = id;
    await _rememberPendingId(id);

    final startedAt = DateTime.now();
    var lastReceived = 0;
    while (true) {
      if (cancelToken?.isCancelled ?? false) {
        await _cancelAndCleanup(id, dir, asset.name);
        throw const ApkDownloadException('cancelled');
      }
      final status = await _manager.query(id);
      if (status == null) {
        // 查不到（通道抖了一下）：不判死，继续轮询。
        await Future<void>.delayed(_pollInterval);
        continue;
      }
      final total = status.total > 0 ? status.total : asset.size;
      onProgress?.call(
        ApkDownloadProgress(
          received: status.downloaded,
          total: total,
          speedBytesPerSec: _speed(
            status.downloaded - lastReceived,
            DateTime.now().difference(startedAt),
          ),
        ),
      );
      lastReceived = status.downloaded;

      if (status.isSuccessful) {
        final path =
            status.localPath ??
            '${dir.path}${Platform.pathSeparator}${asset.name}';
        final file = File(path);
        await _validate(file, asset);
        await _writeMeta(file, version);
        await clearPendingDownloadId();
        activeDownloadId = null;
        return file;
      }
      if (status.isFailed) {
        await _cancelAndCleanup(id, dir, asset.name);
        throw ApkDownloadException(
          'download failed reason=${status.reason}',
          reason: status.reason,
        );
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  Future<void> _cancelAndCleanup(int id, Directory dir, String fileName) async {
    await _manager.cancel(id);
    activeDownloadId = null;
    await clearPendingDownloadId();
    await deleteApkWithMeta('${dir.path}${Platform.pathSeparator}$fileName');
  }

  // ───────────────────────────── dio 引擎 ─────────────────────────────

  Future<File> _downloadViaDio(
    ReleaseAsset asset, {
    void Function(ApkDownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
    String? version,
    Directory? overrideDir,
  }) async {
    lastEngine = 'dio';
    final dir = overrideDir ?? await _cacheDirProvider();
    if (dir == null) {
      throw const ApkDownloadException('temp dir unavailable');
    }
    await _prepareDir(dir, asset: asset, version: version);
    final target = File('${dir.path}${Platform.pathSeparator}${asset.name}');

    final startedAt = DateTime.now();
    DateTime? lastEmitAt;
    var lastReceived = 0;
    try {
      await _dio.download(
        asset.downloadUrl,
        target.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (onProgress == null) return;
          final now = DateTime.now();
          // 赋过值的局部变量在闭包里不会被类型提升，这里显式取一次快照。
          final lastEmit = lastEmitAt;
          if (lastEmit != null &&
              now.difference(lastEmit) < kApkProgressThrottle) {
            return;
          }
          lastEmitAt = now;
          onProgress(
            ApkDownloadProgress(
              received: received,
              total: total > 0 ? total : asset.size,
              speedBytesPerSec: _speed(
                received - lastReceived,
                now.difference(startedAt),
              ),
            ),
          );
          lastReceived = received;
        },
      );
    } on DioException catch (e) {
      await deleteApkWithMeta(target.path);
      if (CancelToken.isCancel(e)) {
        throw const ApkDownloadException('cancelled');
      }
      throw ApkDownloadException('dio download failed: ${e.type.name}');
    } catch (e) {
      await deleteApkWithMeta(target.path);
      throw ApkDownloadException('dio download failed: $e');
    }

    await _validate(target, asset);
    await _writeMeta(target, version);
    // 让进度条一定能走到 100%（最后一个 chunk 的回调常被节流吃掉）。
    onProgress?.call(
      ApkDownloadProgress(
        received: asset.size > 0 ? asset.size : await target.length(),
        total: asset.size > 0 ? asset.size : await target.length(),
      ),
    );
    return target;
  }

  // ─────────────────────────────── 公共辅助 ───────────────────────────────

  /// 落盘前清场（时机一）：清旧版本包 + 删同名旧文件。
  Future<void> _prepareDir(
    Directory dir, {
    required ReleaseAsset asset,
    String? version,
  }) async {
    try {
      await dir.create(recursive: true);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'create dir failed: ${dir.path}', e);
    }
    if (version != null && version.isNotEmpty) {
      await purgeStaleApks(targetVersion: version, dir: dir);
    }
    final target = File('${dir.path}${Platform.pathSeparator}${asset.name}');
    try {
      if (await target.exists()) {
        await deleteApkWithMeta(target.path);
        Logger.infoWithTag(_logTag, 'removed previous ${asset.name}');
      }
    } catch (e) {
      Logger.debugWithTag(_logTag, 'remove previous apk failed', e);
    }
  }

  Future<void> _writeMeta(File file, String? version) async {
    if (version == null || version.trim().isEmpty) return;
    await writeApkMeta(
      file.path,
      ApkMeta(version: version.trim(), downloadedAt: DateTime.now().toUtc()),
    );
  }

  Future<void> _validate(File file, ReleaseAsset asset) async {
    if (!await file.exists()) {
      throw const ApkDownloadException('downloaded file missing');
    }
    if (asset.size > 0) {
      final length = await file.length();
      if (length != asset.size) {
        await deleteApkWithMeta(file.path);
        throw ApkDownloadException(
          'size mismatch: got $length, expected ${asset.size}',
        );
      }
    }
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final head = await raf.read(4);
      final isZip =
          (head.length == 4 && _matches(head, kZipMagicLocalHeader)) ||
          (head.length == 4 && _matches(head, kZipMagicEmptyArchive));
      if (!isZip) {
        await deleteApkWithMeta(file.path);
        throw ApkDownloadException(
          'not a zip/apk: magic=${head.map((b) => b.toRadixString(16)).join(' ')}',
        );
      }
    } on ApkDownloadException {
      rethrow;
    } catch (e) {
      await deleteApkWithMeta(file.path);
      throw ApkDownloadException('validate failed: $e');
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        // 关不掉也无所谓，上面已经把结论定完了。
      }
    }
  }

  bool _matches(List<int> actual, List<int> magic) {
    for (var i = 0; i < magic.length; i++) {
      if (actual[i] != magic[i]) return false;
    }
    return true;
  }

  double _speed(int deltaBytes, Duration elapsed) {
    final ms = elapsed.inMilliseconds;
    if (deltaBytes <= 0 || ms <= 0) return 0;
    return deltaBytes * 1000 / ms;
  }

  // ───────────────────── App 被杀后再回来（可选增强） ─────────────────────

  /// 上次没走完的 download id（跨进程持久化）。
  static Future<int?> pendingDownloadId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getInt(kPendingApkDownloadIdKey);
      if (id == null || id <= 0) return null;
      return id;
    } catch (e) {
      Logger.debugWithTag(_logTag, 'read pending download id failed', e);
      return null;
    }
  }

  /// 清掉持久化的 id（下载结束/失败/取消时调用）。
  static Future<void> clearPendingDownloadId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kPendingApkDownloadIdKey);
    } catch (e) {
      Logger.debugWithTag(_logTag, 'clear pending download id failed', e);
    }
  }

  Future<void> _rememberPendingId(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kPendingApkDownloadIdKey, id);
    } catch (e) {
      Logger.debugWithTag(_logTag, 'persist pending download id failed', e);
    }
  }

  /// App 启动时收尾上一次没走完的下载（fire-and-forget，绝不阻塞启动）。
  ///
  /// - `running/pending/paused` → 保留 id，等下次进来再收（系统还在下）；
  /// - `successful` → 做完整性校验 + 补写 meta，文件留给用户点「安装」；
  /// - `failed` / 查不到 → 清 id + 删文件。
  Future<ApkPendingOutcome> settlePendingDownload({
    String? version,
    Directory? overrideDir,
  }) async {
    final id = await pendingDownloadId();
    if (id == null) return ApkPendingOutcome.none;
    try {
      final status = await _manager.query(id);
      if (status == null || status.isFailed) {
        final dir = overrideDir ?? await _downloadsDirProvider();
        if (dir != null && status?.localPath != null) {
          await deleteApkWithMeta(status!.localPath!);
        }
        await clearPendingDownloadId();
        return ApkPendingOutcome.discarded;
      }
      if (!status.isSuccessful) {
        Logger.infoWithTag(
          _logTag,
          'pending apk download still ${status.status}, keep id=$id',
        );
        return ApkPendingOutcome.running;
      }
      final dir = overrideDir ?? await _downloadsDirProvider();
      final path = status.localPath;
      if (dir == null || path == null) {
        await clearPendingDownloadId();
        return ApkPendingOutcome.discarded;
      }
      final file = File(path);
      if (!await file.exists()) {
        await clearPendingDownloadId();
        return ApkPendingOutcome.discarded;
      }
      // 大小不可知时跳过 size 校验，只验魔数（asset.size 已经拿不到了）。
      await _validate(
        file,
        const ReleaseAsset(name: '', downloadUrl: '', size: 0),
      );
      await _writeMeta(file, version);
      await clearPendingDownloadId();
      return ApkPendingOutcome.completed;
    } catch (e) {
      Logger.debugWithTag(_logTag, 'settle pending download skipped', e);
      await clearPendingDownloadId();
      return ApkPendingOutcome.discarded;
    }
  }

  // ───────────────────── 安装后复查（时机三，辅助） ─────────────────────

  /// 安装器拉起后延时复查「当前运行版本是否已经变了」。
  ///
  /// 变了 ⇒ 这次更新确实装成功 → 安装包留着没用，立刻删（连同旁车 meta）。
  /// 没变 ⇒ 用户可能在系统安装器上点了取消 → **必须留着**，交给启动时的
  /// `cleanupInstalledApks` 按 24 小时兜底（让用户能直接重试，不必重下几十 MB）。
  ///
  /// 返回 `true` = 版本已变、包已删；`false` = 版本没变 / 无法判定 / 出错。
  ///
  /// **这个方法绝不能当主判据**：更新成功后本进程会被系统杀掉替换，
  /// `await delay` 之后的代码大概率根本跑不到。真正兜住的是启动时那次清理。
  Future<bool> recheckInstalledVersion({
    required String apkPath,
    required String previousVersion,
  }) async {
    try {
      final current = (await _currentVersionReader()).trim();
      if (current.isEmpty) return false;
      if (compareAppVersions(current, previousVersion) <= 0) {
        Logger.infoWithTag(
          _logTag,
          'version unchanged ($current), keep apk for retry',
        );
        return false;
      }
      Logger.infoWithTag(
        _logTag,
        'version $previousVersion -> $current, purging apk',
      );
      await deleteApkWithMeta(apkPath);
      return true;
    } catch (e) {
      Logger.debugWithTag(_logTag, 'post-install version recheck skipped', e);
      return false;
    }
  }
}

/// 默认取版本方式：`PackageInfo.fromPlatform().version`。
///
/// 注意这是**运行时**版本（CI 用 `--build-name` 注入的那一个），不是
/// `pubspec.yaml` 里的版本号 —— 两者在本地 `flutter run` 时可能不一致，
/// 判据必须用运行时版本。
Future<String> _defaultCurrentVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  } catch (e) {
    Logger.debugWithTag(_logTag, 'read package version failed', e);
    return '';
  }
}
