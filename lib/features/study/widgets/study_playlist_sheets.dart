import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

/// 学习歌单弹窗集合：名称输入 / 加入歌单选择器 / 歌单操作菜单。

/// 名称输入（新建与重命名共用），返回去掉首尾空白后的名称；取消返回 null。
Future<String?> showStudyPlaylistNameSheet({
  required BuildContext context,
  required String title,
  required String confirmText,
  String initialName = '',
  String? fieldLabel,
  String? hintText,
}) {
  return showMusicFlowBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (_) => _StudyPlaylistNameSheet(
      title: title,
      confirmText: confirmText,
      initialName: initialName,
      fieldLabel: fieldLabel,
      hintText: hintText,
    ),
  );
}

class _StudyPlaylistNameSheet extends StatefulWidget {
  const _StudyPlaylistNameSheet({
    required this.title,
    required this.confirmText,
    required this.initialName,
    this.fieldLabel,
    this.hintText,
  });

  final String title;
  final String confirmText;
  final String initialName;
  final String? fieldLabel;
  final String? hintText;

  @override
  State<_StudyPlaylistNameSheet> createState() =>
      _StudyPlaylistNameSheetState();
}

class _StudyPlaylistNameSheetState extends State<_StudyPlaylistNameSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_nameController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final motion = context.musicFlowMotion;

    return AnimatedPadding(
      duration: motion.resolve(context, motion.state),
      curve: motion.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: MusicFlowBottomSheet(
        title: widget.title,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              MusicFlowTextField(
                controller: _nameController,
                label: widget.fieldLabel ?? loc.library_playlist_name,
                hintText: widget.hintText ?? loc.library_playlist_name_hint,
                leadingIcon: AppIcons.playlist,
                autofocus: true,
                textInputAction: TextInputAction.done,
                validator: (value) => value == null || value.trim().isEmpty
                    ? loc.library_playlist_name_required
                    : null,
                onSubmitted: (_) => _submit(),
              ),
              SizedBox(height: context.musicFlowSpacing.lg),
              Row(
                children: <Widget>[
                  Expanded(
                    child: MusicFlowButton.secondary(
                      label: loc.settings_cancel,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SizedBox(width: context.musicFlowSpacing.sm),
                  Expanded(
                    child: MusicFlowButton.primary(
                      label: widget.confirmText,
                      onPressed: _submit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选择器结果：命中已有歌单，或要求新建。
class StudyPlaylistPick {
  const StudyPlaylistPick.existing(this.playlist) : createNew = false;

  const StudyPlaylistPick.create() : playlist = null, createNew = true;

  final StudyPlaylist? playlist;
  final bool createNew;
}

/// 列出学习歌单供选择（首项为「新建学习歌单」）。
Future<StudyPlaylistPick?> showStudyPlaylistPickerSheet({
  required BuildContext context,
  required int count,
}) {
  return showMusicFlowBottomSheet<StudyPlaylistPick>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) => _StudyPlaylistPickerSheet(count: count),
  );
}

class _StudyPlaylistPickerSheet extends ConsumerWidget {
  const _StudyPlaylistPickerSheet({required this.count});

  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final playlists = ref.watch(studyPlaylistsProvider);
    return MusicFlowBottomSheet(
      title: loc.study_add_to_playlist,
      subtitle: loc.library_selected_count('$count'),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.playlistAdd,
              title: loc.study_playlist_create,
              onPressed: () =>
                  Navigator.of(context).pop(const StudyPlaylistPick.create()),
            ),
            const MusicFlowDivider(),
            Flexible(
              child: playlists.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: context.musicFlowSpacing.lg,
                  ),
                  child: Center(
                    child: MusicFlowButton.secondary(
                      label: loc.widgets_retry,
                      onPressed: () => ref.invalidate(studyPlaylistsProvider),
                    ),
                  ),
                ),
                data: (items) {
                  if (items.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: context.musicFlowSpacing.lg,
                      ),
                      child: Text(
                        loc.study_empty_playlists,
                        textAlign: TextAlign.center,
                        style: context.musicFlowTypography.metadata.copyWith(
                          color: context.musicFlowColors.muted,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final playlist = items[index];
                      return MusicFlowActionRow(
                        icon: AppIcons.playlist,
                        title: playlist.name,
                        subtitle: loc.study_playlist_song_count(
                          playlist.songCount,
                        ),
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(StudyPlaylistPick.existing(playlist)),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌单操作（重命名 / 移动到文件夹 / 移出文件夹 / 删除）。
enum StudyPlaylistAction { rename, move, removeFromFolder, delete }

Future<StudyPlaylistAction?> showStudyPlaylistActionsSheet({
  required BuildContext context,
  required StudyPlaylist playlist,
}) {
  return showMusicFlowBottomSheet<StudyPlaylistAction>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) => _StudyPlaylistActionsSheet(playlist: playlist),
  );
}

class _StudyPlaylistActionsSheet extends StatelessWidget {
  const _StudyPlaylistActionsSheet({required this.playlist});

  final StudyPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MusicFlowBottomSheet(
      title: playlist.name,
      subtitle: loc.study_playlist_song_count(playlist.songCount),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          MusicFlowActionRow(
            icon: AppIcons.edit,
            title: loc.study_playlist_rename,
            onPressed: () =>
                Navigator.of(context).pop(StudyPlaylistAction.rename),
          ),
          MusicFlowActionRow(
            icon: AppIcons.folder,
            title: loc.study_move_to_folder,
            onPressed: () =>
                Navigator.of(context).pop(StudyPlaylistAction.move),
          ),
          if (playlist.folder.isNotEmpty)
            MusicFlowActionRow(
              icon: AppIcons.folderOpen,
              title: loc.study_remove_from_folder,
              onPressed: () =>
                  Navigator.of(context).pop(StudyPlaylistAction.removeFromFolder),
            ),
          MusicFlowActionRow(
            icon: AppIcons.delete,
            title: loc.library_delete_playlist,
            destructive: true,
            onPressed: () =>
                Navigator.of(context).pop(StudyPlaylistAction.delete),
          ),
        ],
      ),
    );
  }
}

// ==================== 学习歌单文件夹 ====================

/// 空白区域长按菜单：新建歌单 / 新建文件夹。
enum StudyBlankAction { newPlaylist, newFolder }

Future<StudyBlankAction?> showStudyBlankActionsSheet({
  required BuildContext context,
  required bool includeFolder,
}) {
  return showMusicFlowBottomSheet<StudyBlankAction>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) {
      final loc = AppLocalizations.of(context);
      return MusicFlowBottomSheet(
        title: loc.study_blank_actions_title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.playlistAdd,
              title: loc.study_playlist_create,
              onPressed: () =>
                  Navigator.of(context).pop(StudyBlankAction.newPlaylist),
            ),
            if (includeFolder)
              MusicFlowActionRow(
                icon: AppIcons.folder,
                title: loc.study_new_folder,
                onPressed: () =>
                    Navigator.of(context).pop(StudyBlankAction.newFolder),
              ),
          ],
        ),
      );
    },
  );
}

