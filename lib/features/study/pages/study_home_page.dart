import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/study/pages/study_browse_page.dart';
import 'package:musicflow_client/features/study/pages/study_playlist_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

/// 学习模块首页：总目录 / 学习歌单 / 继续学习。
///
/// 对齐网页端学习页的三段结构；「最近添加」不在此展示（用户定稿）。
class StudyHomePage extends ConsumerWidget {
  const StudyHomePage({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(studySourcesProvider);
    ref.invalidate(studyPlaylistsProvider);
    ref.invalidate(studyContinueProvider);
    await Future.wait<void>(<Future<void>>[
      ref.read(studySourcesProvider.future).then((_) {}),
      ref.read(studyPlaylistsProvider.future).then((_) {}),
      ref.read(studyContinueProvider.future).then((_) {}),
    ]).catchError((Object _) => <void>[]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 进入学习模块即激活学习进度上报（应用级单例，重复读取无副作用）。
    ref.read(studyProgressReporterProvider);
    final loc = AppLocalizations.of(context);
    final sources = ref.watch(studySourcesProvider);
    final playlists = ref.watch(studyPlaylistsProvider);
    final continuing = ref.watch(studyContinueProvider);

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(
        context: context,
        title: loc.study_title,
      ),
      body: MusicFlowRefreshView(
        onRefresh: () => _refresh(ref),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: EdgeInsets.only(
                left: context.musicFlowPageHorizontalPadding,
                right: context.musicFlowPageHorizontalPadding,
                bottom: 32,
              ),
              children: <Widget>[
                _Section(
                  title: loc.study_section_catalog,
                  child: _buildSources(context, ref, loc, sources),
                ),
                _Section(
                  title: loc.study_section_playlists,
                  child: _buildPlaylists(context, ref, loc, playlists),
                ),
                _Section(
                  title: loc.study_section_continue,
                  child: _buildContinue(context, ref, loc, continuing),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSources(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations loc,
    AsyncValue<List<StudySource>> async,
  ) {
    return async.when(
      loading: () => const _LoadingRows(),
      error: (error, _) => _ErrorRow(
        message: loc.study_load_failed,
        onRetry: () => ref.invalidate(studySourcesProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return _EmptyRow(
            icon: AppIcons.study,
            label: loc.study_empty_catalog,
          );
        }
        return Column(
          children: <Widget>[
            for (final source in items)
              _StudyRow(
                icon: AppIcons.study,
                title: source.name,
                subtitle: source.songCount > 0
                    ? loc.study_source_song_count(source.songCount)
                    : null,
                onTap: () => _openBrowse(context, source),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPlaylists(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations loc,
    AsyncValue<List<StudyPlaylist>> async,
  ) {
    return async.when(
      loading: () => const _LoadingRows(),
      error: (error, _) => _ErrorRow(
        message: loc.study_load_failed,
        onRetry: () => ref.invalidate(studyPlaylistsProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return _EmptyRow(
            icon: AppIcons.playlist,
            label: loc.study_empty_playlists,
          );
        }
        return Column(
          children: <Widget>[
            for (final playlist in items)
              _StudyRow(
                icon: AppIcons.playlist,
                title: playlist.name,
                subtitle: loc.study_playlist_song_count(playlist.songCount),
                onTap: () {
                  unawaited(
                    Navigator.of(context).push<void>(
                      MusicFlowPageRoute<void>(
                        context: context,
                        builder: (_) => StudyPlaylistPage(
                          playlistId: playlist.id,
                          title: playlist.name,
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildContinue(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations loc,
    AsyncValue<List<StudyContinueItem>> async,
  ) {
    return async.when(
      loading: () => const _LoadingRows(),
      error: (error, _) => _ErrorRow(
        message: loc.study_load_failed,
        onRetry: () => ref.invalidate(studyContinueProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return _EmptyRow(
            icon: AppIcons.history,
            label: loc.study_empty_continue,
          );
        }
        final currentId =
            ref.watch(playerProvider.select((s) => s.currentSong?.id));
        return Column(
          children: <Widget>[
            for (var i = 0; i < items.length; i++)
              _ContinueRow(
                item: items[i],
                playing: items[i].song.id == currentId,
                onTap: () => unawaited(_playContinue(ref, items, i)),
              ),
          ],
        );
      },
    );
  }

  void _openBrowse(BuildContext context, StudySource source) {
    unawaited(
      Navigator.of(context).push<void>(
        MusicFlowPageRoute<void>(
          context: context,
          builder: (_) => StudyBrowsePage(
            sourceId: source.id,
            sourceName: source.name,
            path: '',
          ),
        ),
      ),
    );
  }

  /// 继续学习：本机续播从上次进度起播；投屏/直投交给流转链路（对端起播）。
  Future<void> _playContinue(
    WidgetRef ref,
    List<StudyContinueItem> items,
    int index,
  ) async {
    final songs = <Song>[for (final item in items) item.song];
    final casting =
        ref.read(castPeerControllerProvider).activePeer != null ||
        ref.read(dlnaCastProvider).isCasting;
    if (casting) {
      await playEffectiveQueue(ref, songs, startIndex: index);
      return;
    }
    await ref.read(playerProvider.notifier).playQueue(
          songs,
          startIndex: index,
          initialPosition: Duration(seconds: items[index].positionSec),
        );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: MusicFlowSectionHeader(title: title),
        ),
        child,
      ],
    );
  }
}

class _StudyRow extends StatelessWidget {
  const _StudyRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return MusicFlowPressable(
      onPressed: onTap,
      borderRadius: context.musicFlowRadii.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: <Widget>[
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

/// 继续学习行：带进度环与剩余位置。
class _ContinueRow extends StatelessWidget {
  const _ContinueRow({
    required this.item,
    required this.playing,
    required this.onTap,
  });

  final StudyContinueItem item;
  final bool playing;
  final VoidCallback onTap;

  static String _formatSeconds(int seconds) {
    if (seconds <= 0) return '00:00';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final progress = item.progress.clamp(0.0, 1.0).toDouble();
    final percent = (progress * 100).round();
    return MusicFlowPressable(
      onPressed: onTap,
      borderRadius: context.musicFlowRadii.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: 30,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2.4,
                    backgroundColor: colors.muted.withValues(alpha: 0.25),
                    valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
                  ),
                  Icon(
                    playing ? AppIcons.equalizer : AppIcons.play,
                    size: 13,
                    color: playing ? colors.accent : colors.ink,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.body.copyWith(
                      color: playing ? colors.accent : colors.ink,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${_formatSeconds(item.positionSec)} · $percent%',
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: colors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.icon, required this.label});

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

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(AppIcons.warning, size: 18, color: context.musicFlowColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ),
          MusicFlowButton.ghost(
            label: loc.widgets_retry,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _LoadingRows extends StatelessWidget {
  const _LoadingRows();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 18),
      child: LinearProgressIndicator(minHeight: 2),
    );
  }
}
