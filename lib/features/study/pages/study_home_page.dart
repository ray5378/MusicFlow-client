import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/library/widgets/playlist_manage_dialogs.dart';
import 'package:musicflow_client/features/study/pages/study_browse_page.dart';
import 'package:musicflow_client/features/study/pages/study_playlist_page.dart';
import 'package:musicflow_client/features/study/widgets/study_playlist_sheets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/study/study_providers.dart';

/// 学习模块首页：总目录 / 学习歌单 / 继续学习。
///
/// 三个模块与首页分类导航同款排版（图标在上、文字在下，无底色条），点击切换；
/// 搜索为统一搜索：一次搜「学习歌单 + 学习内容」，歌单排在内容前面。
class StudyHomePage extends ConsumerStatefulWidget {
  const StudyHomePage({super.key});

  @override
  ConsumerState<StudyHomePage> createState() => _StudyHomePageState();
}

class _StudyHomePageState extends ConsumerState<StudyHomePage> {
  static const List<String> _tabNames = <String>[
    'catalog',
    'playlists',
    'continue',
  ];

  int _tab = 0;
  bool _searchOpen = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final Set<String> _expandedFolders = <String>{};
  // 统一搜索的内容结果（服务端 kind=study 模糊匹配）。
  List<Song> _contentResults = const <Song>[];
  bool _contentSearching = false;
  Timer? _searchDebounce;
  int _searchSeq = 0;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(studySourcesProvider);
    ref.invalidate(studyPlaylistsProvider);
    ref.invalidate(studyPlaylistFoldersProvider);
    ref.invalidate(studyContinueProvider);
    await Future.wait<void>(<Future<void>>[
      ref.read(studySourcesProvider.future).then((_) {}),
      ref.read(studyPlaylistsProvider.future).then((_) {}),
      ref.read(studyPlaylistFoldersProvider.future).then((_) {}),
      ref.read(studyContinueProvider.future).then((_) {}),
    ]).catchError((Object _) => <void>[]);
  }

  void _setTab(int index) {
    if (_tab == index && !_searchOpen) return;
    setState(() {
      _tab = index;
      _searchOpen = false;
      _query = '';
      _searchController.clear();
    });
    _searchDebounce?.cancel();
    setState(() {
      _contentResults = const <Song>[];
      _contentSearching = false;
    });
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _query = '';
        _searchController.clear();
        _contentResults = const <Song>[];
        _contentSearching = false;
      }
    });
    _searchDebounce?.cancel();
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  /// 统一搜索：输入即搜「学习歌单 + 学习内容」（歌单本地即时过滤，内容走服务端）。
  void _onQueryChanged(String value) {
    setState(() => _query = value);
    _searchDebounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) {
      setState(() {
        _contentResults = const <Song>[];
        _contentSearching = false;
      });
      return;
    }
    setState(() => _contentSearching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 260), () {
      unawaited(_runContentSearch(q));
    });
  }

  Future<void> _runContentSearch(String q) async {
    final seq = ++_searchSeq;
    try {
      final songs = await ref.read(studyApiProvider).searchContents(q);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _contentResults = songs;
        _contentSearching = false;
      });
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _contentResults = const <Song>[];
        _contentSearching = false;
      });
    }
  }

  bool get _searchActive => _searchOpen && _query.trim().isNotEmpty;

  bool _matches(String text) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return text.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    // 进入学习模块即激活学习进度上报（应用级单例，重复读取无副作用）。
    ref.read(studyProgressReporterProvider);
    final loc = AppLocalizations.of(context);

    return MusicFlowScaffold(
      topBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 与首页分类导航同款：不带标题栏底色，图标在上、文字在下；
          // 搜索按钮常驻最右，展开后搜索框在下一行。
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowPageHorizontalPadding - 8,
              context.musicFlowSpacing.sm,
              context.musicFlowPageHorizontalPadding - 8,
              0,
            ),
            child: Row(
              children: <Widget>[
                MusicFlowIconButton(
                  icon: AppIcons.back,
                  label: loc.core_back,
                  onPressed: () => Navigator.maybePop(context),
                ),
                // 四个入口按首页导航样式横排（图标在上、文字在下）；窄屏/大字号自动缩放。
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _StudyModuleTab(
                          label: loc.study_section_catalog,
                          icon: AppIcons.study,
                          selected: _tab == 0 && !_searchOpen,
                          onPressed: () => _setTab(0),
                        ),
                        SizedBox(width: context.musicFlowSpacing.sm),
                        _StudyModuleTab(
                          label: loc.study_section_playlists,
                          icon: AppIcons.playlist,
                          selected: _tab == 1 && !_searchOpen,
                          onPressed: () => _setTab(1),
                        ),
                        SizedBox(width: context.musicFlowSpacing.sm),
                        _StudyModuleTab(
                          label: loc.study_section_continue,
                          icon: AppIcons.history,
                          selected: _tab == 2 && !_searchOpen,
                          onPressed: () => _setTab(2),
                        ),
                        SizedBox(width: context.musicFlowSpacing.sm),
                        // 搜索与三个模块同款入口（图标在上、文字在下），展开后输入框在下一行。
                        _StudyModuleTab(
                          label: loc.study_module_search,
                          icon: AppIcons.search,
                          selected: _searchOpen,
                          onPressed: _toggleSearch,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_searchOpen)
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.musicFlowPageHorizontalPadding,
                context.musicFlowSpacing.sm,
                context.musicFlowPageHorizontalPadding,
                context.musicFlowSpacing.xs,
              ),
              child: MusicFlowTextField(
                controller: _searchController,
                focusNode: _searchFocus,
                label: loc.study_search_unified_hint,
                leadingIcon: AppIcons.search,
                onChanged: _onQueryChanged,
                trailing: _query.isEmpty
                    ? null
                    : MusicFlowIconButton(
                        icon: AppIcons.close,
                        label: loc.study_search_clear,
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                        },
                      ),
              ),
            ),
          SizedBox(height: context.musicFlowSpacing.xs),
        ],
      ),
      body: MusicFlowRefreshView(
        onRefresh: _refresh,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _searchActive
                ? _buildSearchResults(context, loc)
                : _buildTabBody(context, loc),
          ),
        ),
      ),
    );
  }

  Widget _buildTabBody(BuildContext context, AppLocalizations loc) {
    switch (_tabNames[_tab]) {
      case 'playlists':
        return _buildPlaylistsTab(context, loc);
      case 'continue':
        return _buildContinueTab(context, loc);
      default:
        return _buildCatalogTab(context, loc);
    }
  }

  /// 统一搜索结果：学习歌单排在前面，学习内容排在后面（与服务端搜索一致）。
  Widget _buildSearchResults(BuildContext context, AppLocalizations loc) {
    final playlists =
        ref.watch(studyPlaylistsProvider).asData?.value ??
            const <StudyPlaylist>[];
    final matchedPlaylists = playlists
        .where((playlist) => _matches(playlist.name))
        .toList(growable: false);
    return ListView(
      padding: _listPadding,
      children: <Widget>[
        _Section(
          title: loc.study_section_playlists,
          child: matchedPlaylists.isEmpty
              ? _EmptyRow(icon: AppIcons.search, label: loc.study_search_empty)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final playlist in matchedPlaylists)
                      _buildPlaylistRow(context, loc, playlist),
                  ],
                ),
        ),
        _Section(
          title: loc.study_section_contents,
          child: _contentSearching
              ? const _LoadingRows()
              : _contentResults.isEmpty
                  ? _EmptyRow(
                      icon: AppIcons.search,
                      label: loc.study_search_empty,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final song in _contentResults)
                          _StudyRow(
                            icon: AppIcons.play,
                            title: song.title,
                            subtitle: (song.album ?? '').isEmpty
                                ? null
                                : song.album,
                            onTap: () => unawaited(_playSong(song)),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }

  /// 搜索结果里点单条学习内容 → 直接播放（投屏态走统一流转入口）。
  Future<void> _playSong(Song song) async {
    final casting =
        ref.read(castPeerControllerProvider).activePeer != null ||
            ref.read(dlnaCastProvider).isCasting;
    if (casting) {
      await playEffectiveQueue(ref, <Song>[song], startIndex: 0);
      return;
    }
    await ref.read(playerProvider.notifier).playQueue(<Song>[song], startIndex: 0);
  }

  EdgeInsets get _listPadding => EdgeInsets.only(
        left: context.musicFlowPageHorizontalPadding,
        right: context.musicFlowPageHorizontalPadding,
        bottom: 32,
      );

  Widget _buildCatalogTab(BuildContext context, AppLocalizations loc) {
    final sources = ref.watch(studySourcesProvider);
    return ListView(
      padding: _listPadding,
      children: <Widget>[
        _Section(
          title: loc.study_section_catalog,
          child: sources.when(
            loading: () => const _LoadingRows(),
            error: (error, _) => _ErrorRow(
              message: loc.study_load_failed,
              onRetry: () => ref.invalidate(studySourcesProvider),
            ),
            data: (items) {
              final visible = items
                  .where((source) => _matches(source.name))
                  .toList(growable: false);
              if (items.isEmpty) {
                return _EmptyRow(
                  icon: AppIcons.study,
                  label: loc.study_empty_catalog,
                );
              }
              if (visible.isEmpty) {
                return _EmptyRow(
                  icon: AppIcons.search,
                  label: loc.study_search_empty,
                );
              }
              return Column(
                children: <Widget>[
                  for (final source in visible)
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
          ),
        ),
        _BlankZone(
          label: loc.study_blank_hint,
          onLongPress: () => unawaited(_showBlankActions(includeFolder: false)),
        ),
      ],
    );
  }

  Widget _buildPlaylistsTab(BuildContext context, AppLocalizations loc) {
    final playlists = ref.watch(studyPlaylistsProvider);
    final folderNames = ref.watch(studyPlaylistFoldersProvider);
    return ListView(
      padding: _listPadding,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  loc.study_section_playlists,
                  style: context.musicFlowTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              MusicFlowIconButton(
                icon: AppIcons.folder,
                label: loc.study_new_folder,
                onPressed: () => unawaited(_createFolder()),
              ),
              MusicFlowIconButton(
                icon: AppIcons.playlistAdd,
                label: loc.study_playlist_create,
                onPressed: () => unawaited(_createPlaylist()),
              ),
            ],
          ),
        ),
        playlists.when(
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
            final query = _query.trim();
            if (query.isNotEmpty) {
              final matched = items
                  .where((playlist) => _matches(playlist.name))
                  .toList(growable: false);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      loc.study_playlist_search_result(matched.length),
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ),
                  if (matched.isEmpty)
                    _EmptyRow(
                      icon: AppIcons.search,
                      label: loc.study_search_empty,
                    )
                  else
                    for (final playlist in matched)
                      _buildPlaylistRow(context, loc, playlist),
                ],
              );
            }
            final knownFolders = <String>{
              ...(folderNames.asData?.value ?? const <String>[]),
              for (final playlist in items)
                if (playlist.folder.isNotEmpty) playlist.folder,
            }.toList()
              ..sort();
            final rootPlaylists = items
                .where((playlist) => playlist.folder.isEmpty)
                .toList(growable: false);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final folder in knownFolders) ...<Widget>[
                  _FolderRow(
                    name: folder,
                    count: items
                        .where((playlist) => playlist.folder == folder)
                        .length,
                    expanded: _expandedFolders.contains(folder),
                    onTap: () => setState(() {
                      if (!_expandedFolders.add(folder)) {
                        _expandedFolders.remove(folder);
                      }
                    }),
                    onLongPress: () => unawaited(_showFolderActions(folder)),
                  ),
                  if (_expandedFolders.contains(folder))
                    for (final playlist in items.where(
                      (playlist) => playlist.folder == folder,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: _buildPlaylistRow(context, loc, playlist),
                      ),
                ],
                for (final playlist in rootPlaylists)
                  _buildPlaylistRow(context, loc, playlist),
              ],
            );
          },
        ),
        _BlankZone(
          label: loc.study_blank_hint,
          onLongPress: () => unawaited(_showBlankActions(includeFolder: true)),
        ),
      ],
    );
  }

  Widget _buildPlaylistRow(
    BuildContext context,
    AppLocalizations loc,
    StudyPlaylist playlist,
  ) {
    return _StudyRow(
      icon: AppIcons.play,
      iconLabel: loc.study_icon_play_playlist,
      onIconTap: () => unawaited(_playPlaylist(playlist)),
      title: playlist.name,
      subtitle: playlist.folder.isEmpty
          ? loc.study_playlist_song_count(playlist.songCount)
          : '${loc.study_playlist_song_count(playlist.songCount)} · ${playlist.folder}',
      onTap: () => _openPlaylist(context, playlist),
      onLongPress: () =>
          unawaited(_showPlaylistActions(playlist)),
    );
  }

  Widget _buildContinueTab(BuildContext context, AppLocalizations loc) {
    final continuing = ref.watch(studyContinueProvider);
    return ListView(
      padding: _listPadding,
      children: <Widget>[
        _Section(
          title: loc.study_section_continue,
          child: continuing.when(
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
              final visible = items
                  .where((item) => _matches(item.song.title))
                  .toList(growable: false);
              if (visible.isEmpty) {
                return _EmptyRow(
                  icon: AppIcons.search,
                  label: loc.study_search_empty,
                );
              }
              final currentId = ref.watch(
                playerProvider.select((s) => s.currentSong?.id),
              );
              return Column(
                children: <Widget>[
                  for (var i = 0; i < visible.length; i++)
                    _ContinueRow(
                      item: visible[i],
                      playing: visible[i].song.id == currentId,
                      onTap: () => unawaited(_playContinue(visible, i)),
                    ),
                ],
              );
            },
          ),
        ),
      ],
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

  void _openPlaylist(BuildContext context, StudyPlaylist playlist) {
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

  /// 点击歌单图标:不进入详情,直接播放整个学习歌单。
  Future<void> _playPlaylist(StudyPlaylist playlist) async {
    final loc = AppLocalizations.of(context);
    try {
      final songs = await ref.read(
        studyPlaylistTracksProvider(playlist.id).future,
      );
      if (!mounted) return;
      if (songs.isEmpty) {
        _toast(loc.study_empty_playlist_tracks, kind: MusicFlowMessageKind.error);
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
      if (!mounted) return;
      _toast(loc.study_play_failed, kind: MusicFlowMessageKind.error);
    }
  }

  void _invalidatePlaylists() {
    ref.invalidate(studyPlaylistsProvider);
    ref.invalidate(studyPlaylistFoldersProvider);
  }

  void _toast(String message, {MusicFlowMessageKind kind = MusicFlowMessageKind.success}) {
    if (!mounted) return;
    ToastNotifier.show(message, kind: kind);
  }

  /// 新建学习歌单：输入名称后创建并刷新列表。
  Future<void> _createPlaylist() async {
    final loc = AppLocalizations.of(context);
    final name = await showStudyPlaylistNameSheet(
      context: context,
      title: loc.study_playlist_create,
      confirmText: loc.common_save,
    );
    if (name == null || !mounted) return;
    try {
      await ref.read(studyApiProvider).createPlaylist(name);
      _invalidatePlaylists();
      _toast(loc.study_playlist_created(name));
    } catch (_) {
      _toast(loc.study_playlist_create_failed, kind: MusicFlowMessageKind.error);
    }
  }

  /// 新建歌单文件夹。
  Future<void> _createFolder() async {
    final loc = AppLocalizations.of(context);
    final name = await showStudyPlaylistNameSheet(
      context: context,
      title: loc.study_new_folder,
      confirmText: loc.common_save,
      fieldLabel: loc.study_new_folder,
      hintText: loc.study_folder_name_hint,
    );
    if (name == null || !mounted) return;
    try {
      await ref.read(studyApiProvider).createPlaylistFolder(name);
      _invalidatePlaylists();
      _toast(loc.study_folder_created(name));
    } catch (_) {
      _toast(loc.study_folder_create_failed, kind: MusicFlowMessageKind.error);
    }
  }

  Future<void> _showBlankActions({required bool includeFolder}) async {
    final action = await showStudyBlankActionsSheet(
      context: context,
      includeFolder: includeFolder,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case StudyBlankAction.newPlaylist:
        await _createPlaylist();
      case StudyBlankAction.newFolder:
        await _createFolder();
    }
  }

  Future<void> _showFolderActions(String folder) async {
    final action = await showStudyFolderActionsSheet(
      context: context,
      folder: folder,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case StudyFolderAction.rename:
        await _renameFolder(folder);
      case StudyFolderAction.delete:
        await _deleteFolder(folder);
    }
  }

  Future<void> _renameFolder(String folder) async {
    final loc = AppLocalizations.of(context);
    final name = await showStudyPlaylistNameSheet(
      context: context,
      title: loc.study_folder_rename_title,
      confirmText: loc.common_save,
      initialName: folder,
      fieldLabel: loc.study_new_folder,
      hintText: loc.study_folder_name_hint,
    );
    if (name == null || !mounted || name == folder) return;
    try {
      await ref.read(studyApiProvider).renamePlaylistFolder(folder, name);
      setState(() {
        if (_expandedFolders.remove(folder)) _expandedFolders.add(name);
      });
      _invalidatePlaylists();
      _toast(loc.study_folder_renamed(name));
    } catch (_) {
      _toast(loc.study_folder_update_failed, kind: MusicFlowMessageKind.error);
    }
  }

  Future<void> _deleteFolder(String folder) async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDeleteFolderConfirmSheet(
      context: context,
      folder: folder,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(studyApiProvider).deletePlaylistFolder(folder);
      _expandedFolders.remove(folder);
      _invalidatePlaylists();
      _toast(loc.study_folder_deleted(folder));
    } catch (_) {
      _toast(loc.study_folder_delete_failed, kind: MusicFlowMessageKind.error);
    }
  }

  /// 歌单长按菜单：重命名 / 移动到文件夹 / 移出文件夹 / 删除。
  Future<void> _showPlaylistActions(StudyPlaylist playlist) async {
    final action = await showStudyPlaylistActionsSheet(
      context: context,
      playlist: playlist,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case StudyPlaylistAction.rename:
        await _renamePlaylist(playlist);
      case StudyPlaylistAction.move:
        await _movePlaylist(playlist);
      case StudyPlaylistAction.removeFromFolder:
        await _applyPlaylistFolder(playlist, '');
      case StudyPlaylistAction.delete:
        await _deletePlaylist(playlist);
    }
  }

  Future<void> _renamePlaylist(StudyPlaylist playlist) async {
    final loc = AppLocalizations.of(context);
    final name = await showStudyPlaylistNameSheet(
      context: context,
      title: loc.study_playlist_rename_title,
      confirmText: loc.common_save,
      initialName: playlist.name,
    );
    if (name == null || !mounted || name == playlist.name) return;
    try {
      await ref.read(studyApiProvider).renamePlaylist(playlist.id, name);
      _invalidatePlaylists();
      ref.invalidate(studyPlaylistTracksProvider(playlist.id));
      _toast(loc.study_playlist_renamed(name));
    } catch (_) {
      _toast(loc.study_playlist_update_failed, kind: MusicFlowMessageKind.error);
    }
  }

  /// 移动到文件夹：可选择已有文件夹、根目录或现场新建文件夹。
  Future<void> _movePlaylist(StudyPlaylist playlist) async {
    final loc = AppLocalizations.of(context);
    final folders = await ref.read(studyPlaylistFoldersProvider.future).catchError(
          (Object _) => const <String>[],
        );
    if (!mounted) return;
    final pick = await showStudyFolderPickerSheet(
      context: context,
      title: loc.study_move_to_folder_title(playlist.name),
      folders: folders,
      currentFolder: playlist.folder,
    );
    if (pick == null || !mounted) return;
    if (pick.createNew) {
      final name = await showStudyPlaylistNameSheet(
        context: context,
        title: loc.study_new_folder,
        confirmText: loc.common_save,
        fieldLabel: loc.study_new_folder,
        hintText: loc.study_folder_name_hint,
      );
      if (name == null || !mounted) return;
      await _applyPlaylistFolder(playlist, name, createFolder: true);
      return;
    }
    await _applyPlaylistFolder(playlist, pick.folder);
  }

  Future<void> _applyPlaylistFolder(
    StudyPlaylist playlist,
    String folder, {
    bool createFolder = false,
  }) async {
    final loc = AppLocalizations.of(context);
    try {
      final api = ref.read(studyApiProvider);
      if (createFolder) await api.createPlaylistFolder(folder);
      await api.movePlaylist(playlist.id, folder);
      _invalidatePlaylists();
      _toast(
        folder.isEmpty
            ? loc.study_removed_from_folder
            : loc.study_moved_to_folder(folder),
      );
    } catch (_) {
      _toast(loc.study_playlist_update_failed, kind: MusicFlowMessageKind.error);
    }
  }

  Future<void> _deletePlaylist(StudyPlaylist playlist) async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDeletePlaylistConfirmDialog(
      context: context,
      playlistName: playlist.name,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(studyApiProvider).deletePlaylist(playlist.id);
      _invalidatePlaylists();
      ref.invalidate(studyPlaylistTracksProvider(playlist.id));
      _toast(loc.study_playlist_deleted(playlist.name));
    } catch (_) {
      _toast(loc.study_playlist_delete_failed, kind: MusicFlowMessageKind.error);
    }
  }

  /// 继续学习：本机续播从上次进度起播；投屏/直投交给流转链路（对端起播）。
  Future<void> _playContinue(
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
    await ref
        .read(playerProvider.notifier)
        .playQueue(
          songs,
          startIndex: index,
          initialPosition: Duration(seconds: items[index].positionSec),
        );
  }
}

