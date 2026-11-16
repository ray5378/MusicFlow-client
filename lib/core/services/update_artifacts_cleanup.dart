import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'package:musicflow_client/core/services/apk_cache_janitor.dart';
import 'package:musicflow_client/core/services/apk_cache_paths.dart';
import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/utils/logger.dart';

const String _logTag = 'APK_CLEANUP';

/// 启动结算结果的回调签名。
///
/// [ApkDownloadService.settlePendingDownload] 只回一个枚举，**不带路径**；
/// 需要路径的调用方（设置页更新行 / 下载控制器）由 [purgeUpdateArtifacts]
/// 内部补一次目录扫描后一并回调。
///
/// [version] / [apkPath] 只在 [outcome] 为 [ApkPendingOutcome.completed] 时
/// 可能有值，其余情况恒为 null —— 调用方自己决定要不要理它们。
typedef PendingDownloadSettled =
    void Function(
      ApkPendingOutcome outcome, {
      String? version,
      String? apkPath,
    });

/// 「上次待收尾的下载」最终落地的那颗包（绝对路径 + 旁车 meta）。
///
/// [meta] 允许为 null：极端情况下 meta 写失败（下载层刻意不让写 meta 失败
/// 反噬下载结果），此时仍然把路径交出去，只是版本号未知。
class _SettledApk {
  const _SettledApk({required this.path, required this.meta});

  /// apk 的绝对路径。
  final String path;

  /// 旁车 meta（读不到就是 null）。
  final ApkMeta? meta;
}

/// App 启动时收拾内置更新留下的残留（**fire-and-forget**，绝不阻塞首帧）。
///
/// 两件事，顺序不能反：
///
/// 1. [cleanupInstalledApks] —— 按旁车 meta 清掉「已经装成功」的包
///    （`meta.version <= 当前运行版本`）与「装了但失败超 24 小时」的包，
///    以及没有 meta 的孤儿包。这是「装完自动清包」的**真正判据**。
/// 2. [ApkDownloadService.settlePendingDownload] —— 上次下载到一半进程被杀，
///    这里按持久化的 download id 收尾：还在下就留着等下次，下完了就补校验 +
///    补 meta，失败了就删干净。仅在 Android 上做（DownloadManager 才存在）。
///
/// 全程静默：目录不存在、PackageInfo 通道缺失（桌面/测试）、SharedPreferences
/// 不可用…… 一律跳过。清理失败最多是「多留一个几十 MB 的包」，而抛异常会让
/// 应用启动报错 —— 轻重分明，所以这里兜住一切。
///
/// [onPendingSettled] 是结算结果的出口（可选）：传了就把 outcome —— 以及
/// [ApkPendingOutcome.completed] 时的 apk 路径 / 版本 —— 回调出去，供下载
/// 控制器把「上次已经下好了」灌进自己的状态。回调本身也被 try/catch 包住：
/// 它是 UI 层的代码，抛异常不能连累启动流程。
Future<void> purgeUpdateArtifacts({
  PendingDownloadSettled? onPendingSettled,
}) async {
  // ⚠️ 顺序硬约束：**先**清「已装成功」的包，**再**结算 pending 下载。
  //
  // 反过来会把「刚下好、还没写旁车 meta」的新包当成孤儿包删掉，用户下一次
  // 点更新就得白下几十 MB。
  try {
    await cleanupInstalledApks();
  } catch (e) {
    Logger.debugWithTag(_logTag, 'installed apk cleanup skipped', e);
  }

  // DownloadManager / 旁车 meta 只在 Android 存在，其它平台没有可结算的东西。
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

  final ApkPendingOutcome outcome;
  try {
    outcome = await ApkDownloadService().settlePendingDownload();
  } catch (e) {
    Logger.debugWithTag(_logTag, 'pending apk download settle skipped', e);
    return;
  }
  if (outcome != ApkPendingOutcome.none) {
    Logger.infoWithTag(
      _logTag,
      'pending apk download settled: ${outcome.name}',
    );
  }

  if (onPendingSettled == null) return;

  // 只有「真的下完了」才值得去扫目录：running / discarded / none 没有包可交。
  String? version;
  String? apkPath;
  if (outcome == ApkPendingOutcome.completed) {
    final settled = await _findLatestSettledApk();
    if (settled == null) {
      // 扫描不出来不算错误：可能是 ROM 把外部存储收起、目录被系统清了……
      // 照样回调（apkPath 为 null），让调用方按「没有可装的包」处理。
      Logger.warnWithTag(_logTag, 'settled completed but no apk located');
    } else {
      version = settled.meta?.version;
      apkPath = settled.path;
    }
  }

  try {
    onPendingSettled(outcome, version: version, apkPath: apkPath);
  } catch (e) {
    // 调用方（UI / Provider）抛异常绝不能反噬启动流程。
    Logger.debugWithTag(_logTag, 'pending settle callback skipped', e);
  }
}

/// 在候选目录里找「最像上次下载结果」的那颗 apk。
///
/// 判据是**旁车 meta 的 `downloadedAt` 最新**（取不到 meta 时退化成文件
/// `lastModified`），跨目录比较，因此 DownloadManager 主落点与 dio 兜底落点
/// 谁赢谁上，不靠目录顺序猜。目录顺序仍按 [apkCandidateDirs]（`Download/`
/// 优先）遍历，同刻并列时先命中的胜出。
///
/// 全程不抛：任何一步出问题都只跳过那一项。
Future<_SettledApk?> _findLatestSettledApk() async {
  _SettledApk? best;
  DateTime? bestAt;
  try {
    final dirs = await apkCandidateDirs();
    for (final dir in dirs) {
      if (!await dir.exists()) continue;
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list().toList();
      } catch (e) {
        Logger.debugWithTag(_logTag, 'list apk dir skipped: ${dir.path}', e);
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        // 只要 apk 本体；旁车 `.meta.json` 与下载中的 `.part` 都不算。
        if (!entry.path.toLowerCase().endsWith('.apk')) continue;
        final ApkMeta? meta;
        final DateTime at;
        try {
          meta = await readApkMeta(entry.path);
          at = meta?.downloadedAt ?? (await entry.stat()).modified.toUtc();
        } catch (e) {
          Logger.debugWithTag(_logTag, 'inspect apk skipped: ${entry.path}', e);
          continue;
        }
        if (bestAt == null || at.isAfter(bestAt)) {
          bestAt = at;
          best = _SettledApk(path: entry.path, meta: meta);
        }
      }
    }
  } catch (e) {
    Logger.debugWithTag(_logTag, 'apk scan failed (ignored)', e);
    return null;
  }
  return best;
}
