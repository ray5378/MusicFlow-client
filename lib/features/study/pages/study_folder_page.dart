import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/study/study_folder_tree.dart';
import 'package:musicflow_client/features/study/study_playlist_actions.dart';
import 'package:musicflow_client/features/study/widgets/study_rows.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

/// 打开某个学习歌单文件夹（点首页文件夹行时调用）。
void openStudyFolder(BuildContext context, String path) {
  unawaited(
    Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(
        context: context,
        builder: (_) => StudyFolderPage(path: path),
      ),
    ),
  );
}

/// 学习歌单「文件夹内部」页：只列**这一层**（直属子文件夹 + 直属歌单），
/// 点子文件夹再进一层，返回则退上一层。
///
/// 与「学习目录」浏览页（StudyBrowsePage）同一套交互：点文件夹 = 进到里面，
/// 而不是把里面的内容摊在当前列表里。文件夹本身没有实体，只是歌单上 `a/b`
/// 形式的路径，层级由 [buildStudyFolderPaths] 补全父目录后算出。
class StudyFolderPage extends ConsumerWidget {
  const StudyFolderPage({super.key, required this.path});

  /// 本页对应的文件夹完整路径（如 `课程/高数`）。
  final String path;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(studyPlaylistsProvider);
    ref.invalidate(studyPlaylistFoldersProvider);
    try {
      await Future.wait<void>(<Future<void>>[
        ref.read(studyPlaylistsProvider.future).then((_) {}),
        ref.read(studyPlaylistFoldersProvider.future).then((_) {}),
      ]);
    } catch (_) {
      // 失败由列表错误态提示，这里只负责结束下拉动画。
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final playlists = ref.watch(studyPlaylistsProvider);
    final folderNames = ref.watch(studyPlaylistFoldersProvider);
    final allPlaylists = playlists.asData?.value ?? const <StudyPlaylist>[];
    // 文件夹路径全集：接口给的（含空文件夹）+ 歌单上挂着的（老的、接口没补全的）。
    final allFolders = buildStudyFolderPaths(<String>[
      ...(folderNames.asData?.value ?? const <String>[]),
      for (final playlist in allPlaylists)
        if (playlist.folder.isNotEmpty) playlist.folder,
    ]);
    final childFolders = studyChildFolders(allFolders, path);
    final directPlaylists = <StudyPlaylist>[
      for (final playlist in allPlaylists)
        if (playlist.folder == path) playlist,
    ];

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(
        context: context,
        title: studyFolderLabel(path),
        subtitle: path,
        actions: <Widget>[
          MusicFlowIconButton(
            icon: AppIcons.folder,
            label: loc.study_new_folder,
            onPressed: () =>
                unawaited(createStudyFolder(context, ref, parent: path)),
          ),
          MusicFlowIconButton(
            icon: AppIcons.playlistAdd,
            label: loc.study_playlist_create,
            onPressed: () =>
                unawaited(createStudyPlaylist(context, ref, folder: path)),
          ),
        ],
      ),
      body: MusicFlowRefreshView(
        onRefresh: () => _refresh(ref),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: playlists.when(
              loading: () => const StudyLoadingRows(),
              error: (error, _) => StudyErrorRow(
                message: loc.study_load_failed,
                onRetry: () => ref.invalidate(studyPlaylistsProvider),
              ),
              data: (_) {
                if (childFolders.isEmpty && directPlaylists.isEmpty) {
                  return Center(
                    child: Text(
                      loc.study_empty_dir,
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  );
                }
                return ListView(
                  padding: EdgeInsets.only(
                    left: context.musicFlowPageHorizontalPadding,
                    right: context.musicFlowPageHorizontalPadding,
                    bottom: 32,
                  ),
                  children: <Widget>[
                    for (final folder in childFolders)
                      StudyFolderRow(
                        name: studyFolderLabel(folder),
                        playlistCount: allPlaylists
                            .where((playlist) => playlist.folder == folder)
                            .length,
                        folderCount: studyChildFolders(
                          allFolders,
                          folder,
                        ).length,
                        onTap: () => openStudyFolder(context, folder),
                        onLongPress: () => unawaited(
                          showStudyFolderActions(context, ref, folder),
                        ),
                      ),
                    for (final playlist in directPlaylists)
                      StudyRow(
                        icon: AppIcons.play,
                        iconLabel: loc.study_icon_play_playlist,
                        onIconTap: () => unawaited(
                          playStudyPlaylist(context, ref, playlist),
                        ),
                        title: playlist.name,
                        subtitle: loc.study_playlist_song_count(
                          playlist.songCount,
                        ),
                        onTap: () => openStudyPlaylist(context, playlist),
                        onLongPress: () => unawaited(
                          showStudyPlaylistActions(context, ref, playlist),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
