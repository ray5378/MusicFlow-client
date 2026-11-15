import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:musicflow_client/core/utils/logger.dart';

const String _logTag = 'APK_CACHE';

/// 旁车 meta 文件的后缀：与 apk 同目录，即 `<apk 文件名>.meta.json`。
///
/// 为什么需要它：安装包文件名里的版本是**紧凑 tag**（`v5.14.1` → `5141`），
/// 紧凑化是**有损**的 —— `5.14.1` 与 `51.4.1` 都会变成 `5141`，无法可靠还原。
/// 所以版本只从这份旁车文件读，绝不解析文件名。
const String kApkMetaSuffix = '.meta.json';

/// DownloadManager 引擎的落点：`getExternalStorageDirectory()/Download/`。
///
/// 必须与 `android/app/src/main/res/xml/file_paths.xml` 里的
/// `<external-files-path name="updates" path="Download/" />` 严格对齐，
/// 否则 `FileProvider.getUriForFile` 会直接抛「Failed to find configured root」。
const String kApkDownloadSubdir = 'Download';

/// dio 降级引擎的落点：`getTemporaryDirectory()/updates/`。
///
/// 与 `file_paths.xml` 里的 `<cache-path name="updates_cache" path="updates/" />`
/// 对齐。只在 DownloadManager 不可用（桌面 / 异常 ROM）时使用。
const String kApkCacheSubdir = 'updates';

/// 安装包旁车元数据（版本 + 下载时刻）。
///
/// 清理判据完全建立在它上面：`version <= 运行版本` ⇒ 这次更新已经装成功了。
class ApkMeta {
  const ApkMeta({required this.version, required this.downloadedAt});

  /// 下这个包**时**的「最新版本」（来自 `UpdateCheckResult.latestVersion`，
  /// 不是从文件名解析出来的）。
  final String version;

  /// 落盘完成的时刻（UTC）。
  final DateTime downloadedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'downloadedAt': downloadedAt.toUtc().toIso8601String(),
  };

  /// 解析永远不抛：meta 损坏（半写 / 手工改坏 / 老版本格式）一律当成
  /// 「没有 meta」，由调用方按孤儿包处理。
  static ApkMeta? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    if (version is! String || version.trim().isEmpty) return null;
    final at = raw['downloadedAt'];
    final parsedAt = at is String ? DateTime.tryParse(at) : null;
    return ApkMeta(
      version: version.trim(),
      downloadedAt: (parsedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .toUtc(),
    );
  }

  @override
  String toString() => 'ApkMeta(version: $version, at: $downloadedAt)';
}

/// 比较两个 `x.y.z` 形式的版本号：a < b 返回负数，相等 0，a > b 正数。
///
/// 与 `UpdateChecker` 内部的比较口径一致（缺位补 0、非数字按 0），但**刻意
/// 单独实现**：检测逻辑是既有稳定代码，清理逻辑不该反过来依赖它的私有方法。
int compareAppVersions(String a, String b) {
  List<int> parts(String s) =>
      s.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
  final aParts = parts(a);
  final bParts = parts(b);
  final length = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < length; i++) {
    final av = i < aParts.length ? aParts[i] : 0;
    final bv = i < bParts.length ? bParts[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

/// DownloadManager 落点目录（不保证已存在；获取失败返回 null）。
Future<Directory?> apkDownloadsDir() async {
  try {
    final base = await getExternalStorageDirectory();
    if (base == null) return null;
    return Directory(
      '${base.path}${Platform.pathSeparator}$kApkDownloadSubdir',
    );
  } catch (e) {
    Logger.debugWithTag(_logTag, 'external files dir unavailable', e);
    return null;
  }
}

/// dio 降级引擎落点目录（不保证已存在；获取失败返回 null）。
Future<Directory?> apkCacheDir() async {
  try {
    final base = await getTemporaryDirectory();
    return Directory('${base.path}${Platform.pathSeparator}$kApkCacheSubdir');
  } catch (e) {
    Logger.debugWithTag(_logTag, 'temp dir unavailable', e);
    return null;
  }
}

/// 清理需要扫的两个目录（DownloadManager 主 + dio 兜底遗留）。
Future<List<Directory>> apkCandidateDirs() async {
  final dirs = <Directory>[];
  for (final dir in <Directory?>[
    await apkDownloadsDir(),
    await apkCacheDir(),
  ]) {
    if (dir == null) continue;
    if (dirs.any((d) => d.path == dir.path)) continue;
    dirs.add(dir);
  }
  return dirs;
}

/// apk 对应的旁车 meta 路径。
String apkMetaPathFor(String apkPath) => '$apkPath$kApkMetaSuffix';

/// 写旁车 meta。**失败绝不反噬下载结果**：meta 丢了最坏退化成「孤儿包」，
/// 下次清理时被删掉重下，比「下载成功却因为写 meta 失败而报错」好得多。
Future<void> writeApkMeta(String apkPath, ApkMeta meta) async {
  try {
    await File(
      apkMetaPathFor(apkPath),
    ).writeAsString(jsonEncode(meta.toJson()));
  } catch (e) {
    Logger.warnWithTag(_logTag, 'write apk meta failed: $apkPath', e);
  }
}

/// 读旁车 meta；不存在 / 损坏一律返回 null（不抛）。
Future<ApkMeta?> readApkMeta(String apkPath) async {
  try {
    final file = File(apkMetaPathFor(apkPath));
    if (!await file.exists()) return null;
    return ApkMeta.fromJson(jsonDecode(await file.readAsString()));
  } catch (e) {
    Logger.debugWithTag(_logTag, 'read apk meta failed (ignored): $apkPath', e);
    return null;
  }
}

/// 删 apk 并连带删掉它的 meta；所有异常静默（清理是尽力而为）。
Future<void> deleteApkWithMeta(String apkPath) async {
  for (final path in <String>[apkPath, apkMetaPathFor(apkPath)]) {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      Logger.debugWithTag(_logTag, 'delete failed (ignored): $path', e);
    }
  }
}
