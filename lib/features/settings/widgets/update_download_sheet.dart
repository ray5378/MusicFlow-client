import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/services/apk_installer.dart';
import 'package:musicflow_client/core/services/notification_permission_service.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/settings/update_download_provider.dart';

/// 弹出「下载更新包」浮层。
///
/// ## 这是一个**纯展示**浮层
///
/// 下载任务归 [UpdateDownloadController] 所有（与 App 进程同生命周期），
/// 本浮层只 `ref.watch` 它的状态来画进度 / 失败 / 完成。
///
/// 因此：
///
/// - **拖掉浮层 ≠ 取消下载**：下载继续（`DownloadManager` 在后台跑，通知栏
///   仍有进度），下完后照样自动唤装；
/// - 只有点「取消下载」才会真正打断下载并删包。
///
/// `asset` / `installer` / `downloadService` / `notificationGranted` 等参数保留
/// 只为**兼容既有调用点**：真正的启动动作由调用方（`AppUpdateInstaller`）
/// 直接调 `controller.start(...)` 完成。
Future<void> showUpdateDownloadSheet(
  BuildContext context, {
  required ReleaseAsset asset,
  required String latestVersion,
  required String currentVersion,
  required ApkInstaller installer,
  required ApkDownloadService downloadService,
  bool notificationGranted = true,
  String? notificationTitle,
  String? notificationDescription,
}) {
  final loc = AppLocalizations.of(context);
  return showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => MusicFlowBottomSheet(
      title: loc.settings_update_downloading,
      subtitle: '$currentVersion → $latestVersion',
      constrainToAvailableHeight: true,
      child: UpdateDownloadSheet(
        asset: asset,
        latestVersion: latestVersion,
        currentVersion: currentVersion,
        installer: installer,
        downloadService: downloadService,
        notificationGranted: notificationGranted,
        notificationTitle: notificationTitle,
        notificationDescription: notificationDescription,
      ),
    ),
  );
}

/// 下载浮层正文（四态：下载中 / 失败 / 完成 / 已取消）。
///
/// 所有状态都来自 [updateDownloadControllerProvider]，本类**不持有**任何
/// 下载相关的可变状态，也不发起下载。
class UpdateDownloadSheet extends ConsumerStatefulWidget {
  const UpdateDownloadSheet({
    super.key,
    required this.asset,
    required this.latestVersion,
    required this.currentVersion,
    required this.installer,
    required this.downloadService,
    this.notificationGranted = true,
    this.notificationTitle,
    this.notificationDescription,
  });

  /// 当前要下载的资产（进度文案里「总量」的兜底来源）。
  final ReleaseAsset asset;
  final String latestVersion;
  final String currentVersion;

  /// 保留仅为了兼容既有调用点；下载与唤装现在由控制器负责。
  final ApkInstaller installer;

  /// 保留仅为了兼容既有调用点。
  final ApkDownloadService downloadService;

  /// 通知权限（未授予仍会下载，只是通知栏看不到进度）。
  final bool notificationGranted;
  final String? notificationTitle;
  final String? notificationDescription;

  @override
  ConsumerState<UpdateDownloadSheet> createState() =>
      _UpdateDownloadSheetState();
}

class _UpdateDownloadSheetState extends ConsumerState<UpdateDownloadSheet> {
  /// **必须在 `initState` 里先抓成字段**：`ref` 在 `dispose()` 之后不可用，
  /// 而 `dispose()` 里要通知控制器「浮层已经不在屏上了」。
  late final UpdateDownloadController _controller;

