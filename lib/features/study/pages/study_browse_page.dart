import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

/// 学习目录浏览页：文件夹下钻 + 音频点播 / 播放全部。
///
/// 点某一章或「播放全部」都会把**当前目录的音频**一次性入库（resolve-batch），
/// 以整目录作为播放队列交给统一播放入口 —— 因而流转到其它播放端后，
/// 队列里同样能上下曲/跳播。
class StudyBrowsePage extends ConsumerStatefulWidget {
  const StudyBrowsePage({
    super.key,
    required this.sourceId,
    required this.sourceName,
    required this.path,
  });

  final String sourceId;
  final String sourceName;
  final String path;

  @override
  ConsumerState<StudyBrowsePage> createState() => _StudyBrowsePageState();
}

class _StudyBrowsePageState extends ConsumerState<StudyBrowsePage> {
  /// 正在解析入库的目标文件（用于整页加载提示与防重复点击）。
  String? _resolvingPath;
  bool _resolvingAll = false;

  static const Set<String> _audioExtensions = <String>{
    'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus', 'ape', 'wma', 'aiff', 'aif',
  };

  static bool _isAudioFile(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return false;
    return _audioExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  Future<void> _refresh() async {
    ref.invalidate(
      studyDirProvider((sourceId: widget.sourceId, path: widget.path)),
    );
    await ref
        .read(
          studyDirProvider((sourceId: widget.sourceId, path: widget.path))
              .future,
        )
        .catchError((Object _) => <StudyDirEntry>[]);
  }

  List<StudyDirEntry> _sortedFiles(List<StudyDirEntry> entries) {
    final files = entries.where((e) => !e.isDir && _isAudioFile(e.name)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return files;
  }

  /// 把当前目录的全部音频入库并按 [targetPath] 起播。
  Future<void> _playDirectory({
    required List<StudyDirEntry> entries,
    String? targetPath,
  }) async {
    final files = _sortedFiles(entries);
    if (files.isEmpty) return;
    if (_resolvingAll || _resolvingPath != null) return;
    setState(() {
      if (targetPath == null) {
        _resolvingAll = true;
      } else {
        _resolvingPath = targetPath;
      }
    });
    try {
      final songs = await ref.read(studyApiProvider).resolveBatch(
            sourceId: widget.sourceId,
            paths: <String>[for (final file in files) file.relPath],
          );
      if (!mounted || songs.isEmpty) return;
      var index = 0;
      if (targetPath != null) {
        // 批量结果按入参顺序返回，失败项会被跳过，因此按 relPath 定位更稳妥。
        final target = files.indexWhere((f) => f.relPath == targetPath);
        if (target >= 0 && target < songs.length) index = target;
      }
      await playEffectiveQueue(ref, songs, startIndex: index);
      ref.invalidate(studyDirProvider);
    } catch (_) {
      if (!mounted) return;
      showMusicFlowToast(
        context,
        AppLocalizations.of(context).study_play_failed,
        kind: MusicFlowMessageKind.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _resolvingAll = false;
          _resolvingPath = null;
        });
      }
    }
  }

  void _openDirectory(StudyDirEntry entry) {
    unawaited(
      Navigator.of(context).push<void>(
        MusicFlowPageRoute<void>(
          context: context,
          builder: (_) => StudyBrowsePage(
            sourceId: widget.sourceId,
            sourceName: widget.sourceName,
            path: entry.relPath,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 学习音频播放(含流转)时按 10s 心跳上报进度。
    ref.read(studyProgressReporterProvider);
    final loc = AppLocalizations.of(context);
    final async = ref.watch(
      studyDirProvider((sourceId: widget.sourceId, path: widget.path)),
    );
    final currentSongId =
        ref.watch(playerProvider.select((s) => s.currentSong?.id));

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(
        context: context,
        title: widget.path.isEmpty
            ? widget.sourceName
            : widget.path.split('/').last,
        subtitle: widget.path.isEmpty ? null : widget.path,
        actions: <Widget>[
          IconButton(
            tooltip: loc.study_play_all,
            icon: const Icon(AppIcons.play),
            onPressed: async.valueOrNull == null
                ? null
                : () => unawaited(
                      _playDirectory(entries: async.valueOrNull!),
                    ),
          ),
        ],
      ),
      body: MusicFlowRefreshView(
        onRefresh: _refresh,
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: MusicFlowButton.secondary(
              label: loc.widgets_retry,
              onPressed: () => ref.invalidate(studyDirProvider),
            ),
          ),
          data: (entries) {
            final dirs = entries.where((e) => e.isDir).toList()
              ..sort(
                (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
              );
            final files = _sortedFiles(entries);
            if (dirs.isEmpty && files.isEmpty) {
              return Center(
                child: Text(
                  loc.study_empty_dir,
                  style: context.musicFlowTypography.metadata.copyWith(
                    color: context.musicFlowColors.muted,
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 32),
              itemCount: dirs.length + files.length,
              itemBuilder: (context, index) {
                if (index < dirs.length) {
                  return _DirRow(
                    entry: dirs[index],
                    onTap: () => _openDirectory(dirs[index]),
                  );
                }
                final file = files[index - dirs.length];
                return _FileRow(
                  entry: file,
                  playing: file.songId != null && file.songId == currentSongId,
                  busy: _resolvingPath == file.relPath,
                  onTap: () => unawaited(
                    _playDirectory(
                      entries: entries,
                      targetPath: file.relPath,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _DirRow extends StatelessWidget {
  const _DirRow({required this.entry, required this.onTap});

  final StudyDirEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MusicFlowPressable(
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(AppIcons.folder, size: 22, color: context.musicFlowColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.musicFlowTypography.body,
              ),
            ),
            Icon(
              AppIcons.chevronRight,
              size: 18,
              color: context.musicFlowColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.entry,
    required this.playing,
    required this.busy,
    required this.onTap,
  });

  final StudyDirEntry entry;
  final bool playing;
  final bool busy;
  final VoidCallback onTap;

  static String _durationLabel(StudyDirEntry entry) {
    final total = entry.durationSec ?? 0;
    if (total <= 0) return '';
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final duration = _durationLabel(entry);
    final progress = entry.progress.clamp(0.0, 1.0).toDouble();
    return MusicFlowPressable(
      onPressed: busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 26,
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      entry.finished
                          ? AppIcons.checkCircle
                          : AppIcons.fileText,
                      size: 20,
                      color: playing ? colors.accent : colors.muted,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.body.copyWith(
                      color: playing ? colors.accent : colors.ink,
                    ),
                  ),
                  if (progress > 0 && !entry.finished)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 2,
                          backgroundColor: colors.muted.withValues(alpha: 0.2),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            colors.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (duration.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  duration,
                  style: context.musicFlowTypography.metadata.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
