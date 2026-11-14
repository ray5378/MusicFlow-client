import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 学习模块的通用列表行。
///
/// 从 `study_home_page.dart` 提取出来：学习模块首页与「进入文件夹」页共用同一套
/// 行样式，保证两处观感完全一致（文件夹行 / 歌单行 / 空态 / 错误态 / 加载态）。

/// 文件夹行：点击**进入**该文件夹（不再原地展开），右侧箭头恒为 `>`。
class StudyFolderRow extends StatelessWidget {
  const StudyFolderRow({
    super.key,
    required this.name,
    required this.playlistCount,
    required this.folderCount,
    required this.onTap,
    this.onLongPress,
  });

  final String name;

  /// 直属歌单数（只算这一层，不含子文件夹里的）。
  final int playlistCount;

  /// 直属子文件夹数。
  final int folderCount;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final loc = AppLocalizations.of(context);
    // 「3 个歌单 · 2 个子文件夹」；没有子文件夹时不显示后半段，保持行简短。
    final subtitle = <String>[
      loc.study_folder_playlist_count(playlistCount),
      if (folderCount > 0) loc.study_folder_subfolder_count(folderCount),
    ].join(' · ');
    return MusicFlowPressable(
      onPressed: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      borderRadius: context.musicFlowRadii.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(AppIcons.folder, size: 22, color: colors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.body,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: colors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(AppIcons.chevronRight, size: 18, color: colors.muted),
          ],
        ),
      ),
    );
  }
}

/// 通用可点行（歌单、学习源、单条学习内容都用它）。
class StudyRow extends StatelessWidget {
  const StudyRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
    this.onIconTap,
    this.iconLabel,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 图标本身作为播放入口(歌单行),与整行点击(进入详情)区分。
  final VoidCallback? onIconTap;
  final String? iconLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return MusicFlowPressable(
      onPressed: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      borderRadius: context.musicFlowRadii.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: <Widget>[
            if (onIconTap != null)
              MusicFlowIconButton(
                icon: icon,
                label: iconLabel ?? title,
                onPressed: onIconTap,
              )
            else
              Icon(icon, size: 22, color: colors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.body,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.metadata.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Icon(AppIcons.chevronRight, size: 18, color: colors.muted),
          ],
        ),
      ),
    );
  }
}

/// 空态行（图标 + 一句灰字）。
class StudyEmptyRow extends StatelessWidget {
  const StudyEmptyRow({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: colors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: context.musicFlowTypography.metadata.copyWith(
                color: colors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误态行（提示 + 重试）。
class StudyErrorRow extends StatelessWidget {
  const StudyErrorRow({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(
            AppIcons.warning,
            size: 18,
            color: context.musicFlowColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ),
          MusicFlowButton.ghost(label: loc.widgets_retry, onPressed: onRetry),
        ],
      ),
    );
  }
}

/// 加载态：一条细进度条（保持列表高度不跳）。
class StudyLoadingRows extends StatelessWidget {
  const StudyLoadingRows({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 18),
      child: LinearProgressIndicator(minHeight: 2),
    );
  }
}
