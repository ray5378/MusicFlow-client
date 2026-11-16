import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/services/apk_installer.dart';
import 'package:musicflow_client/core/services/notification_permission_service.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/features/settings/widgets/update_download_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/settings/update_download_provider.dart';

const String _logTag = 'APP_UPDATE';

/// 内置更新编排层：**Android 直下 + 唤装**，其它平台行为一个字节都不变。
///
/// ## Android 时序
///
/// 1. `pickPlatformUpdateAsset` 挑 `.apk`（挑不到 → 回退发布页链接）；
/// 2. `canRequestPackageInstalls` —— 没有「安装未知应用」授权就先引导去开，
///    回来后**必须再查一次**（用户可能点了返回没开）；
/// 3. 通知权限（Android 13+）—— 未授权**不阻断**，但要如实告诉用户
///    通知栏不会有进度；
/// 4. **去重 + 启动下载**：[UpdateDownloadController] 是下载的唯一入口 ——
///    同一版本已在下载 / 已下好时**不新建 service、不重下**，只弹浮层；
/// 5. 弹下载浮层：后台由系统 DownloadManager 下载 + 通知栏进度（浮层只是
///    展示层，拖掉它不影响下载）；
/// 6. 下完校验通过 → 回到前台时 `installApk(path)` 唤起系统安装器。
///
/// ## 清理安装包的三个时机（顺序不能乱）
///
/// - **下载前**：`ApkDownloadService._prepareDir` 清旧版本包 + 删同名旧文件；
/// - **启动时**：`cleanupInstalledApks`（真正的判据，见它的文档）；
/// - **安装器返回后 3 秒**：辅助复查版本是否已经变了（大概率跑不到 —— 更新成功
///   后本进程会被系统杀掉替换，所以绝不作主判据）。
///
/// **唤装后绝不立即删包**：`startActivity` 返回的瞬间系统安装器只是拿到了
/// `content://` URI，字节流是异步读的，此时删文件会变成「解析包时出错」。
class AppUpdateInstaller {
  const AppUpdateInstaller._();

  /// 「安装完成后再复查一次」的延时（辅助时机）。
  static const Duration kPostInstallRecheckDelay = Duration(seconds: 3);

  /// 统一入口：在 [context] 上展示更新流程。
  ///
  /// [fallbackUrl] 为挑不到安装包时回退的下载/发布页地址。
  /// [installer] / [downloadService] / [platform] / [isWeb] 仅供测试注入。
  static Future<void> install(
    BuildContext context,
    UpdateCheckResult result, {
    String? fallbackUrl,
    ApkInstaller? installer,
    Future<ApkDownloadService> Function()? downloadServiceFactory,
    TargetPlatform? platform,
    bool? isWeb,
  }) async {
    final web = isWeb ?? kIsWeb;
    final target = platform ?? defaultTargetPlatform;
    final browserUrl = fallbackUrl ?? result.releaseUrl;

    // 非 Android（尤其 Windows）：保持原样，交给系统浏览器。
    if (web || target != TargetPlatform.android) {
      await _openInBrowser(browserUrl);
      return;
    }

    final asset = pickPlatformUpdateAsset(
      result,
      platform: TargetPlatform.android,
    );
    if (asset == null) {
      Logger.infoWithTag(_logTag, 'no apk asset, falling back to browser');
      await _openInBrowser(browserUrl);
      return;
    }

    final apkInstaller = installer ?? ApkInstaller();
    final granted = await _ensureInstallPermission(
      context,
      apkInstaller,
      platform: target,
      isWeb: web,
    );
    if (!granted) {
      Logger.infoWithTag(_logTag, 'install permission not granted, aborted');
      return;
    }
    if (!context.mounted) return;

    final notificationGranted = await ensureUpdateNotificationPermission();
    if (!context.mounted) return;

    final downloadService =
        await (downloadServiceFactory?.call() ??
            Future<ApkDownloadService>.value(ApkDownloadService()));
    if (!context.mounted) return;

    final loc = AppLocalizations.of(context);

    final container = ProviderScope.containerOf(context, listen: false);
    final controller = container.read(updateDownloadControllerProvider.notifier);

    // 无条件交给 controller.start()：它内部已经覆盖三种情况
    //   ① 同版本在下载 → 只记依赖（供 installNow/retry 复用），不重下；
    //   ② 同版本已下好 → 记依赖 + 自动唤装；
    //   ③ 新版本 → 真正开下。
    // 调用方再分叉一次只会漏掉依赖注入（历史上就是这里漏的：
    // 走了「复用」分支不调 start()，于是浮层里「再次安装」拿不到 installer）。
    await controller.start(
      asset: asset,
      version: result.latestVersion,
      installer: apkInstaller,
      downloadService: downloadService,
      notificationGranted: notificationGranted,
      notificationTitle: loc.settings_update_found_version(
        result.latestVersion,
      ),
      notificationDescription: loc.settings_update_downloading,
    );
    if (!context.mounted) return;

    await showUpdateDownloadSheet(
      context,
      asset: asset,
      latestVersion: result.latestVersion,
      currentVersion: result.currentVersion,
      installer: apkInstaller,
      downloadService: downloadService,
      notificationGranted: notificationGranted,
      notificationTitle: loc.settings_update_found_version(
        result.latestVersion,
      ),
      notificationDescription: loc.settings_update_downloading,
    );
  }

