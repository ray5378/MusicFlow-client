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
///
/// 资产挑选只认文件名后缀，与更新通道无关：Gitee 与 GitHub 发布的资产名
/// 完全一致（同一 CI 产物双向上传），Gitee 自动追加的 `vX.Y.Z.zip/tar.gz`
/// 是 tag 归档直链，不会被本函数误选（Windows 分支只认 windows-setup.exe）。
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

/// 更新检查/下载通道。
///
/// - [gitee]：默认通道，国内网络直连更快，也不受 GitHub 匿名 API 限流影响；
/// - [github]：备用通道。Gitee 检查失败时自动回退到它（结果带
///   [UpdateCheckResult.viaFallback] 标注）；用户显式选择 github 时不回退。
enum UpdateChannel { gitee, github }

/// Represents the result of an update check.
@immutable
class UpdateCheckResult {
  /// Whether a newer version is available.
  final bool hasUpdate;

  /// Current app version string (e.g. "0.3.2").
  final String currentVersion;

  /// Latest release version string (e.g. "0.4.0").
  final String latestVersion;

  /// HTML URL of the latest release page.
  final String? releaseUrl;

  /// Release notes body (markdown).
  final String? releaseNotes;

  /// Direct download URLs for release assets (APK, etc.).
  final List<ReleaseAsset> assets;

  /// 本次结果是否实际来自**备用通道**（所选通道 gitee 检查失败后自动回退
  /// GitHub 成功）。UI 据此展示「来自 GitHub 备用通道」标注。
  final bool viaFallback;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    this.releaseUrl,
    this.releaseNotes,
    this.assets = const [],
    this.viaFallback = false,
  });

  /// 返回带「来自备用通道」标注的结果副本（其余字段逐字保留）。
  UpdateCheckResult withFallbackFlag() => UpdateCheckResult(
    hasUpdate: hasUpdate,
    currentVersion: currentVersion,
    latestVersion: latestVersion,
    releaseUrl: releaseUrl,
    releaseNotes: releaseNotes,
    assets: assets,
    viaFallback: true,
  );
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

/// 所选通道与备用通道**都**检查失败时抛出（设置页据此展示
/// 「两个通道都试过」的稳定文案；原始错误只进日志）。
class UpdateChannelsExhaustedException implements Exception {
  /// 首选通道（gitee）的原始错误。
  final Object giteeError;

  /// 备用通道（github）的原始错误。
  final Object githubError;

  const UpdateChannelsExhaustedException(this.giteeError, this.githubError);

  @override
  String toString() =>
      'UpdateChannelsExhaustedException(gitee: $giteeError, github: $githubError)';
}

/// Service that checks for app updates via Gitee / GitHub Releases API.
class UpdateChecker {
  static const _logTag = 'UPDATE';

  // GitHub（备用通道）。
  static const _owner = 'ray5378';
  static const _repo = 'MusicFlow-client';
  static const _githubApiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';
  static const _releasesAtomUrl =
      'https://github.com/$_owner/$_repo/releases.atom';

