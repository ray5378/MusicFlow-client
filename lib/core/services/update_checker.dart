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

  /// GitHub 发布页自己用来渲染「资源列表」的 HTML 片段接口。
  ///
  /// 关键：它走 `github.com`，**不经过 `api.github.com`**，因而不吃匿名
  /// API 的 60 次/时/IP 限流。atom 兜底路径用它把 assets 补回来 —— 缺了
  /// assets，Android 内置更新就挑不到 apk 直链，只能退回浏览器，表现为
  /// 「点下载却跳去 GitHub 发布页」（这是 v5.17.15 之前的老问题）。
  static const _expandedAssetsBase =
      'https://github.com/$_owner/$_repo/releases/expanded_assets';

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
  /// notes 置空,避免 atom 里的 HTML 富文本进 UI。atom 不区分 prerelease,
  /// 兜底路径可接受。
  ///
  /// **资源列表必须另外补**:atom 只有标题和链接,没有 assets。历史上这里
  /// 留空,弹窗就「回退发布页链接」—— 在 Windows 上无害(本来就要跳浏览器),
  /// 但 Android 内置更新因此挑不到 apk,点「下载」直接蹦到 GitHub 页面。
  /// 现在改走 [parseExpandedAssets] 补齐,让两条链路都拿到直链。
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
    final assets = await _fetchExpandedAssets(
      _tagFromReleaseUrl(latest.$2, latest.$1),
    );
    return UpdateCheckResult(
      hasUpdate: _compareVersions(currentVersion, latest.$1) < 0,
      currentVersion: currentVersion,
      latestVersion: latest.$1,
      releaseUrl: latest.$2,
      assets: assets,
    );
  }

  /// 从 release 页 URL 里取回 tag 原文（atom 的 link 形如
  /// `…/releases/tag/v5.17.15`）。取不到就按 `v<version>` 拼——
  /// 与 CI 打 tag 的规则一致。
  static String _tagFromReleaseUrl(String? url, String version) {
    if (url != null) {
      final tag = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(url)?.group(1);
      if (tag != null && tag.isNotEmpty) return tag;
    }
    return 'v$version';
  }

  /// 抓 `releases/expanded_assets/<tag>` 并解析成资源列表。
  ///
  /// 任何失败都只回空列表、绝不向上抛:更新检查本身已经成功,不能因为
  /// 「补资源」这一步失败就把整次检查判死（那样设置页会谎报检查失败）。
  static Future<List<ReleaseAsset>> _fetchExpandedAssets(String tag) async {
    if (tag.isEmpty) return const <ReleaseAsset>[];
    try {
      final res = await _dio.get(
        '$_expandedAssetsBase/$tag',
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Accept': 'text/html'},
        ),
      );
      final assets = parseExpandedAssets(res.data?.toString() ?? '');
      Logger.infoWithTag(
        _logTag,
        'expanded_assets $tag → ${assets.length} asset(s)',
      );
      return assets;
    } catch (e) {
      Logger.warnWithTag(_logTag, 'expanded_assets $tag failed', e);
      return const <ReleaseAsset>[];
    }
  }

  /// 从 `releases/expanded_assets/<tag>` 的 HTML 片段解析资源列表。
  ///
  /// 每个资源在页面里是一行
  /// `<a href="/<owner>/<repo>/releases/download/<tag>/<file>">`，
  /// 文件名取路径末段（URL 解码），下载地址补 `https://github.com` 前缀。
  ///
  /// 体积拿不到 —— HTML 里只有 "46.9 MB" 这种展示串，反解成字节没有意义
  /// （46.9 MB 到底是 46.9×10^6 还是 ×2^20 说不清）。size 置 0，下载进度
  /// 有「按实际回调校正」的兜底，不影响功能。
  ///
  /// 独立成纯函数供测试；同名资源只保留第一条（GitHub 不会重名，
  /// 但页面可能因重复渲染出现两次）。
  static List<ReleaseAsset> parseExpandedAssets(String html) {
    // 尾部的 `(?:\?[^"]*)?` 是为了吃下 `?download=1` 这类查询串:整段
    // href 必须一路匹配到闭引号,不显式吃掉 query 就会因为「`.apk` 后面
    // 不是引号」而整条漏掉(安卓侧表现为又回到「assets 为空」)。
    final pattern = RegExp(
      r'href="(/[^"]*?/releases/download/[^"/]+/([^"/?]+))(?:\?[^"]*)?"',
    );
    final assets = <ReleaseAsset>[];
    final seen = <String>{};
    for (final match in pattern.allMatches(html)) {
      final name = Uri.decodeComponent(match.group(2)!);
      if (!seen.add(name)) continue;
      assets.add(
        ReleaseAsset(
          name: name,
          downloadUrl: 'https://github.com${match.group(1)!}',
          size: 0,
        ),
      );
    }
    return assets;
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