  /// 安装器拉起后延时复查版本（辅助时机，不阻塞 UI）。
  ///
  /// 更新成功后本进程会被系统杀掉替换，这段代码大概率跑不到 —— 它是兜底，
  /// 真正负责「装完自动清包」的是启动时那次 `cleanupInstalledApks`。
  static Future<void> schedulePostInstallRecheck(
    ApkDownloadService service, {
    required String apkPath,
    required String currentVersion,
    Duration delay = kPostInstallRecheckDelay,
  }) async {
    try {
      await Future<void>.delayed(delay);
      final status = await service.recheckInstalledVersion(
        apkPath: apkPath,
        previousVersion: currentVersion,
      );
      if (status) {
        Logger.infoWithTag(_logTag, 'update took effect, apk removed');
      }
    } catch (e) {
      Logger.debugWithTag(_logTag, 'post-install recheck skipped', e);
    }
  }

  /// 回退：用系统浏览器打开链接（与改造前完全一致）。
  static Future<void> _openInBrowser(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        Logger.warnWithTag(_logTag, 'cannot launch url: $url');
      }
    } catch (e, st) {
      Logger.errorWithTag(_logTag, 'open url failed: $url', e, st);
    }
  }

  /// 确保拿到「安装未知应用」授权；用户拒绝返回 false。
  static Future<bool> _ensureInstallPermission(
    BuildContext context,
    ApkInstaller installer, {
    required TargetPlatform platform,
    required bool isWeb,
  }) async {
    if (await installer.canRequestPackageInstalls(
      platform: platform,
      isWeb: isWeb,
    )) {
      return true;
    }
    if (!context.mounted) return false;
    final loc = AppLocalizations.of(context);
    final goOpen = await showMusicFlowBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.settings_update_need_install_permission_title,
        constrainToAvailableHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              loc.settings_update_need_install_permission_body,
              style: sheetContext.musicFlowTypography.body.copyWith(
                color: sheetContext.musicFlowColors.muted,
              ),
            ),
            SizedBox(height: sheetContext.musicFlowSpacing.lg),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: sheetContext.musicFlowSpacing.xs,
              runSpacing: sheetContext.musicFlowSpacing.xs,
              children: <Widget>[
                MusicFlowButton.ghost(
                  label: loc.settings_later,
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                ),
                MusicFlowButton.primary(
                  label: loc.settings_update_need_install_permission_open,
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (goOpen != true) return false;

    final opened = await installer.openUnknownSourcesSettings(
      platform: platform,
      isWeb: isWeb,
    );
    if (!opened) return false;
    // 从设置页回来是**异步**的：必须先等到 resumed，再复查一次权限。
    await waitForAppResume();
    final now = await installer.canRequestPackageInstalls(
      platform: platform,
      isWeb: isWeb,
    );
    if (!now && context.mounted) {
      final loc = AppLocalizations.of(context);
      showMusicFlowMessage(
        context,
        loc.settings_update_need_install_permission_cancelled,
        kind: MusicFlowMessageKind.error,
      );
    }
    return now;
  }

  /// 等到 App 从后台回到前台（超时按已回来处理，让后续复查给出结论）。
  ///
  /// 公开给 [UpdateDownloadController] 复用：「安装未知应用」授权缺失时，
  /// 控制器同样需要「跳设置页 → 等回前台 → 复查授权 → 自动重试一次」，
  /// 这段时序必须只有一份实现，否则两处迟早走偏。
  static Future<void> waitForAppResume({
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    final completer = Completer<void>();
    AppLifecycleListener? listener;
    listener = AppLifecycleListener(
      onResume: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    try {
      await completer.future.timeout(timeout, onTimeout: () {});
    } finally {
      listener.dispose();
    }
  }
}
