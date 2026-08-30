import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/update_checker.dart';
import '../../../core/utils/logger.dart';
import '../widgets/update_available_dialog.dart';

/// 启动后延迟多久再发起更新检查。
///
/// 避开首屏渲染、自动登录与曲库拉取，避免和它们抢网络与 CPU；
/// 全程在后台异步执行，不阻塞任何交互。
const Duration kStartupUpdateCheckDelay = Duration(seconds: 3);

/// 每次启动自动检查更新的目标平台：Windows 与 Android。
///
/// Web / macOS / Linux / iOS 不做静默网络请求，也不打扰用户。
bool startupUpdateCheckSupported({
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return false;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.windows || target == TargetPlatform.android;
}

/// 应用启动后一次性在后台检查更新。
///
/// 发现新版本则弹出可关闭的提示框（[showUpdateAvailableDialog]），
/// 用户在框内点「前往下载」后直接用系统浏览器打开下载链接。
///
/// [checker] / [launcher] / [platform] 仅用于测试注入真实实现。
/// 返回是否向用户弹出了更新提示。
@visibleForTesting
Future<bool> runStartupUpdateCheck(
  BuildContext context, {
  Future<UpdateCheckResult> Function()? checker,
  Future<void> Function(String url)? launcher,
  TargetPlatform? platform,
  Duration delay = kStartupUpdateCheckDelay,
}) async {
  if (!startupUpdateCheckSupported(platform: platform)) return false;
  if (delay > Duration.zero) await Future<void>.delayed(delay);
  if (!context.mounted) return false;

  try {
    final result = await (checker ?? UpdateChecker.check)();
    if (!result.hasUpdate) return false;
    if (!context.mounted) return false;

    // 不 await 弹窗：提示框的 Future 要等用户关闭才完成，await 会把本函数
    // 一直挂起（调用方 StartupUpdateCheckScope 也就一直挂着）。
    // 这里只负责「发现更新 → 安排弹窗」，随即返回。
    unawaited(
      showUpdateAvailableDialog(
        context,
        result: result,
        platform: platform,
        onDownload: (url) {
          final launch = launcher ?? _launchInBrowser;
          unawaited(launch(url));
        },
      ),
    );
    return true;
  } catch (error, stackTrace) {
    // 更新检查是锦上添花：网络不通、平台通道缺失（如 package_info 未注册）、
    // 响应解析失败都一样——只打日志，绝不因为检查失败影响应用正常使用。
    Logger.errorWithTag(
      'UPDATE',
      'startup update check failed',
      error,
      stackTrace,
    );
    return false;
  }
}

/// 用系统浏览器打开下载链接（应用外下载/安装）。
Future<void> _launchInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// 挂在应用根部的隐形 scope：挂载后（首帧结束后）触发一次启动更新检查。
///
/// 自身不渲染任何内容，只负责调度；检查与弹窗全程异步，失败静默忽略，
/// 绝不影响应用启动与正常使用。
class StartupUpdateCheckScope extends StatefulWidget {
  const StartupUpdateCheckScope({
    super.key,
    required this.child,
    this.checker,
    this.launcher,
    this.delay = kStartupUpdateCheckDelay,
  });

  final Widget child;

  /// 测试注入的检查实现（默认 [UpdateChecker.check]）。
  final Future<UpdateCheckResult> Function()? checker;

  /// 测试注入的打开链接实现（默认系统浏览器）。
  final Future<void> Function(String url)? launcher;

  final Duration delay;

  @override
  State<StartupUpdateCheckScope> createState() =>
      _StartupUpdateCheckScopeState();
}

class _StartupUpdateCheckScopeState extends State<StartupUpdateCheckScope> {
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer != null) return;
    // 延迟由本 scope 持有 Timer：组件销毁（页面/应用退出、测试 dispose）
    // 时立即取消，不留下悬挂的定时器。
    _timer = Timer(widget.delay, () {
      _timer = null;
      if (!mounted) return;
      unawaited(
        runStartupUpdateCheck(
          context,
          checker: widget.checker,
          launcher: widget.launcher,
          // 延迟已在本 scope 完成，这里不再二次等待。
          delay: Duration.zero,
        ),
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
