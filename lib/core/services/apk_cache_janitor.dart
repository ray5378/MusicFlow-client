import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'package:musicflow_client/core/services/apk_cache_paths.dart';
import 'package:musicflow_client/core/utils/logger.dart';

const String _logTag = 'APK_JANITOR';

/// 取当前运行版本的方式（默认 `PackageInfo.fromPlatform().version`）。
///
/// 单测注入用：测试环境没有真实的 PackageInfo 通道。
typedef PackageInfoSource = Future<String> Function();

/// 「下载了但没装成」的包最多留多久。
///
/// 用户可能在系统安装器上点了取消 / 装到一半退出 / ROM 拦截了一次。留 24 小时
/// 让他能直接重试，不必重下几十 MB；超时就当垃圾清掉。
const Duration kApkRetainAfterFailure = Duration(hours: 24);

/// 清理下载缓存里的安装包（App 启动时调用一次）。
///
/// ## 判据（唯一依据是旁车 meta，不解析文件名）
///
/// | 条件 | 动作 |
/// |---|---|
/// | `meta.version <= 当前运行版本` | **删** —— 这次更新已经装成功了 |
/// | `meta.version > 当前版本` 且 `now - downloadedAt > 24h` | **删** —— 装了但被取消/失败，超时兜底 |
/// | `meta.version > 当前版本` 且未超 24h | **留** —— 用户可能还要重试 |
/// | 目录里没有对应 meta 的孤儿 apk | **删** —— 历史遗留，无法判定就不能留 |
///
/// ## 为什么是「启动时清理」而不是「安装完立刻清理」
///
/// `installApk()` 里 `startActivity` 返回的瞬间，系统安装器只是拿到了
/// `content://` URI，**真正的字节流是异步读的**。此时删文件 → 安装器读不到 →
/// 「解析包时出错」，部分 ROM 上表现为静默失败，极难查。而「更新成功后本进程
/// 会被系统杀掉替换」，所以安装完成后那段代码大概率跑不到 —— 真正兜住的是
/// 这个启动时的判据。
///
/// 全程静默：目录不存在、meta 损坏、删除被拒…… 一律跳过，绝不抛。
Future<void> cleanupInstalledApks({
  PackageInfoSource? pkgInfo,
  List<Directory>? dirs,
  DateTime Function()? now,
}) async {
  try {
    final currentVersion = await (pkgInfo ?? _defaultPackageVersion)();
    if (currentVersion.trim().isEmpty) return;
    final targets = dirs ?? await apkCandidateDirs();
    final clock = (now ?? DateTime.now)();
    var removed = 0;
    for (final dir in targets) {
      removed += await _cleanDir(
        dir,
        currentVersion: currentVersion,
        now: clock,
      );
    }
    if (removed > 0) {
      Logger.infoWithTag(
        _logTag,
        'cleaned $removed stale apk(s) against runtime version $currentVersion',
      );
    }
  } catch (e) {
    // 清理是锦上添花，任何失败都不许影响启动。
    Logger.debugWithTag(_logTag, 'apk cache cleanup skipped', e);
  }
}

/// 下载前清旧包（时机一）。
///
/// 删两类：
/// 1. meta 版本 **低于** [targetVersion] 的（旧版本包留着没意义）；
/// 2. 没有 meta 的孤儿包（无法判定版本 = 无法判断能不能用）。
///
/// **不删** meta 版本 >= [targetVersion] 的：同版本重复下载时由
/// `ApkDownloadService` 自己删同名文件，这里不抢它的活。
Future<void> purgeStaleApks({
  required String targetVersion,
  required Directory dir,
  DateTime Function()? now,
}) async {
  try {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.toLowerCase().endsWith('.apk')) continue;
      final meta = await readApkMeta(path);
      if (meta == null) {
        await deleteApkWithMeta(path);
        Logger.debugWithTag(_logTag, 'purged orphan apk: $path');
        continue;
      }
      if (compareAppVersions(meta.version, targetVersion) < 0) {
        await deleteApkWithMeta(path);
        Logger.debugWithTag(
          _logTag,
          'purged older apk ${meta.version} (< $targetVersion): $path',
        );
      }
    }
  } catch (e) {
    Logger.debugWithTag(_logTag, 'purge stale apks skipped', e);
  }
}

Future<int> _cleanDir(
  Directory dir, {
  required String currentVersion,
  required DateTime now,
}) async {
  var removed = 0;
  try {
    if (!await dir.exists()) return 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.toLowerCase().endsWith('.apk')) continue;
      final meta = await readApkMeta(path);
      final shouldDelete = _shouldDelete(
        meta,
        currentVersion: currentVersion,
        now: now,
      );
      if (!shouldDelete) continue;
      await deleteApkWithMeta(path);
      removed += 1;
    }
  } catch (e) {
    Logger.debugWithTag(_logTag, 'clean dir skipped: ${dir.path}', e);
  }
  return removed;
}

bool _shouldDelete(
  ApkMeta? meta, {
  required String currentVersion,
  required DateTime now,
}) {
  // 孤儿包：没有 meta 就无从判断版本，留着只会在「未知版本」上继续堆。
  if (meta == null) return true;
  // 已装成功：meta 版本 <= 当前运行版本 ⇒ 这个包已经被装上去了。
  if (compareAppVersions(meta.version, currentVersion) <= 0) return true;
  // 装了但没成：超过 24 小时就当垃圾。
  return now.difference(meta.downloadedAt) > kApkRetainAfterFailure;
}

Future<String> _defaultPackageVersion() async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
}