/// 文件夹操作（重命名 / 删除）。
enum StudyFolderAction { rename, delete }

Future<StudyFolderAction?> showStudyFolderActionsSheet({
  required BuildContext context,
  required String folder,
}) {
  return showMusicFlowBottomSheet<StudyFolderAction>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) {
      final loc = AppLocalizations.of(context);
      return MusicFlowBottomSheet(
        title: folder,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.edit,
              title: loc.study_folder_rename,
              onPressed: () =>
                  Navigator.of(context).pop(StudyFolderAction.rename),
            ),
            MusicFlowActionRow(
              icon: AppIcons.delete,
              title: loc.study_folder_delete,
              destructive: true,
              onPressed: () =>
                  Navigator.of(context).pop(StudyFolderAction.delete),
            ),
          ],
        ),
      );
    },
  );
}

/// 文件夹选择结果：移动到已有文件夹、根目录，或新建文件夹。
class StudyFolderPick {
  const StudyFolderPick.existing(this.folder) : createNew = false;

  const StudyFolderPick.root()
      : folder = '',
        createNew = false;

  const StudyFolderPick.create()
      : folder = '',
        createNew = true;

  final String folder;
  final bool createNew;
}

Future<StudyFolderPick?> showStudyFolderPickerSheet({
  required BuildContext context,
  required String title,
  required List<String> folders,
  required String currentFolder,
}) {
  return showMusicFlowBottomSheet<StudyFolderPick>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    desktopAnchored:
        context.musicFlowWindowClass != MusicFlowWindowClass.compact,
    builder: (_) => _StudyFolderPickerSheet(
      title: title,
      folders: folders,
      currentFolder: currentFolder,
    ),
  );
}