  // Gitee（默认通道）。
  static const _giteeOwner = 'ray5378';
  static const _giteeRepo = 'music-flow-client';
  static const _giteeApiUrl =
      'https://gitee.com/api/v5/repos/$_giteeOwner/$_giteeRepo/releases/latest';

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {'Accept': 'application/vnd.github+json'},
    ),
  );

  /// 检查更新（默认走 gitee 通道）。
  ///
  /// - [channel] == [UpdateChannel.github]：只走 GitHub，失败如实抛错
  ///   （用户显式选择了备用通道，不再反向回退）；
  /// - [channel] == [UpdateChannel.gitee]（默认）：先走 Gitee，失败自动
  ///   回退 GitHub 并在结果上打 [UpdateCheckResult.viaFallback] 标注；
  ///   两边都失败抛 [UpdateChannelsExhaustedException]。
  ///
  /// [currentVersionOverride] / [giteeFetcher] / [githubFetcher] 仅测试注入。
  static Future<UpdateCheckResult> check({
    UpdateChannel channel = UpdateChannel.gitee,
    String? currentVersionOverride,
    Future<UpdateCheckResult> Function()? giteeFetcher,
    Future<UpdateCheckResult> Function()? githubFetcher,
  }) async {
    Logger.infoWithTag(_logTag, 'checking for updates… channel=${channel.name}');

    // currentVersionOverride 已给定时跳过 PackageInfo（纯注入路径无需平台通道，
    // 测试环境也因此不触 MethodChannel / 网络）。
    final currentVersion = currentVersionOverride ??
        (await PackageInfo.fromPlatform()).version;

    if (channel == UpdateChannel.github) {
      return _github(currentVersion, githubFetcher: githubFetcher);
    }

    try {
      final giteeResult = await (giteeFetcher ?? () async {
        return _checkViaGitee(currentVersion);
      })();
      return giteeResult;
    } catch (giteeError, giteeSt) {
      Logger.errorWithTag(
        _logTag,
        'gitee update check failed, falling back to github',
        giteeError,
        giteeSt,
      );
      try {
        final result = await _github(currentVersion, githubFetcher: githubFetcher);
        return result.withFallbackFlag();
      } catch (githubError, githubSt) {
        Logger.errorWithTag(
          _logTag,
          'github fallback update check also failed',
          githubError,
          githubSt,
        );
        throw UpdateChannelsExhaustedException(giteeError, githubError);
      }
    }
  }

  /// GitHub 通道：JSON API 失败兜底 releases.atom（行为与改造前一致）。
  static Future<UpdateCheckResult> _github(
    String currentVersion, {
    Future<UpdateCheckResult> Function()? githubFetcher,
  }) async {
    return githubFetcher != null
        ? githubFetcher()
        : _checkViaGitHub(currentVersion);
  }

  /// GitHub Releases API 检查（原 [check] 的 GitHub 分支，逐字保留）。
  static Future<UpdateCheckResult> _checkViaGitHub(String currentVersion) async {
    try {
      final response = await _dio.get(_githubApiUrl);
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

  /// Gitee Releases API 检查。
  ///
  /// 与 GitHub 的字段差异（对本仓 Release 实测）：
  /// - `html_url` 为 **null** → 自行拼接 `https://gitee.com/{owner}/{repo}/releases/tag/{tag}`，
  ///   否则浏览器回退会拿到 null；
  /// - `assets[].size` 为 **null** → 解析为 0（下载层的落盘大小校验对 0 跳过，
  ///   UI 对 0 隐藏体积显示）；
  /// - `tag_name / name / body / assets[].browser_download_url` 与 GitHub 同名同义。
  ///
  /// 解析逻辑独立成 [parseGiteeRelease] 纯函数供测试；本方法只负责网络取数。
  static Future<UpdateCheckResult> _checkViaGitee(String currentVersion) async {
    final response = await _dio.get(
      _giteeApiUrl,
      options: Options(headers: <String, String>{'Accept': 'application/json'}),
    );
    return parseGiteeRelease(
      response.data as Map<String, dynamic>,
      currentVersion: currentVersion,
    );
  }

  /// 解析 Gitee `/releases/latest` 响应为 [UpdateCheckResult]（纯函数）。
  ///
  /// [data] 形状按真机实测：`tag_name: "v5.16.3"`、`html_url: null`、
  /// `assets[].size: null`（Gitee 会自动追加 zip/tar.gz 归档资产）。
  /// 解析不到 tag 时抛 [FormatException]。
  @visibleForTesting
  static UpdateCheckResult parseGiteeRelease(
    Map<String, dynamic> data, {
    required String currentVersion,
  }) {
    final tagName = (data['tag_name'] as String?) ?? '';
    if (tagName.isEmpty) {
      throw const FormatException('gitee release: empty tag_name');
    }
    final latestVersion = tagName.startsWith('v')
        ? tagName.substring(1)
        : tagName;

    // Gitee 的 html_url 为 null，必须自行拼接发布页地址（浏览器回退用）。
    final releaseUrl =
        (data['html_url'] as String?) ??
        'https://gitee.com/$_giteeOwner/$_giteeRepo/releases/tag/$tagName';
    final releaseNotes = data['body'] as String?;

    final rawAssets = data['assets'] as List<dynamic>? ?? [];
    final assets = rawAssets.map((a) {
      final m = a as Map<String, dynamic>;
      return ReleaseAsset(
        name: m['name'] as String? ?? '',
        downloadUrl: m['browser_download_url'] as String? ?? '',
        // Gitee 资产不带 size，缺省 0（下载层与 UI 都按 0 兜底）。
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
