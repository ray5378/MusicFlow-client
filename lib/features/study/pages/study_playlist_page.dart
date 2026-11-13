import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/library/widgets/playlist_detail_blocks.dart';
import 'package:musicflow_client/features/library/widgets/playlist_manage_dialogs.dart';
import 'package:musicflow_client/features/study/widgets/study_playlist_sheets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

/// 学习歌单详情页：与音乐歌单一致的行交互（长按多选 / 移出歌单），
/// 播放同样走统一入口（本机 / 投屏 / 直投三链路）。
class StudyPlaylistPage extends ConsumerStatefulWidget {
  const StudyPlaylistPage({
    super.key,
    required this.playlistId,
    required this.title,
  });

  final String playlistId;
  final String title;

  @override
  ConsumerState<StudyPlaylistPage> createState() => _StudyPlaylistPageState();
}

class _StudyPlaylistPageState extends ConsumerState<StudyPlaylistPage> {
  late String _title = widget.title;

  bool _selectionMode = false;
  final Set<String> _selectedSongIds = <String>{};
  bool _busy = false;

  Future<void> _refresh() async {
    ref.invalidate(studyPlaylistTracksProvider(widget.playlistId));
    ref.invalidate(studyPlaylistsProvider);
    await ref
        .read(studyPlaylistTracksProvider(widget.playlistId).future)
        .catchError((Object _) => <Song>[]);
  }

  void _enterSelectionMode(String songId) {
    if (_busy) return;
    setState(() {
      _selectionMode = true;
      _selectedSongIds.add(songId);
    });
  }

  void _exitSelectionMode() {
    if (_busy) return;
    setState(() {
      _selectionMode = false;
      _selectedSongIds.clear();
    });
  }

  void _toggleSelection(String songId) {
    if (_busy) return;
    setState(() {
      if (!_selectedSongIds.add(songId)) {
        _selectedSongIds.remove(songId);
      }
    });
  }

  void _toggleSelectAll(List<Song> songs) {
    if (_busy) return;
    setState(() {
      final allSelected =
          songs.isNotEmpty &&
          songs.every((song) => _selectedSongIds.contains(song.id));
      _selectedSongIds.clear();
      if (!allSelected) {
        _selectedSongIds.addAll(songs.map((song) => song.id));
      }
    });
  }