class _StudyFolderPickerSheet extends StatelessWidget {
  const _StudyFolderPickerSheet({
    required this.title,
    required this.folders,
    required this.currentFolder,
  });

  final String title;
  final List<String> folders;
  final String currentFolder;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return MusicFlowBottomSheet(
      title: title,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MusicFlowActionRow(
              icon: AppIcons.folderOpen,
              title: loc.study_root_folder,
              selected: currentFolder.isEmpty,
              onPressed: () =>
                  Navigator.of(context).pop(const StudyFolderPick.root()),
            ),
            for (final folder in folders)
              MusicFlowActionRow(
                icon: AppIcons.folder,
                title: folder,
                selected: folder == currentFolder,
                onPressed: () => Navigator.of(
                  context,
                ).pop(StudyFolderPick.existing(folder)),
              ),
            const MusicFlowDivider(),
            MusicFlowActionRow(
              icon: AppIcons.playlistAdd,
              title: loc.study_or_new_folder,
              onPressed: () =>
                  Navigator.of(context).pop(const StudyFolderPick.create()),
            ),
          ],
        ),
      ),
    );
  }
}

/// 删除文件夹确认（说明歌单只会回到根目录）。
Future<bool?> showDeleteFolderConfirmSheet({
  required BuildContext context,
  required String folder,
}) {
  return showMusicFlowBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final loc = AppLocalizations.of(sheetContext);
      return MusicFlowBottomSheet(
        title: loc.study_folder_delete,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              loc.study_folder_delete_confirm(folder),
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
                    label: loc.common_delete,
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// 「加入学习歌单」完整流程：选择歌单（或新建）后把 [songIds] 加入。
///
/// 返回 true 表示加入成功。
Future<bool> addStudySongsToPlaylist({
  required BuildContext context,
  required WidgetRef ref,
  required List<String> songIds,
}) async {
  if (songIds.isEmpty) return false;
  final loc = AppLocalizations.of(context);
  final pick = await showStudyPlaylistPickerSheet(
    context: context,
    count: songIds.length,
  );
  if (pick == null || !context.mounted) return false;

  var playlist = pick.playlist;
  if (pick.createNew) {
    final name = await showStudyPlaylistNameSheet(
      context: context,
      title: loc.study_playlist_create,
      confirmText: loc.common_save,
    );
    if (name == null || !context.mounted) return false;
    try {
      final id = await ref.read(studyApiProvider).createPlaylist(name);
      playlist = StudyPlaylist(id: id, name: name);
      ref.invalidate(studyPlaylistsProvider);
    } catch (_) {
      ToastNotifier.show(
        loc.study_playlist_create_failed,
        kind: MusicFlowMessageKind.error,
      );
      return false;
    }
  }
  final target = playlist;
  if (target == null) return false;

  try {
    await ref.read(studyApiProvider).addTracks(target.id, songIds);
  } catch (_) {
    ToastNotifier.show(
      loc.study_add_to_playlist_failed,
      kind: MusicFlowMessageKind.error,
    );
    return false;
  }
  ref.invalidate(studyPlaylistsProvider);
  ref.invalidate(studyPlaylistTracksProvider(target.id));
  ToastNotifier.show(
    loc.study_added_to_playlist(target.name, songIds.length),
    kind: MusicFlowMessageKind.success,
  );
  return true;
}