/// 学习模块标签：与首页分类导航同款「图标在上、文字在下」，无底色条。
class _StudyModuleTab extends StatelessWidget {
  const _StudyModuleTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  // 四个入口 + 返回按钮要在 320dp 窄屏内放得下（4×56 + 3×8 = 248）。
  static const double _width = 56;

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final color = selected ? colors.accent : colors.muted;
    return MusicFlowPressable(
      semanticLabel: label,
      selected: selected,
      minimumSize: const Size(_width, 60),
      borderRadius: context.musicFlowRadii.surface,
      onPressed: onPressed,
      child: SizedBox(
        width: _width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 26, color: color),
            SizedBox(height: context.musicFlowSpacing.xxs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.musicFlowTypography.metadata.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: MusicFlowSectionHeader(title: title, trailing: trailing),
        ),
        child,
      ],
    );
  }
}

/// 文件夹行（点击展开/收起夹内歌单，长按重命名/删除）。
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.name,
    required this.count,
    required this.expanded,
    required this.onTap,
    required this.onLongPress,
  });

  final String name;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final loc = AppLocalizations.of(context);
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
                      loc.study_folder_playlist_count(count),
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: colors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
              size: 18,
              color: colors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// 空白区域：长按新建歌单 / 文件夹。
class _BlankZone extends StatelessWidget {
  const _BlankZone({required this.label, required this.onLongPress});

  final String label;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: MusicFlowPressable(
        onPressed: onLongPress,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        borderRadius: context.musicFlowRadii.control,
        child: Container(
          height: 110,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: context.musicFlowRadii.control,
            border: Border.all(
              color: colors.muted.withValues(alpha: 0.2),
              style: BorderStyle.solid,
            ),
          ),
          child: Text(
            label,
            style: context.musicFlowTypography.metadata.copyWith(
              color: colors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _StudyRow extends StatelessWidget {
  const _StudyRow({
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
