import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/features/settings/widgets/update_available_dialog.dart';
import 'package:musicflow_client/providers/settings/update_channel_provider.dart';

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

/// 默认通道读取：从 [updateChannelProvider] 取当前通道。
///
/// 挂载在 MaterialApp.builder 层的 scope 其 context 位于 Navigator 之上，
/// 但仍在 ProviderScope 之内，containerOf 可用；拿不到时按默认 gitee 兜底
/// （更新检查是锦上添花，绝不因通道读取失败影响启动）。
Future<UpdateChannel> _defaultChannelReader(BuildContext context) async {
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    return container.read(updateChannelProvider);
  } catch (error) {
    Logger.errorWithTag('UPDATE', 'read update channel failed', error);
    return UpdateChannel.gitee;
  }
}

/// 应用启动后一次性在后台检查更新。
///
/// 发现新版本则弹出可关闭的提示框（[showUpdateAvailableDialog]）。
///
/// 检查通道：未注入 [checker] 时按用户设置的更新通道走
/// （通道来自 [channelReader]，默认读 [updateChannelProvider]，缺省 gitee）；
/// gitee 通道失败会自动回退 GitHub 并在结果上打 viaFallback 标注。
///
/// 用户在框内点「前往下载」后：
/// - 传了 [installer]（Android 生产环境）→ 走**内置更新**：直下 apk → 校验 →
///   唤起系统安装器，全程不离开应用；
/// - 没传（默认，含全部既有测试）→ 行为与改造前**完全一致**，用系统浏览器
///   打开下载链接。
///
/// [checker] / [launcher] / [platform] / [installer] / [channelReader] 仅用于
/// 测试注入真实实现。
/// [navigatorKey] 为根导航器 key：scope 挂载在 MaterialApp.builder 层时
/// 其 context 位于 Navigator **之上**，showDialog 找不到 Navigator 会静默失败，
/// 因此弹窗必须改用 Navigator 之下（overlay）的 context（生产环境必传）。
/// 返回是否向用户弹出了更新提示。
@visibleForTesting
Future<bool> runStartupUpdateCheck(
  BuildContext context, {
  Future<UpdateCheckResult> Function()? checker,
  Future<void> Function(String url)? launcher,
  Future<void> Function(BuildContext context, UpdateCheckResult result)?
  installer,
  TargetPlatform? platform,
  Duration delay = kStartupUpdateCheckDelay,
  GlobalKey<NavigatorState>? navigatorKey,
  Future<UpdateChannel> Function(BuildContext context)? channelReader,
}) async {
  if (!startupUpdateCheckSupported(platform: platform)) return false;
  if (delay > Duration.zero) await Future<void>.delayed(delay);
  if (!context.mounted) return false;

  try {
    // 未注入 checker（生产路径）时按用户通道检查；注入 checker 的既有测试
    // 行为一个字节都不变。
    final effectiveChecker = checker ?? () async {
      final channel = await (channelReader ?? _defaultChannelReader)(context);
      return UpdateChecker.check(channel: channel);
    };
    final result = await effectiveChecker();
    if (!result.hasUpdate) return false;

    // 弹窗上下文：优先用根 Navigator 的 overlay context（在 Navigator 之下），
    // 避免 MaterialApp.builder 层 context 找不到 Navigator 导致弹窗静默失败。
    final dialogContext =
        navigatorKey?.currentState?.overlay?.context ?? context;
    if (!dialogContext.mounted) return false;

    // 不 await 弹窗：提示框的 Future 要等用户关闭才完成，await 会把本函数
    // 一直挂起（调用方 StartupUpdateCheckScope 也就一直挂着）。
    // 这里只负责「发现更新 → 安排弹窗」，随即返回。
    unawaited(
      _showUpdateDialogSafely(
        dialogContext,
        result: result,
        platform: platform,
        launcher: launcher ?? _launchInBrowser,
        installer: installer,
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

/// 弹窗调用的安全包装：showDialog 在找不到 Navigator（context 在 Navigator
/// 之上）等情况下会抛错。弹窗是锦上添花，任何失败只打日志、绝不外溢成
/// 未处理异常（否则 unawaited 会让异常变成无人处理的异步错误）。
Future<void> _showUpdateDialogSafely(
  BuildContext context, {
  required UpdateCheckResult result,
  required TargetPlatform? platform,
  required Future<void> Function(String url) launcher,
  Future<void> Function(BuildContext context, UpdateCheckResult result)?
  installer,
}) async {
  try {
    await showUpdateAvailableDialog(
      context,
      result: result,
      platform: platform,
      onDownload: (url) {
        // 有 installer（仅 Android 生产环境传）→ 内置更新：直下 apk + 唤装。
        // 没传 → 与改造前逐字一致，交给系统浏览器。
        final builtIn = installer;
        if (builtIn != null) {
          unawaited(builtIn(context, result));
          return;
        }
        unawaited(launcher(url));
      },
    );
  } catch (error, stackTrace) {
    Logger.errorWithTag(
      'UPDATE',
      'startup update dialog failed',
      error,
      stackTrace,
    );
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
    this.installer,
    this.delay = kStartupUpdateCheckDelay,
    this.navigatorKey,
    this.channelReader,
  });

  final Widget child;

  /// 测试注入的检查实现（默认按用户通道调 [UpdateChecker.check]）。
  final Future<UpdateCheckResult> Function()? checker;

  /// 测试注入的打开链接实现（默认系统浏览器）。
  final Future<void> Function(String url)? launcher;

  /// 内置更新入口（仅 Android 生产环境由 app.dart 传入）。
  ///
  /// 为 null 时「前往下载」走 [launcher]（系统浏览器），与改造前完全一致；
  /// 非 null 时改为直下 apk + 唤装（见 `AppUpdateInstaller`）。
  final Future<void> Function(BuildContext context, UpdateCheckResult result)?
  installer;

  final Duration delay;

  /// 根导航器 key：弹窗需要 Navigator 之下的 context（scope 在
  /// MaterialApp.builder 层时其自身 context 在 Navigator 之上，见
  /// [runStartupUpdateCheck]）。生产环境由 app.dart 传入。
  final GlobalKey<NavigatorState>? navigatorKey;

  /// 测试注入的通道读取实现（默认读 [updateChannelProvider]）。
  final Future<UpdateChannel> Function(BuildContext context)? channelReader;

  @override
  State<StartupUpdateCheckScope> createState() =>
      _StartupUpdateCheckScopeState();
}

class _StartupUpdateCheckScopeState extends State<StartupUpdateCheckScope> {
  Timer? _timer;

  /// 一次性守卫(v5.1.8):didChangeDependencies 在 Timer 触发后以及此后任何
  /// 主题/语言/MediaQuery 变化时都会再次回调,不能拿「_timer 是否在跑」当守卫
  /// —— 触发后 _timer 已置 null,会再次发起检查并可能重复弹窗。
  bool _ran = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ran) return;
    _ran = true;
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
          installer: widget.installer,
          // 延迟已在本 scope 完成，这里不再二次等待。
          delay: Duration.zero,
          navigatorKey: widget.navigatorKey,
          channelReader: widget.channelReader,
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