  /// 防止重复 pop（取消提示与用户手动关闭可能撞在一起）。
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(updateDownloadControllerProvider.notifier);
    // 不能在 build 期改 provider：等这一帧画完再置可见性。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.setSheetVisible(true);
    });
  }

  @override
  void dispose() {
    // ⚠️ 这里只报告"视图关了"。绝**不**取消下载、绝不删包 —— 那正是本文件
    // 改造前的 bug（拖掉浮层 = 取消下载 + 删包，几十 MB 白下）。
    //
    // 也**不能**在这里同步改 provider：`ConsumerStatefulElement.unmount()`
    // 是「先 `super.unmount()`（触发本 dispose）→ 再关闭订阅」，同步写状态
    // 会对已经 defunct 的元素 `markNeedsBuild`（debug 断言 / 订阅泄漏）。
    // 丢进微任务，等 unmount 彻底收尾后再置。
    final controller = _controller;
    Future<void>.microtask(() => controller.setSheetVisible(false));
    super.dispose();
  }

  /// 只关视图，不碰下载任务。
  void _closeView() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final spacing = context.musicFlowSpacing;
    final colors = context.musicFlowColors;
    final textStyle = context.musicFlowTypography.body.copyWith(
      color: colors.muted,
    );
    final state = ref.watch(updateDownloadControllerProvider);

    // 用户点了「取消下载」：下载层已经把半截包删干净，这里只补一句提示 + 关视图。
    ref.listen<UpdateDownloadState>(updateDownloadControllerProvider, (
      previous,
      next,
    ) {
      final cancelled =
          previous?.stage == UpdateDownloadStage.downloading &&
          next.stage == UpdateDownloadStage.idle;
      if (!cancelled || !mounted) return;
      showMusicFlowMessage(context, loc.settings_update_download_cancelled);
      _closeView();
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!widget.notificationGranted) ...<Widget>[
          Text(loc.settings_update_notification_off_hint, style: textStyle),
          SizedBox(height: spacing.xs),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: MusicFlowButton.ghost(
              label: loc.settings_update_notification_open,
              onPressed: () => unawaited(openNotificationPermissionSettings()),
            ),
          ),
          SizedBox(height: spacing.sm),
          const MusicFlowDivider(),
        ],
        SizedBox(height: spacing.sm),
        ..._buildBody(context, loc, textStyle, spacing, state),
      ],
    );
  }

  List<Widget> _buildBody(
    BuildContext context,
    AppLocalizations loc,
    TextStyle textStyle,
    MusicFlowSpacing spacing,
    UpdateDownloadState state,
  ) {
    switch (state.stage) {
      case UpdateDownloadStage.downloading:
        final progress = state.progress;
        final fraction = progress?.fraction ?? 0.0;
        final percent = (fraction * 100).round();
        return <Widget>[
          MusicFlowProgressBar(
            value: fraction,
            height: 6,
            semanticLabel: loc.settings_update_downloading,
          ),
          SizedBox(height: spacing.sm),
          Text(
            loc.settings_update_download_progress(
              '$percent',
              _formatBytes(progress?.received ?? 0),
              _formatBytes(progress?.total ?? widget.asset.size),
            ),
            style: textStyle,
          ),
          if ((progress?.speedBytesPerSec ?? 0) > 0) ...<Widget>[
            SizedBox(height: spacing.xxs),
            Text(
              loc.settings_update_download_speed(
                '${_formatBytes((progress?.speedBytesPerSec ?? 0).round())}/s',
              ),
              style: context.musicFlowTypography.body.copyWith(
                color: context.musicFlowColors.muted,
                fontSize: 12,
              ),
            ),
          ],
          SizedBox(height: spacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: spacing.xs,
            runSpacing: spacing.xs,
            children: <Widget>[
              // 「取消下载」是真取消（打断下载 + 删包），和「后台下载」语义不同。
              MusicFlowButton.ghost(
                label: loc.settings_update_download_cancel,
                onPressed: _controller.cancel,
              ),
              MusicFlowButton.primary(
                label: loc.settings_update_download_background,
                onPressed: _closeView,
              ),
            ],
          ),
        ];
      case UpdateDownloadStage.failed:
        return <Widget>[
          Text(
            loc.settings_update_download_failed(_shortReason(state.errorMessage)),
            style: context.musicFlowTypography.body.copyWith(
              color: context.musicFlowColors.error,
            ),
          ),
          SizedBox(height: spacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: spacing.xs,
            runSpacing: spacing.xs,
            children: <Widget>[
              MusicFlowButton.ghost(
                label: loc.settings_later,
                onPressed: _closeView,
              ),
              MusicFlowButton.primary(
                label: loc.widgets_retry,
                leadingIcon: AppIcons.refresh,
                // 参数全在控制器里，浮层不必持有 asset/installer/service。
                onPressed: () => unawaited(_controller.retry()),
              ),
            ],
          ),
        ];
      case UpdateDownloadStage.completed:
        return <Widget>[
          MusicFlowProgressBar(value: 1, height: 6),
          SizedBox(height: spacing.sm),
          Text(loc.settings_update_download_ready, style: textStyle),
          if (state.apkPath != null) ...<Widget>[
            SizedBox(height: spacing.lg),
            Wrap(
              alignment: WrapAlignment.end,
              children: <Widget>[
                MusicFlowButton.primary(
                  label: loc.settings_update_install_again,
                  onPressed: () => unawaited(_controller.installNow()),
                ),
              ],
            ),
          ],
        ];
      case UpdateDownloadStage.idle:
        // 正常情况走到这里之前已经被 ref.listen 关掉了；留一个兜底视图，
        // 避免"取消了但浮层没关"时出现空白面板。
        return <Widget>[
          Text(loc.settings_update_download_cancelled, style: textStyle),
          SizedBox(height: spacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            children: <Widget>[
              MusicFlowButton.ghost(
                label: loc.settings_later,
                onPressed: _closeView,
              ),
            ],
          ),
        ];
    }
  }

  /// 失败原因只给一句能看懂的，原始 message 已经进日志了。
  String _shortReason(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    if (raw.length <= 160) return raw;
    return '${raw.substring(0, 157)}…';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    final digits = value >= 100 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }
}
