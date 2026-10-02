import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:musicflow_client/core/utils/logger.dart';

/// 挑选适合当前平台的更新包:
/// - Android → `.apk`;
/// - Windows → `windows-setup.exe`(单文件安装包);
/// - 其它平台 → `.zip`。
///
/// 交付物自 v4.3.41 起只有 `-android.apk` 与 `-windows-setup.exe`
/// （绿色版 portable zip 已停止产出），因此 Windows 分支不再有
/// 「安装版/绿色版」二选一，统一取安装包。
///
/// 没有匹配到首选后缀时回退第一个资源，没有资源则返回 null(调用方应改用
/// 发布页 URL)。[isInstallerBuild] 为兼容旧调用保留，现已不参与决策。
ReleaseAsset? pickPlatformUpdateAsset(
  UpdateCheckResult result, {
  TargetPlatform? platform,
  bool? isInstallerBuild,
}) {
  if (result.assets.isEmpty) return null;
  final target = platform ?? defaultTargetPlatform;
  final isAndroid = !kIsWeb && target == TargetPlatform.android;
  if (isAndroid) {
    for (final asset in result.assets) {
      if (asset.name.toLowerCase().contains('.apk')) return asset;
    }
    return result.assets.first;
  }
  final isWindows = !kIsWeb && target == TargetPlatform.windows;
  if (isWindows) {
    // 只认单文件安装包；旧版本 zip 已不再发布，仅作历史兼容兜底。
    for (final asset in result.assets) {
      if (asset.name.toLowerCase().contains('windows-setup.exe')) return asset;
    }
    for (final asset in result.assets) {
      if (asset.name.toLowerCase().contains('windows.zip')) return asset;
    }
  } else {
    for (final asset in result.assets) {
      if (asset.name.toLowerCase().contains('.zip')) return asset;
    }
  }
  return result.assets.first;
}

/// Represents the result of an update check.
@immutable
class UpdateCheckResult {
  /// Whether a newer version is available.
  final bool hasUpdate;

  /// Current app version string (e.g. "0.3.2").
  final String currentVersion;

  /// Latest release version string from GitHub (e.g. "0.4.0").
  final String latestVersion;

  /// HTML URL of the latest release page on GitHub.
  final String? releaseUrl;

  /// Release notes body (markdown).
  final String? releaseNotes;

  /// Direct download URLs for release assets (APK, etc.).
  final List<ReleaseAsset> assets;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    this.releaseUrl,
    this.releaseNotes,
    this.assets = const [],
  });
}

@immutable
class ReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;

  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
}

/// Service that checks for app updates via GitHub Releases API.
class UpdateChecker {
  static const _logTag = 'UPDATE';
  static const _owner = 'ray5378';
  static const _repo = 'MusicFlow-client';
  static const _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';
  static const _releasesAtomUrl =
      'https://github.com/$_owner/$_repo/releases.atom';

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {'Accept': 'application/vnd.github+json'},
    ),
  );

  /// Check for updates against the latest GitHub release.
  static Future<UpdateCheckResult> check() async {
    Logger.infoWithTag(_logTag, 'checking for updates…');

    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version; // e.g. "0.3.2"

    try {
      final response = await _dio.get(_apiUrl);
      final data = response.data as Map<String, dynamic>;

      // tag_name is typically "v0.4.0" or "0.4.0"
      final tagName = (data['tag_name'] as String?) ?? '';
      final latestVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;

      final releaseUrl = data['html_url'] as String?;
      final releaseNotes = data['body'] as String?;

      final rawAssets = data['assets'] as List<dynamic>? ?? [];
      final assets = rawAssets.map((a) {
        final m = a as Map<String, dynamic>;
        return ReleaseAsset(
          name: m['name'] as String? ?? '',
          downloadUrl: m['browser_download_url'] as String? ?? '',
          size: m['size'] as int? ?? 0,
        );
      }).toList();

      final hasUpdate = _compareVersions(currentVersion, latestVersion) < 0;

      Logger.infoWithTag(
        _logTag,
        'current=$currentVersion latest=$latestVersion hasUpdate=$hasUpdate',
      );

      return UpdateCheckResult(
        hasUpdate: hasUpdate,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        releaseUrl: releaseUrl,
        releaseNotes: releaseNotes,
        assets: assets,
      );
    } catch (e, st) {
      Logger.errorWithTag(_logTag, 'update check failed', e, st);
      // api.github.com 匿名限流(60 次/时/IP)在共享出口 IP 下高频触发;
      // 兜底改抓 releases.atom(不受 API 限流)。两条路都失败才向上抛 ——
      // 设置页如实报错(v5.1.7 及之前会把失败吞成 hasUpdate=false,被设置页
      // 谎报成「已是最新」);启动检查侧有自己的 catch 静默兜底,行为不变。
      try {
        return await _checkViaAtom(currentVersion);
      } catch (atomError) {
        Logger.errorWithTag(
          _logTag,
          'update check via atom also failed',
          atomError,
        );
        throw e;
      }
    }
  }

  /// releases.atom 兜底检查:解析第一条 entry 的 tag(订阅流最新在前)。
  /// atom 拿不到资源列表 → assets 为空,弹窗自动回退发布页链接;notes 置空
  /// 避免 atom 里的 HTML 富文本进 UI。atom 不区分 prerelease,兜底路径可接受。
  static Future<UpdateCheckResult> _checkViaAtom(
    String currentVersion,
  ) async {
    final res = await _dio.get(
      _releasesAtomUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Accept': 'application/atom+xml'},
      ),
    );
    final latest = parseAtomLatest(res.data?.toString() ?? '');
    return UpdateCheckResult(
      hasUpdate: _compareVersions(currentVersion, latest.$1) < 0,
      currentVersion: currentVersion,
      latestVersion: latest.$1,
      releaseUrl: latest.$2,
    );
  }

  /// 从 releases.atom 内容解析最新 release 的 (version, releaseUrl)。
  /// 独立成纯函数供测试;解析不到 tag 抛 [FormatException]。
  static (String, String?) parseAtomLatest(String xml) {
    final entry =
        RegExp(r'<entry>[\s\S]*?</entry>').firstMatch(xml)?.group(0) ?? '';
    final tagMatch = RegExp(r'releases/tag/([^"<?\s]+)').firstMatch(entry);
    var latest = tagMatch?.group(1) ?? '';
    if (latest.startsWith('v')) latest = latest.substring(1);
    if (latest.isEmpty) {
      throw const FormatException('releases.atom: no release tag found');
    }
    final releaseUrl =
        RegExp(r'href="([^"]+)"').firstMatch(entry)?.group(1) ??
            'https://github.com/$_owner/$_repo/releases/latest';
    return (latest, releaseUrl);
  }

  /// Compare two semver-like version strings.
  /// Returns negative if a < b, 0 if equal, positive if a > b.
  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final length = aParts.length > bParts.length
        ? aParts.length
        : bParts.length;

    for (var i = 0; i < length; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }
}
