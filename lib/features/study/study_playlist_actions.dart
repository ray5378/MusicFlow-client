import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/library/widgets/playlist_manage_dialogs.dart';
import 'package:musicflow_client/features/study/pages/study_playlist_page.dart';
import 'package:musicflow_client/features/study/study_folder_tree.dart';
import 'package:musicflow_client/features/study/widgets/study_playlist_sheets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

/// 学习歌单的共用动作（新建 / 改名 / 移动 / 删除 / 播放 / 进入详情）。
///
/// 首页的「学习歌单」tab 与「进入文件夹」页都要用同一批动作，抽到这里避免两份
/// 实现慢慢走偏。所有函数都自行刷新 provider，调用方不需要再手动 invalidate。

/// 学习歌单相关数据的统一失效点（歌单列表 + 文件夹路径列表）。
void invalidateStudyPlaylists(WidgetRef ref) {
  ref.invalidate(studyPlaylistsProvider);
  ref.invalidate(studyPlaylistFoldersProvider);
}

/// Toast 是应用级浮层，不需要 context（也就不受「await 之后不能用 context」限制）。
void _toast(
  String message, {
  MusicFlowMessageKind kind = MusicFlowMessageKind.success,
}) {
  ToastNotifier.show(message, kind: kind);
}

/// 新建文件夹；[parent] 为空表示建在根目录，否则建在该文件夹**里面**。
Future<void> createStudyFolder(
  BuildContext context,
  WidgetRef ref, {
  String parent = '',
}) async {
  final loc = AppLocalizations.of(context);
  final name = await showStudyPlaylistNameSheet(
    context: context,
    title: loc.study_new_folder,
    confirmText: loc.common_save,
    fieldLabel: loc.study_new_folder,
    hintText: loc.study_folder_name_hint,
  );
  if (name == null || !context.mounted) return;
  try {
    await ref.read(studyApiProvider).createPlaylistFolder(name, parent: parent);
    invalidateStudyPlaylists(ref);
    _toast(loc.study_folder_created(name));
  } catch (_) {
    _toast(
      loc.study_folder_create_failed,
      kind: MusicFlowMessageKind.error,
    );
  }
}

/// 新建学习歌单；[folder] 为空表示建在根目录，否则建在该文件夹**里面**。
Future<void> createStudyPlaylist(
  BuildContext context,
  WidgetRef ref, {
  String folder = '',
}) async {
  final loc = AppLocalizations.of(context);
  final name = await showStudyPlaylistNameSheet(
    context: context,
    title: loc.study_playlist_create,
    confirmText: loc.common_save,
  );
  if (name == null || !context.mounted) return;
  try {
    await ref.read(studyApiProvider).createPlaylist(name, folder: folder);
    invalidateStudyPlaylists(ref);
    _toast(loc.study_playlist_created(name));
  } on StudyPlaylistNameConflict {
    _toast(
      loc.study_playlist_name_exists,
      kind: MusicFlowMessageKind.error,
    );
  } catch (_) {
    _toast(
      loc.study_playlist_create_failed,
      kind: MusicFlowMessageKind.error,
    );
  }
}

/// 文件夹长按菜单：重命名 / 删除。
Future<void> showStudyFolderActions(
  BuildContext context,
  WidgetRef ref,
  String folder,
) async {
  final action = await showStudyFolderActionsSheet(
    context: context,
    folder: folder,
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case StudyFolderAction.rename:
      await _renameFolder(context, ref, folder);
    case StudyFolderAction.delete:
      await _deleteFolder(context, ref, folder);
  }
}

/// 重命名文件夹。
///
/// 只编辑**最后一段名称**（输入框里预填 `高数` 而不是 `课程/高数`），由服务端
/// 拼回父路径并**连子目录一起改**（走 `POST /playlist-folders/rename`）。
Future<void> _renameFolder(
  BuildContext context,
  WidgetRef ref,
  String folder,
) async {
  final loc = AppLocalizations.of(context);
  final current = studyFolderLabel(folder);
  final name = await showStudyPlaylistNameSheet(
    context: context,
    title: loc.study_folder_rename_title,
    confirmText: loc.common_save,
    initialName: current,
    fieldLabel: loc.study_new_folder,
    hintText: loc.study_folder_name_hint,
  );
  if (name == null || !context.mounted || name == current) return;
  try {
    await ref.read(studyApiProvider).renamePlaylistFolder(folder, name);
    invalidateStudyPlaylists(ref);
    _toast(loc.study_folder_renamed(name));
  } catch (_) {
    _toast(
      loc.study_folder_update_failed,
      kind: MusicFlowMessageKind.error,
    );
  }
}

/// 删除文件夹（歌单回到上一级，不删歌单本身）。
Future<void> _deleteFolder(
  BuildContext context,
  WidgetRef ref,
  String folder,
) async {
  final loc = AppLocalizations.of(context);
  final label = studyFolderLabel(folder);
  final confirmed = await showDeleteFolderConfirmSheet(
    context: context,
    folder: label,
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await ref.read(studyApiProvider).deletePlaylistFolder(folder);
    invalidateStudyPlaylists(ref);
    _toast(loc.study_folder_deleted(label));
  } catch (_) {
    _toast(
      loc.study_folder_delete_failed,
      kind: MusicFlowMessageKind.error,
    );
  }
}

