import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/song_source_label.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart' show isWindowsDesktop;

/// 打开「歌曲信息」弹窗。
///
/// 字段与主项目「歌曲信息」弹窗的基础字段一致（标题 / 歌手 / 专辑 / 时长 /
/// 码率·格式 / 年份 / 专辑艺人 / 作曲 / 风格 / 音轨），最后一行是「保存路径 / 来源」：
/// 平台(web)歌曲显示「平台中文名（插件名）」，本地 / WebDAV 显示剥掉 `w:<源id>:`
/// 前缀的真实路径。
///
/// 刻意**不含**原始标签折叠块、**不含**歌词概况、**不调用**详情接口 —— 仅用传入的
/// [song] 渲染。空值整行不显示。
///
/// 平台样式沿用仓库惯例：桌面端（Windows）用「窗户」样式对话框，其余用底部抽屉。
Future<void> showSongInfoDialog({
  required BuildContext context,
  required Song song,
}) {
  if (isWindowsDesktop) {
    return showMusicFlowDesktopDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => MusicFlowDesktopDialog(
        icon: AppIcons.info,
        title: AppLocalizations.of(dialogContext).song_info_title,
        child: _SongInfoContent(song: song),
      ),
    );
  }
  return showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => MusicFlowBottomSheet(
      title: AppLocalizations.of(sheetContext).song_info_title,
      constrainToAvailableHeight: true,
      child: SingleChildScrollView(child: _SongInfoContent(song: song)),
    ),
  );
}

/// 歌曲信息正文：一组「标签 — 值」行；值为空的整行不渲染。
class _SongInfoContent extends StatelessWidget {
  const _SongInfoContent({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final isWeb = isPlatformSong(song);

    final rows = <Widget?>[
      _InfoRow(label: loc.song_info_field_title, value: song.title),
      _InfoRow(label: loc.song_info_field_artist, value: song.artist),
      _InfoRow(label: loc.song_info_field_album, value: song.album),
      // 时长复用 Song.durationString（与歌曲信息页同一格式化实现）。
      _InfoRow(
        label: loc.song_info_duration,
        value: song.duration == null ? null : song.durationString,
      ),
      _InfoRow(label: loc.song_info_bit_rate, value: _bitRateAndFormat(song)),
      _InfoRow(
        label: loc.song_info_field_year,
        value: song.year == null ? null : '${song.year}',
      ),
      _InfoRow(label: loc.song_info_field_album_artist, value: song.albumArtist),
      _InfoRow(label: loc.song_info_field_composer, value: song.composer),
      _InfoRow(label: loc.song_info_field_genre, value: song.genre),
      _InfoRow(
        label: loc.song_info_field_track,
        value: song.track == null ? null : '${song.track}',
      ),
      // 最后一行：保存路径 / 来源（标签随类型动态变化）。
      _InfoRow(
        label: isWeb ? loc.song_info_source : loc.song_info_saved_path,
        value: isWeb
            ? platformSongSourceValue(song, loc)
            : savedPathValue(song),
      ),
    ];

    final visible = rows.whereType<Widget>().toList(growable: false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: visible,
    );
  }

  /// 码率·格式：`<bitRate> kbps · <SUFFIX>`；只有一侧时有值就只显示那一侧。
  String? _bitRateAndFormat(Song song) {
    final rate = song.bitRate ?? 0;
    final hasRate = rate > 0;
    final suffix = (song.suffix ?? '').trim();
    final format = suffix.isEmpty ? '' : suffix.toUpperCase();
    if (!hasRate && format.isEmpty) return null;
    if (!hasRate) return format;
    return format.isEmpty ? '$rate kbps' : '$rate kbps · $format';
  }
}

/// 只读的「标签 — 值」信息行（镜像歌曲信息页的行样式）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final resolved = value?.trim() ?? '';
    if (resolved.isEmpty) return const SizedBox.shrink();

    final colors = context.musicFlowColors;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: context.musicFlowTypography.body.copyWith(
                color: colors.muted,
              ),
            ),
          ),
          SizedBox(width: context.musicFlowSpacing.md),
          Expanded(
            child: Text(
              resolved,
              textAlign: TextAlign.end,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
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
