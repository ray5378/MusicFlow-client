import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'package:musicflow_client/core/services/apk_cache_janitor.dart';
import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/utils/logger.dart';

const String _logTag = 'APK_CLEANUP';

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
Future<void> purgeUpdateArtifacts() async {
  try {
    await cleanupInstalledApks();
  } catch (e) {
    Logger.debugWithTag(_logTag, 'installed apk cleanup skipped', e);
  }
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final outcome = await ApkDownloadService().settlePendingDownload();
    if (outcome != ApkPendingOutcome.none) {
      Logger.infoWithTag(
        _logTag,
        'pending apk download settled: ${outcome.name}',
      );
    }
  } catch (e) {
    Logger.debugWithTag(_logTag, 'pending apk download settle skipped', e);
  }
}
