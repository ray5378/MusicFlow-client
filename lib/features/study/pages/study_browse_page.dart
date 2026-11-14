import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/study/widgets/study_playlist_sheets.dart';
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

  /// 多选（仅音频文件参与；目录不可选）。
  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};
  bool _addingToPlaylist = false;

  Future<void> _refresh() async {
    ref.invalidate(
      studyDirProvider((sourceId: widget.sourceId, path: widget.path)),
    );
    await ref
        .read(
          studyDirProvider((
            sourceId: widget.sourceId,
            path: widget.path,
          )).future,
        )
        .catchError((Object _) => <StudyDirEntry>[]);
  }

  List<StudyDirEntry> _sortedFiles(List<StudyDirEntry> entries) {
    final files =
        entries.where((e) => !e.isDir && isStudyAudioFile(e.name)).toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
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
      final songs = await ref
          .read(studyApiProvider)
          .resolveBatch(
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

  /// 子目录长按：把该目录（递归）里的学习内容加入学习歌单。
  Future<void> _showDirActions(StudyDirEntry entry) async {
    if (_selectionMode || _addingToPlaylist || _resolvingAll) return;
    final action = await showStudyDirActionsSheet(
      context: context,
      name: entry.name,
    );
    if (action != StudyDirAction.addToPlaylist || !mounted) return;
    await addStudyDirToPlaylist(
      context: context,
      ref: ref,
      sourceId: widget.sourceId,
      path: entry.relPath,
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
    final currentSongId = ref.watch(
      playerProvider.select((s) => s.currentSong?.id),
    );
    final currentEntries = async.valueOrNull;
    final currentFiles = currentEntries == null
        ? const <StudyDirEntry>[]
        : _sortedFiles(currentEntries);
    final allSelected =
        currentFiles.isNotEmpty &&
        currentFiles.every((file) => _selectedPaths.contains(file.relPath));

    final topBar = _selectionMode
        ? MusicFlowTopBar(
            title: loc.library_selected_count('${_selectedPaths.length}'),
            leading: MusicFlowIconButton(
              icon: AppIcons.close,
              label: loc.library_exit_song_management,
              onPressed: _addingToPlaylist ? null : _exitSelectionMode,
            ),
            actions: <Widget>[
              MusicFlowIconButton(
                icon: allSelected ? AppIcons.clearAll : AppIcons.selectAll,
                label: allSelected
                    ? loc.library_deselect_all
                    : loc.library_select_all,
                selected: allSelected,
                onPressed: currentFiles.isEmpty || _addingToPlaylist
                    ? null
                    : () => _toggleSelectAll(currentFiles),
              ),
            ],
          )
        : MusicFlowTopBar.back(
            context: context,
            title: widget.path.isEmpty
                ? widget.sourceName
                : widget.path.split('/').last,
            subtitle: widget.path.isEmpty ? null : widget.path,
            actions: <Widget>[
              MusicFlowIconButton(
                icon: AppIcons.playlistAdd,
                label: loc.study_add_to_playlist,
                onPressed: currentFiles.isEmpty || _addingToPlaylist
                    ? null
                    : () => _enterSelectionMode(),
              ),
              MusicFlowIconButton(
                icon: AppIcons.play,
                label: loc.study_play_all,
                onPressed: async.valueOrNull == null
                    ? null
                    : () => unawaited(
                        _playDirectory(entries: async.valueOrNull!),
                      ),
              ),
            ],
          );

    return PopScope<void>(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode && !_addingToPlaylist) {
          _exitSelectionMode();
        }
      },
      child: MusicFlowScaffold(
        topBar: topBar,
        bottomBar: _selectionMode
            ? _BrowseSelectionBar(
                selectedCount: _selectedPaths.length,
                busy: _addingToPlaylist,
                onAdd: _selectedPaths.isEmpty || _addingToPlaylist
                    ? null
                    : () => unawaited(_addSelectionToPlaylist(currentFiles)),
              )
            : null,
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
                  (a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()),
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
                      onTap: _selectionMode
                          ? null
                          : () => _openDirectory(dirs[index]),
                      onLongPress: _selectionMode
                          ? null
                          : () => _showDirActions(dirs[index]),
                    );
                  }
                  final file = files[index - dirs.length];
                  return _FileRow(
                    entry: file,
                    playing:
                        file.songId != null && file.songId == currentSongId,
                    busy: _resolvingPath == file.relPath,
                    selectionMode: _selectionMode,
                    selected: _selectedPaths.contains(file.relPath),
                    onLongPress: () => _enterSelectionMode(path: file.relPath),
                    onToggleSelected: () => _togglePathSelection(file.relPath),
                    onTap: () {
                      if (_selectionMode) {
                        _togglePathSelection(file.relPath);
                        return;
                      }
                      unawaited(
                        _playDirectory(
                          entries: entries,
                          targetPath: file.relPath,
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _enterSelectionMode({String? path}) {
    if (_addingToPlaylist) return;
    setState(() {
      _selectionMode = true;
      if (path != null) {
        _selectedPaths.add(path);
      }
    });
  }

  void _exitSelectionMode() {
    if (_addingToPlaylist) return;
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  void _togglePathSelection(String path) {
    if (_addingToPlaylist) return;
    setState(() {
      if (!_selectedPaths.add(path)) {
        _selectedPaths.remove(path);
      }
    });
  }

  void _toggleSelectAll(List<StudyDirEntry> files) {
    if (_addingToPlaylist) return;
    setState(() {
      final allSelected = files.every(
        (file) => _selectedPaths.contains(file.relPath),
      );
      _selectedPaths.clear();
      if (!allSelected) {
        _selectedPaths.addAll(files.map((file) => file.relPath));
      }
    });
  }

  /// 选中的文件先补入库（resolve-batch）拿到 songId，再选择/新建歌单加入。
  Future<void> _addSelectionToPlaylist(List<StudyDirEntry> files) async {
    if (_selectedPaths.isEmpty || _addingToPlaylist) return;
    final loc = AppLocalizations.of(context);
    final selected = <StudyDirEntry>[
      for (final file in files)
        if (_selectedPaths.contains(file.relPath)) file,
    ];
    if (selected.isEmpty) return;
    setState(() => _addingToPlaylist = true);
    try {
      final api = ref.read(studyApiProvider);
      final unresolved = <String>[
        for (final file in selected)
          if (file.songId == null) file.relPath,
      ];
      var resolvedIds = const <String, String>{};
      if (unresolved.isNotEmpty) {
        final resolved = await api.resolveBatchEntries(
          sourceId: widget.sourceId,
          paths: unresolved,
        );
        resolvedIds = <String, String>{
          for (final entry in resolved) entry.path: entry.song.id,
        };
      }
      final songIds = <String>[];
      for (final file in selected) {
        final id = file.songId ?? resolvedIds[file.relPath];
        if (id != null && id.isNotEmpty) {
          songIds.add(id);
        }
      }
      if (!mounted) return;
      if (songIds.isEmpty) {
        ToastNotifier.show(
          loc.study_file_resolve_failed,
          kind: MusicFlowMessageKind.error,
        );
        return;
      }
      final ok = await addStudySongsToPlaylist(
        context: context,
        ref: ref,
        songIds: songIds,
      );
      if (!ok || !mounted) return;
      ref.invalidate(studyDirProvider);
      setState(() {
        _selectionMode = false;
        _selectedPaths.clear();
      });
    } catch (_) {
      if (!mounted) return;
      ToastNotifier.show(
        loc.study_file_resolve_failed,
        kind: MusicFlowMessageKind.error,
      );
    } finally {
      if (mounted) {
        setState(() => _addingToPlaylist = false);
      }
    }
  }
}

class _BrowseSelectionBar extends StatelessWidget {
  const _BrowseSelectionBar({
    required this.selectedCount,
    required this.busy,
    required this.onAdd,
  });

  final int selectedCount;
  final bool busy;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final count = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          loc.study_add_to_playlist,
          style: context.musicFlowTypography.title,
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
        Text(
          loc.library_selected_count('$selectedCount'),
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.muted,
          ),
        ),
      ],
    );

    final addButton = MusicFlowButton.primary(
      label: loc.study_add_to_playlist,
      leadingIcon: AppIcons.playlistAdd,
      expand: true,
      onPressed: busy ? null : onAdd,
    );

    return MusicFlowSurface(
      level: MusicFlowSurfaceLevel.surface,
      borderRadius: BorderRadius.zero,
      borderColor: context.musicFlowColors.divider,
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stack =
              constraints.maxWidth < 380 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                count,
                SizedBox(height: context.musicFlowSpacing.xs),
                addButton,
              ],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(child: count),
              SizedBox(width: context.musicFlowSpacing.sm),
              MusicFlowButton.primary(
                label: loc.study_add_to_playlist,
                leadingIcon: AppIcons.playlistAdd,
                onPressed: busy ? null : onAdd,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DirRow extends StatelessWidget {
  const _DirRow({required this.entry, required this.onTap, this.onLongPress});

  final StudyDirEntry entry;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return MusicFlowPressable(
      onPressed: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(
              AppIcons.folder,
              size: 22,
              color: context.musicFlowColors.accent,
            ),
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
    required this.selectionMode,
    required this.selected,
    required this.onLongPress,
    required this.onToggleSelected,
  });

  final StudyDirEntry entry;
  final bool playing;
  final bool busy;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelected;

  static String _durationLabel(StudyDirEntry entry) {
    final total = entry.durationSec ?? 0;
    if (total <= 0) return '';
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final duration = _durationLabel(entry);
    final progress = entry.progress.clamp(0.0, 1.0).toDouble();
    return MusicFlowPressable(
      onPressed: busy
          ? null
          : selectionMode
          ? onToggleSelected
          : onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      selected: selectionMode ? selected : null,
      child: AnimatedContainer(
        duration: context.musicFlowMotion.resolve(
          context,
          context.musicFlowMotion.feedback,
        ),
        curve: context.musicFlowMotion.easeOut,
        decoration: BoxDecoration(
          color: selectionMode && selected
              ? colors.accent.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: context.musicFlowRadii.control,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 30,
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : MusicFlowIconButton(
                      icon: playing ? AppIcons.equalizer : AppIcons.play,
                      label: loc.study_icon_play_content,
                      selected: playing,
                      onPressed: selectionMode ? onToggleSelected : onTap,
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
            if (selectionMode) ...<Widget>[
              SizedBox(width: context.musicFlowSpacing.xs),
              MusicFlowIconButton(
                icon: selected ? AppIcons.checkCircle : AppIcons.radio,
                label: selected
                    ? loc.widgets_song_deselect(entry.name)
                    : loc.widgets_song_select(entry.name),
                selected: selected,
                onPressed: onToggleSelected,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
