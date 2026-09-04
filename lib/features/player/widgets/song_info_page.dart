import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/song.dart';
import '../../../providers/palette_provider.dart';
import '../../../providers/player_provider.dart';
import 'song_options_sheet.dart';
import '../../../l10n/generated/app_localizations.dart';

/// 歌曲信息页：全屏播放页三页结构中的左滑页。
///
/// 展示当前曲目的标签信息(歌曲/音频/文件三组)，无数据的字段整行隐藏、
/// 整组无数据时连标题一起隐藏。原「更多」菜单里的歌曲动作(下一曲播放、
/// 添加到歌单、跳转歌手/专辑等)通过底部「歌曲操作」入口继续可达。
class SongInfoPage extends ConsumerWidget {
  const SongInfoPage({super.key, required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final spacing = context.musicFlowSpacing;
    final colors = context.musicFlowColors;
    final typography = context.musicFlowTypography;
    final bitRateKbps = ref.watch(
      playerProvider.select((state) => state.currentBitRateKbps),
    );

    final artist = song.artist?.trim() ?? '';
    final album = song.album?.trim() ?? '';

    return SingleChildScrollView(
      key: const ValueKey<String>('full_player_song_info_page'),
      padding: EdgeInsets.fromLTRB(spacing.lg, spacing.md, spacing.lg, spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              song.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: typography.headline.copyWith(
                fontSize: 22,
                color: colors.ink,
              ),
            ),
          ),
          if (artist.isNotEmpty) ...<Widget>[
            SizedBox(height: spacing.xxs),
            Text(
              artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.title.copyWith(color: colors.muted),
            ),
          ],
          if (album.isNotEmpty) ...<Widget>[
            SizedBox(height: spacing.xxs),
            Text(
              album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.body.copyWith(color: colors.muted),
            ),
          ],
          SizedBox(height: spacing.lg),
          _InfoGroup(
            icon: AppIcons.music,
            title: loc.song_info_title,
            rows: <Widget?>[
              _buildRow(
                loc.song_info_duration,
                song.duration == null ? null : song.durationString,
              ),
              _buildRow(loc.song_info_genre, _nonEmpty(song.genre)),
              _buildRow(loc.song_info_disc, _optionalInt(song.discNumber)),
            ],
          ),
          SizedBox(height: spacing.lg),
          _InfoGroup(
            icon: AppIcons.equalizer,
            title: loc.song_info_audio_title,
            rows: <Widget?>[
              _buildRow(loc.song_info_file_type, _fileTypeLabel(song)),
              _buildRow(loc.song_info_bit_rate, _bitRateLabel(song, bitRateKbps)),
              _buildRow(loc.song_info_sample_rate, _samplingRateLabel(song.samplingRate)),
              _buildRow(loc.song_info_bit_depth, _bitDepthLabel(song.bitDepth)),
              _buildRow(loc.song_info_channels, _channelLabel(song.channelCount, loc)),
            ],
          ),
          SizedBox(height: spacing.lg),
          _InfoGroup(
            icon: AppIcons.fileText,
            title: loc.song_info_file_title,
            rows: <Widget?>[
              _buildRow(loc.song_info_file_size, _fileSizeLabel(song.size)),
              _buildRow(loc.song_info_path, _nonEmpty(song.path)),
            ],
          ),
          SizedBox(height: spacing.lg),
          _InfoGroup(
            icon: AppIcons.more,
            title: loc.song_info_actions_title,
            rows: <Widget?>[
              _SongActionRow(
                label: loc.song_info_song_actions,
                description: loc.song_info_song_actions_desc,
                onPressed: () => _openSongActions(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }

  _InfoRow? _buildRow(String label, String? value) {
    final resolved = value?.trim() ?? '';
    if (resolved.isEmpty) return null;
    return _InfoRow(label: label, value: resolved);
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _optionalInt(int? value) => value == null ? null : '$value';

  String? _fileTypeLabel(Song song) {
    final suffix = song.suffix?.trim();
    if (suffix != null && suffix.isNotEmpty) return suffix.toUpperCase();
    final contentType = song.contentType?.trim();
    if (contentType != null && contentType.isNotEmpty) {
      return contentType.toUpperCase();
    }
    return null;
  }

  String? _bitRateLabel(Song song, int currentBitRateKbps) {
    final raw = currentBitRateKbps > 0
        ? currentBitRateKbps
        : ((song.bitRate ?? 0) >= 10000
              ? (song.bitRate ?? 0) ~/ 1000
              : (song.bitRate ?? 0));
    if (raw <= 0) return null;
    return '$raw kbps';
  }

  String? _samplingRateLabel(int? rate) {
    if (rate == null || rate <= 0) return null;
    final khz = rate / 1000;
    if (khz == khz.truncateToDouble()) return '${khz.toInt()} kHz';
    return '${khz.toStringAsFixed(1)} kHz';
  }

  String? _bitDepthLabel(int? depth) {
    if (depth == null || depth <= 0) return null;
    return '$depth bit';
  }

  String? _channelLabel(int? channels, AppLocalizations loc) {
    if (channels == null || channels <= 0) return null;
    return switch (channels) {
      1 => loc.song_info_mono,
      2 => loc.song_info_stereo,
      _ => loc.song_info_channels_count(channels),
    };
  }

  String? _fileSizeLabel(int? bytes) {
    if (bytes == null || bytes <= 0) return null;
    final mb = bytes / 1024 / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }

  Future<void> _openSongActions(BuildContext context, WidgetRef ref) async {
    final mediaVisuals = ref.read(resolvedCurrentSongMediaVisualsProvider);
    await showSongOptionsSheet(
      context: context,
      song: song,
      mediaVisuals: mediaVisuals,
    );
  }
}

/// 一组「图标 + 分组标题」的信息条目。全部条目为空时整组不渲染。
class _InfoGroup extends StatelessWidget {
  const _InfoGroup({
    required this.icon,
    required this.title,
    required this.rows,
  });

  final IconData icon;
  final String title;
  final List<Widget?> rows;

  @override
  Widget build(BuildContext context) {
    final visibleRows = rows.whereType<Widget>().toList(growable: false);
    if (visibleRows.isEmpty) return const SizedBox.shrink();

    final spacing = context.musicFlowSpacing;
    final colors = context.musicFlowColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 18, color: colors.muted),
            SizedBox(width: spacing.xs),
            Text(
              title,
              style: context.musicFlowTypography.title.copyWith(
                color: colors.ink,
              ),
            ),
          ],
        ),
        SizedBox(height: spacing.xs),
        for (final row in visibleRows) row,
      ],
    );
  }
}

/// 只读的「标签 — 值」信息行。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
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
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
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

/// 信息页里打开「歌曲操作」面板的可按压入口行。
class _SongActionRow extends StatelessWidget {
  const _SongActionRow({
    required this.label,
    required this.description,
    required this.onPressed,
  });

  final String label;
  final String description;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    return MusicFlowPressable(
      semanticLabel: loc.song_info_action_row(label, description),
      onPressed: onPressed,
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.minimumTouchTarget,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
        child: Row(
          children: <Widget>[
            Text(
              label,
              style: context.musicFlowTypography.body.copyWith(
                color: colors.ink,
              ),
            ),
            const Spacer(),
            Icon(AppIcons.chevronRight, size: 18, color: colors.muted),
          ],
        ),
      ),
    );
  }
}
