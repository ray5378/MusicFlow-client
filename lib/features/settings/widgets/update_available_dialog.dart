import 'package:flutter/material.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/services/update_checker.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../widgets/windows_title_bar.dart' show isWindowsDesktop;

/// 发现新版本时弹出的提示框（启动自动检查 / 设置页手动检查共用）。
///
/// - **可关闭**：右上角关闭按钮（Windows 对话框）、「稍后再说」或点击弹窗外。
/// - **[onDownload] 直接生效**：点击「前往下载」后立刻把下载链接交给回调，
///   不再弹二次确认——启动自动检查的场景下用户已经看到版本信息，
///   多一次确认只会打断流程。
Future<void> showUpdateAvailableDialog(
  BuildContext context, {
  required UpdateCheckResult result,
  required void Function(String url) onDownload,
  TargetPlatform? platform,
}) async {
  final loc = AppLocalizations.of(context);
  final asset = pickPlatformUpdateAsset(result, platform: platform);
  final downloadUrl = asset?.downloadUrl ?? result.releaseUrl;
  VoidCallback? onDownloadPressed;
  if (downloadUrl != null) {
    onDownloadPressed = () {
      Navigator.of(context, rootNavigator: true).maybePop();
      onDownload(downloadUrl);
    };
  }

  final title = loc.settings_update_found_version(result.latestVersion);
  final subtitle = '${result.currentVersion} → ${result.latestVersion}';
  final content = UpdateAvailableContent(
    result: result,
    downloadLabel: asset?.name,
    onDownload: onDownloadPressed,
  );

  if (isWindowsDesktop) {
    // Windows 用「窗户」样式对话框，与安卓底部抽屉区分。
    return showMusicFlowDesktopDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => MusicFlowDesktopDialog(
        icon: AppIcons.download,
        title: title,
        subtitle: subtitle,
        child: content,
      ),
    );
  }
  return showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => MusicFlowBottomSheet(
      title: title,
      subtitle: subtitle,
      constrainToAvailableHeight: true,
      child: SingleChildScrollView(child: content),
    ),
  );
}

/// 更新提示框正文：版本对照 + 更新说明 + 操作按钮。
class UpdateAvailableContent extends StatelessWidget {
  const UpdateAvailableContent({
    super.key,
    required this.result,
    this.downloadLabel,
    this.onDownload,
  });

  final UpdateCheckResult result;

  /// 将下载的安装包文件名（无资源时为 null）。
  final String? downloadLabel;

  /// 为 null 时「前往下载」禁用（既没有资源也没有发布页链接）。
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final loc = AppLocalizations.of(context);
    final notes = result.releaseNotes?.trim();
    final hasNotes = notes != null && notes.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _InfoLine(label: loc.settings_current_version, value: result.currentVersion),
        _InfoLine(label: loc.settings_latest_version, value: result.latestVersion),
        if (hasNotes) ...<Widget>[
          SizedBox(height: spacing.sm),
          const MusicFlowDivider(),
          SizedBox(height: spacing.md),
          MusicFlowSectionHeader(title: loc.settings_update_notes),
          SizedBox(height: spacing.xs),
          Text(
            notes,
            style: context.musicFlowTypography.body.copyWith(
              color: context.musicFlowColors.muted,
            ),
          ),
        ],
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
              label: loc.settings_download,
              leadingIcon: AppIcons.download,
              onPressed: onDownload,
            ),
          ],
        ),
      ],
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final colors = context.musicFlowColors;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: context.musicFlowTypography.body.copyWith(
              color: colors.muted,
            ),
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: context.musicFlowTypography.body.copyWith(
                color: colors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}