/// 歌单长按菜单：重命名 / 移动到文件夹 / 移出文件夹 / 删除。
Future<void> showStudyPlaylistActions(
  BuildContext context,
  WidgetRef ref,
  StudyPlaylist playlist,
) async {
  final action = await showStudyPlaylistActionsSheet(
    context: context,
    playlist: playlist,
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case StudyPlaylistAction.rename:
      await _renamePlaylist(context, ref, playlist);
    case StudyPlaylistAction.move:
      await _movePlaylist(context, ref, playlist);
    case StudyPlaylistAction.removeFromFolder:
      await _applyPlaylistFolder(context, ref, playlist, '');
    case StudyPlaylistAction.delete:
      await _deletePlaylist(context, ref, playlist);
  }
}

Future<void> _renamePlaylist(
  BuildContext context,
  WidgetRef ref,
  StudyPlaylist playlist,
) async {
  final loc = AppLocalizations.of(context);
  final name = await showStudyPlaylistNameSheet(
    context: context,
    title: loc.study_playlist_rename_title,
    confirmText: loc.common_save,
    initialName: playlist.name,
  );
  if (name == null || !context.mounted || name == playlist.name) return;
  try {
    await ref.read(studyApiProvider).renamePlaylist(playlist.id, name);
    invalidateStudyPlaylists(ref);
    ref.invalidate(studyPlaylistTracksProvider(playlist.id));
    _toast(loc.study_playlist_renamed(name));
  } on StudyPlaylistNameConflict {
    _toast(
      loc.study_playlist_name_exists,
      kind: MusicFlowMessageKind.error,
    );
  } catch (_) {
    _toast(
      loc.study_playlist_update_failed,
      kind: MusicFlowMessageKind.error,
    );
  }
}

/// 移动到文件夹：可选择已有文件夹、根目录或现场新建文件夹。
Future<void> _movePlaylist(
  BuildContext context,
  WidgetRef ref,
  StudyPlaylist playlist,
) async {
  final loc = AppLocalizations.of(context);
  final folders = await ref
      .read(studyPlaylistFoldersProvider.future)
      .catchError((Object _) => const <String>[]);
  if (!context.mounted) return;
  final pick = await showStudyFolderPickerSheet(
    context: context,
    title: loc.study_move_to_folder_title(playlist.name),
    folders: folders,
    currentFolder: playlist.folder,
  );
  if (pick == null || !context.mounted) return;
  if (pick.createNew) {
    final name = await showStudyPlaylistNameSheet(
      context: context,
      title: loc.study_new_folder,
      confirmText: loc.common_save,
      fieldLabel: loc.study_new_folder,
      hintText: loc.study_folder_name_hint,
    );
    if (name == null || !context.mounted) return;
    await _applyPlaylistFolder(context, ref, playlist, name, createFolder: true);
    return;
  }
  await _applyPlaylistFolder(context, ref, playlist, pick.folder);
}

Future<void> _applyPlaylistFolder(
  BuildContext context,
  WidgetRef ref,
  StudyPlaylist playlist,
  String folder, {
  bool createFolder = false,
}) async {
  final loc = AppLocalizations.of(context);
  try {
    final api = ref.read(studyApiProvider);
    if (createFolder) await api.createPlaylistFolder(folder);
    await api.movePlaylist(playlist.id, folder);
    invalidateStudyPlaylists(ref);
    _toast(
      folder.isEmpty
          ? loc.study_removed_from_folder
          : loc.study_moved_to_folder(folder),
    );
  } catch (_) {
    _toast(
      loc.study_playlist_update_failed,
      kind: MusicFlowMessageKind.error,
    );
  }
}

Future<void> _deletePlaylist(
  BuildContext context,
  WidgetRef ref,
  StudyPlaylist playlist,
) async {
  final loc = AppLocalizations.of(context);
  final confirmed = await showDeletePlaylistConfirmDialog(
    context: context,
    playlistName: playlist.name,
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await ref.read(studyApiProvider).deletePlaylist(playlist.id);
    invalidateStudyPlaylists(ref);
    ref.invalidate(studyPlaylistTracksProvider(playlist.id));
    _toast(loc.study_playlist_deleted(playlist.name));
  } catch (_) {
    _toast(
      loc.study_playlist_delete_failed,
      kind: MusicFlowMessageKind.error,
    );
  }
}

/// 播放整个学习歌单（投屏 / 直投时走统一流转入口，手机本机直接起播）。
Future<void> playStudyPlaylist(
  BuildContext context,
  WidgetRef ref,
  StudyPlaylist playlist,
) async {
  final loc = AppLocalizations.of(context);
  try {
    final songs = await ref.read(
      studyPlaylistTracksProvider(playlist.id).future,
    );
    if (!context.mounted) return;
    if (songs.isEmpty) {
      _toast(
        loc.study_empty_playlist_tracks,
        kind: MusicFlowMessageKind.error,
      );
      return;
    }
    final casting =
        ref.read(castPeerControllerProvider).activePeer != null ||
        ref.read(dlnaCastProvider).isCasting;
    if (casting) {
      await playEffectiveQueue(ref, songs, startIndex: 0);
      return;
    }
    await ref.read(playerProvider.notifier).playQueue(songs, startIndex: 0);
  } catch (_) {
    if (!context.mounted) return;
    _toast(loc.study_play_failed, kind: MusicFlowMessageKind.error);
  }
}

/// 进入学习歌单详情（曲目列表 / 管理）。
void openStudyPlaylist(BuildContext context, StudyPlaylist playlist) {
  unawaited(
    Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(
        context: context,
        builder: (_) =>
            StudyPlaylistPage(playlistId: playlist.id, title: playlist.name),
      ),
    ),
  );
}