  /// 移出前二次确认，与音乐歌单移除一致。
  Future<void> _confirmBatchRemoval() async {
    final loc = AppLocalizations.of(context);
    if (_selectedSongIds.isEmpty || _busy) return;
    final count = _selectedSongIds.length;
    final confirmed = await showMusicFlowBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.library_remove_songs,
        subtitle: loc.library_remove_songs_desc,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              loc.library_remove_songs_confirm(_title, '$count'),
              style: sheetContext.musicFlowTypography.body.copyWith(
                color: sheetContext.musicFlowColors.muted,
              ),
            ),
            SizedBox(height: sheetContext.musicFlowSpacing.lg),
            Row(
              children: <Widget>[
                Expanded(
                  child: MusicFlowButton.secondary(
                    label: loc.settings_cancel,
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                  ),
                ),
                SizedBox(width: sheetContext.musicFlowSpacing.sm),
                Expanded(
                  child: MusicFlowButton.destructive(
                    label: loc.common_remove,
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _removeSelected();
  }

  Future<void> _removeSelected() async {
    final loc = AppLocalizations.of(context);
    if (_selectedSongIds.isEmpty || _busy) return;
    final ids = _selectedSongIds.toList(growable: false);
    final count = ids.length;
    setState(() => _busy = true);
    try {
      await ref.read(studyApiProvider).removeTracks(widget.playlistId, ids);
      ref.invalidate(studyPlaylistTracksProvider(widget.playlistId));
      ref.invalidate(studyPlaylistsProvider);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _selectionMode = false;
        _selectedSongIds.clear();
      });
      ToastNotifier.show(
        loc.study_removed_count(count),
        kind: MusicFlowMessageKind.success,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ToastNotifier.show(
        loc.study_remove_failed,
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  Future<void> _showPlaylistActions() async {
    final songCount =
        ref
            .read(studyPlaylistTracksProvider(widget.playlistId))
            .valueOrNull
            ?.length ??
        0;
    final action = await showStudyPlaylistActionsSheet(
      context: context,
      playlist: StudyPlaylist(
        id: widget.playlistId,
        name: _title,
        songCount: songCount,
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case StudyPlaylistAction.rename:
        await _renamePlaylist();
      case StudyPlaylistAction.move:
        await _moveToFolder();
      case StudyPlaylistAction.removeFromFolder:
        await _removeFromFolder();
      case StudyPlaylistAction.delete:
        await _deletePlaylist();
    }
  }

  Future<void> _moveToFolder() async {
    final loc = AppLocalizations.of(context);
    final folders = await ref
        .read(studyPlaylistFoldersProvider.future)
        .catchError((Object _) => const <String>[]);
    if (!mounted) return;
    final pick = await showStudyFolderPickerSheet(
      context: context,
      title: loc.study_move_to_folder_title(_title),
      folders: folders,
      currentFolder: '',
    );
    if (pick == null || !mounted) return;
    try {
      final api = ref.read(studyApiProvider);
      var folder = pick.folder;
      if (pick.createNew) {
        final name = await showStudyPlaylistNameSheet(
          context: context,
          title: loc.study_new_folder,
          confirmText: loc.common_save,
          fieldLabel: loc.study_new_folder,
        );
        if (name == null || !mounted) return;
        await api.createPlaylistFolder(name);
        folder = name;
      }
      await api.movePlaylist(widget.playlistId, folder);
      ref.invalidate(studyPlaylistsProvider);
      ToastNotifier.show(
        loc.study_moved_to_folder(folder),
        kind: MusicFlowMessageKind.success,
      );
    } catch (_) {
      ToastNotifier.show(
        loc.study_playlist_update_failed,
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  Future<void> _removeFromFolder() async {
    final loc = AppLocalizations.of(context);
    try {
      await ref.read(studyApiProvider).movePlaylist(widget.playlistId, '');
      ref.invalidate(studyPlaylistsProvider);
      ToastNotifier.show(
        loc.study_removed_from_folder,
        kind: MusicFlowMessageKind.success,
      );
    } catch (_) {
      ToastNotifier.show(
        loc.study_playlist_update_failed,
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  Future<void> _renamePlaylist() async {
    final loc = AppLocalizations.of(context);
    final name = await showStudyPlaylistNameSheet(
      context: context,
      title: loc.study_playlist_rename_title,
      confirmText: loc.common_save,
      initialName: _title,
    );
    if (name == null || !mounted || name == _title) return;
    try {
      await ref.read(studyApiProvider).renamePlaylist(widget.playlistId, name);
      ref.invalidate(studyPlaylistsProvider);
      if (!mounted) return;
      setState(() => _title = name);
      ToastNotifier.show(
        loc.study_playlist_renamed(name),
        kind: MusicFlowMessageKind.success,
      );
    } catch (_) {
      ToastNotifier.show(
        loc.study_playlist_update_failed,
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  Future<void> _deletePlaylist() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDeletePlaylistConfirmDialog(
      context: context,
      playlistName: _title,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(studyApiProvider).deletePlaylist(widget.playlistId);
      ref.invalidate(studyPlaylistsProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ToastNotifier.show(
        loc.study_playlist_deleted(_title),
        kind: MusicFlowMessageKind.success,
      );
    } catch (_) {
      ToastNotifier.show(
        loc.study_playlist_delete_failed,
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 学习音频播放(含流转)时按 10s 心跳上报进度。
    ref.read(studyProgressReporterProvider);
    final loc = AppLocalizations.of(context);
    final async = ref.watch(studyPlaylistTracksProvider(widget.playlistId));
    final currentSongId = ref.watch(
      playerProvider.select((s) => s.currentSong?.id),
    );
    final songs = async.valueOrNull ?? const <Song>[];
    final allSelected =
        songs.isNotEmpty &&
        songs.every((song) => _selectedSongIds.contains(song.id));

    final topBar = _selectionMode
        ? MusicFlowTopBar(
            title: loc.library_selected_count('${_selectedSongIds.length}'),
            leading: MusicFlowIconButton(
              icon: AppIcons.close,
              label: loc.library_exit_song_management,
              onPressed: _busy ? null : _exitSelectionMode,
            ),
            actions: <Widget>[
              MusicFlowIconButton(
                icon: allSelected ? AppIcons.clearAll : AppIcons.selectAll,
                label: allSelected
                    ? loc.library_deselect_all
                    : loc.library_select_all,
                selected: allSelected,
                onPressed: songs.isEmpty || _busy
                    ? null
                    : () => _toggleSelectAll(songs),
              ),
            ],
          )
        : MusicFlowTopBar.back(
            context: context,
            title: _title,
            actions: <Widget>[
              MusicFlowIconButton(
                icon: AppIcons.more,
                label: loc.study_playlist_actions,
                onPressed: _busy
                    ? null
                    : () => unawaited(_showPlaylistActions()),
              ),
            ],
          );

    return PopScope<void>(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode && !_busy) {
          _exitSelectionMode();
        }
      },
      child: MusicFlowScaffold(
        topBar: topBar,
        bottomBar: _selectionMode
            ? PlaylistSelectionBar(
                selectedCount: _selectedSongIds.length,
                removing: _busy,
                onRemove: _selectedSongIds.isEmpty
                    ? null
                    : () => unawaited(_confirmBatchRemoval()),
              )
            : null,
        body: MusicFlowRefreshView(
          onRefresh: _refresh,
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: MusicFlowButton.secondary(
                label: loc.widgets_retry,
                onPressed: () => ref.invalidate(
                  studyPlaylistTracksProvider(widget.playlistId),
                ),
              ),
            ),
            data: (songs) {
              if (songs.isEmpty) {
                return Center(
                  child: Text(
                    loc.study_empty_playlist_tracks,
                    style: context.musicFlowTypography.metadata.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 32),
                itemCount: songs.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              loc.study_playlist_song_count(songs.length),
                              style: context.musicFlowTypography.metadata
                                  .copyWith(
                                    color: context.musicFlowColors.muted,
                                  ),
                            ),
                          ),
                          MusicFlowButton.primary(
                            label: loc.library_play_all,
                            leadingIcon: AppIcons.play,
                            onPressed: () =>
                                unawaited(playEffectiveQueue(ref, songs)),
                          ),
                        ],
                      ),
                    );
                  }
                  final song = songs[index - 1];
                  return MusicFlowSongRow(
                    song: song,
                    index: index,
                    isCurrent: song.id == currentSongId,
                    selectionMode: _selectionMode,
                    selected: _selectedSongIds.contains(song.id),
                    onToggleSelected: () => _toggleSelection(song.id),
                    onLongPress: () => _enterSelectionMode(song.id),
                    onPressed: () {
                      if (_selectionMode) {
                        _toggleSelection(song.id);
                        return;
                      }
                      unawaited(
                        playEffectiveQueue(ref, songs, startIndex: index - 1),
                      );
                    },
                    onMorePressed: null,
                    showMoreButton: false,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
