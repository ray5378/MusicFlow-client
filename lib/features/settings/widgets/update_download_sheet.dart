import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/services/apk_installer.dart';
import 'package:musicflow_client/core/services/notification_permission_service.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

const String _logTag = 'APK_SHEET';

/// 弹出「下载更新包」浮层，内部自带三态：下载中 / 失败（可重试）/ 完成（自动唤装）。
///
/// 下载本身交给 [ApkDownloadService]：Android 上走系统 `DownloadManager`
/// （后台不断 + 通知栏进度），其它平台走 Dio。
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

/// 下载浮层正文（三态）。
class UpdateDownloadSheet extends StatefulWidget {
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

  final ReleaseAsset asset;
  final String latestVersion;
  final String currentVersion;
  final ApkInstaller installer;
  final ApkDownloadService downloadService;
  final bool notificationGranted;
  final String? notificationTitle;
  final String? notificationDescription;

  @override
  State<UpdateDownloadSheet> createState() => _UpdateDownloadSheetState();
}

enum _SheetStage { downloading, failed, completed }

class _UpdateDownloadSheetState extends State<UpdateDownloadSheet> {
  _SheetStage _stage = _SheetStage.downloading;
  ApkDownloadProgress? _progress;
  String? _errorMessage;
  CancelToken? _cancelToken;
  String? _apkPath;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    // 页面销毁（用户拖掉浮层）时取消下载，避免后台继续下一份用户已经不想要
    // 的包。DownloadManager 引擎会连带删掉文件。
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final token = CancelToken();
    _cancelToken = token;
    if (mounted) {
      setState(() {
        _stage = _SheetStage.downloading;
        _errorMessage = null;
        _progress = null;
        _cancelled = false;
      });
    }
    try {
      final file = await widget.downloadService.download(
        widget.asset,
        cancelToken: token,
        version: widget.latestVersion,
        notificationTitle: widget.notificationTitle,
        notificationDescription: widget.notificationDescription,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      _apkPath = file.path;
      setState(() => _stage = _SheetStage.completed);
      await _install(file.path);
    } on ApkDownloadException catch (e) {
      if (!mounted) return;
      if (_cancelled) {
        _popWithCancelNotice();
        return;
      }
      Logger.warnWithTag(_logTag, 'apk download failed: ${e.message}');
      setState(() {
        _stage = _SheetStage.failed;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      Logger.errorWithTag(_logTag, 'apk download threw', e);
      setState(() {
        _stage = _SheetStage.failed;
        _errorMessage = '$e';
      });
    }
  }

  Future<void> _install(String path) async {
    final loc = AppLocalizations.of(context);
    final opened = await widget.installer.installApk(path);
    if (!mounted) return;
    if (opened) {
      showMusicFlowMessage(
        context,
        loc.settings_update_install_hint,
        kind: MusicFlowMessageKind.success,
      );
      Navigator.of(context).maybePop();
      // 辅助复查（大概率跑不到：更新成功后本进程会被系统杀掉替换）。
      unawaited(_scheduleRecheck(path));
      return;
    }
    showMusicFlowMessage(
      context,
      loc.settings_update_install_open_failed,
      kind: MusicFlowMessageKind.error,
    );
    unawaited(widget.installer.openUnknownSourcesSettings());
  }

  Future<void> _scheduleRecheck(String path) async {
    try {
      await Future<void>.delayed(const Duration(seconds: 3));
      final applied = await widget.downloadService.recheckInstalledVersion(
        apkPath: path,
        previousVersion: widget.currentVersion,
      );
      if (applied) {
        Logger.infoWithTag(_logTag, 'update applied, apk purged');
      }
    } catch (e) {
      Logger.debugWithTag(_logTag, 'post-install recheck skipped', e);
    }
  }

  void _popWithCancelNotice() {
    final loc = AppLocalizations.of(context);
    showMusicFlowMessage(context, loc.settings_update_download_cancelled);
    Navigator.of(context).maybePop();
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelToken?.cancel();
    // DM 引擎靠轮询里的 isCancelled 分支收尾；dio 引擎靠 CancelToken。
    // 两者都会自己删半截文件 + 删 meta，所以这里不再动文件。
  }

  void _retry() {
    unawaited(_start());
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final spacing = context.musicFlowSpacing;
    final colors = context.musicFlowColors;
    final textStyle = context.musicFlowTypography.body.copyWith(
      color: colors.muted,
    );

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
        ..._buildBody(context, loc, textStyle, spacing),
      ],
    );
  }

  List<Widget> _buildBody(
    BuildContext context,
    AppLocalizations loc,
    TextStyle textStyle,
    MusicFlowSpacing spacing,
  ) {
    switch (_stage) {
      case _SheetStage.downloading:
        final progress = _progress;
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
            children: <Widget>[
              MusicFlowButton.ghost(
                label: loc.settings_update_download_cancel,
                onPressed: _cancel,
              ),
            ],
          ),
        ];
      case _SheetStage.failed:
        return <Widget>[
          Text(
            loc.settings_update_download_failed(_shortReason(_errorMessage)),
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
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              MusicFlowButton.primary(
                label: loc.widgets_retry,
                leadingIcon: AppIcons.refresh,
                onPressed: _retry,
              ),
            ],
          ),
        ];
      case _SheetStage.completed:
        return <Widget>[
          MusicFlowProgressBar(value: 1, height: 6),
          SizedBox(height: spacing.sm),
          Text(loc.settings_update_download_ready, style: textStyle),
          if (_apkPath != null) ...<Widget>[
            SizedBox(height: spacing.lg),
            Wrap(
              alignment: WrapAlignment.end,
              children: <Widget>[
                MusicFlowButton.primary(
                  label: loc.settings_update_install_again,
                  onPressed: () => unawaited(_install(_apkPath!)),
                ),
              ],
            ),
          ],
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
