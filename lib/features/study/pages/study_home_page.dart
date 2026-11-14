import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/study_api.dart';
import 'package:musicflow_client/features/study/pages/study_browse_page.dart';
import 'package:musicflow_client/features/study/pages/study_folder_page.dart';
import 'package:musicflow_client/features/study/study_folder_tree.dart';
import 'package:musicflow_client/features/study/study_playlist_actions.dart';
import 'package:musicflow_client/features/study/widgets/study_playlist_sheets.dart';
import 'package:musicflow_client/features/study/widgets/study_rows.dart';
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
      // 顶部导航行需要避让系统状态栏（与首页 SafeArea 一致）。
      topBar: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 页标题「学习」:字号/高度/左右留白与首页「MusicFlow」标题一致,
            // 让下方的模块入口与首页分类导航处于同一水平线。
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.musicFlowPageHorizontalPadding - 5,
                context.musicFlowSpacing.sm,
                context.musicFlowPageHorizontalPadding - 5,
                context.musicFlowSpacing.sm,
              ),
              child: SizedBox(
                height: 48,
                width: double.infinity,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    header: true,
                    namesRoute: true,
                    child: Text(
                      loc.study_title,
                      style: context.musicFlowTypography.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            // 与首页分类导航同款：不带标题栏底色，图标在上、文字在下；
            // 高度/间距/左右留白与首页「探索 / 喜欢」一栏保持一致。
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.musicFlowPageHorizontalPadding - 5,
                context.musicFlowSpacing.xs,
                context.musicFlowPageHorizontalPadding - 5,
                0,
              ),
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
                    SizedBox(width: context.musicFlowSpacing.md),
                    _StudyModuleTab(
                      label: loc.study_section_playlists,
                      icon: AppIcons.playlist,
                      selected: _tab == 1 && !_searchOpen,
                      onPressed: () => _setTab(1),
                    ),
                    SizedBox(width: context.musicFlowSpacing.md),
                    _StudyModuleTab(
                      label: loc.study_section_continue,
                      icon: AppIcons.history,
                      selected: _tab == 2 && !_searchOpen,
                      onPressed: () => _setTab(2),
                    ),
                    SizedBox(width: context.musicFlowSpacing.md),
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
              ? StudyEmptyRow(icon: AppIcons.search, label: loc.study_search_empty)
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
              ? const StudyLoadingRows()
              : _contentResults.isEmpty
                  ? StudyEmptyRow(
                      icon: AppIcons.search,
                      label: loc.study_search_empty,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final song in _contentResults)
                          StudyRow(
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
        // 标题已在顶部导航中展示,这里直接进入内容,不再重复「总目录」。
        const SizedBox(height: 8),
        sources.when(
          loading: () => const StudyLoadingRows(),
          error: (error, _) => StudyErrorRow(
            message: loc.study_load_failed,
            onRetry: () => ref.invalidate(studySourcesProvider),
          ),
          data: (items) {
            final visible = items
                .where((source) => _matches(source.name))
                .toList(growable: false);
            if (items.isEmpty) {
              return StudyEmptyRow(
                icon: AppIcons.study,
                label: loc.study_empty_catalog,
              );
            }
            if (visible.isEmpty) {
              return StudyEmptyRow(
                icon: AppIcons.search,
                label: loc.study_search_empty,
              );
            }
            return Column(
              children: <Widget>[
                for (final source in visible)
                  StudyRow(
                    icon: AppIcons.study,
                    title: source.name,
                    subtitle: source.songCount > 0
                        ? loc.study_source_song_count(source.songCount)
                        : null,
                    onTap: () => _openBrowse(context, source),
                    onLongPress: () => unawaited(_showSourceActions(source)),
                  ),
              ],
            );
          },
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
        // 标题已由顶部导航展示;仅保留新建文件夹/歌单的快捷入口,右对齐。
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              MusicFlowIconButton(
                icon: AppIcons.folder,
                label: loc.study_new_folder,
                onPressed: () => unawaited(createStudyFolder(context, ref)),
              ),
              MusicFlowIconButton(
                icon: AppIcons.playlistAdd,
                label: loc.study_playlist_create,
                onPressed: () => unawaited(createStudyPlaylist(context, ref)),
              ),
            ],
          ),
        ),
        playlists.when(
          loading: () => const StudyLoadingRows(),
          error: (error, _) => StudyErrorRow(
            message: loc.study_load_failed,
            onRetry: () => ref.invalidate(studyPlaylistsProvider),
          ),
          data: (items) {
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
                    StudyEmptyRow(
                      icon: AppIcons.search,
                      label: loc.study_search_empty,
                    )
                  else
                    for (final playlist in matched)
                      _buildPlaylistRow(context, loc, playlist),
                ],
              );
            }
            // 文件夹以完整路径（a/b）存储：这里只放**根层**（不含 `/` 的一段），
            // 子层靠点文件夹进到里面看（StudyFolderPage），不再原地展开摊平。
            final allFolders = buildStudyFolderPaths(<String>[
              ...(folderNames.asData?.value ?? const <String>[]),
              for (final playlist in items)
                if (playlist.folder.isNotEmpty) playlist.folder,
            ]);
            final rootFolders = rootStudyFolders(allFolders);
            final rootPlaylists = items
                .where((playlist) => playlist.folder.isEmpty)
                .toList(growable: false);
            if (items.isEmpty && rootFolders.isEmpty) {
              return StudyEmptyRow(
                icon: AppIcons.playlist,
                label: loc.study_empty_playlists,
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final folder in rootFolders)
                  StudyFolderRow(
                    name: studyFolderLabel(folder),
                    playlistCount: items
                        .where((playlist) => playlist.folder == folder)
                        .length,
                    folderCount: studyChildFolders(allFolders, folder).length,
                    onTap: () => openStudyFolder(context, folder),
                    onLongPress: () => unawaited(
                      showStudyFolderActions(context, ref, folder),
                    ),
                  ),
                for (final playlist in rootPlaylists)
                  _buildPlaylistRow(context, loc, playlist),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildPlaylistRow(
    BuildContext context,
    AppLocalizations loc,
    StudyPlaylist playlist,
  ) {
    return StudyRow(
      icon: AppIcons.play,
      iconLabel: loc.study_icon_play_playlist,
      onIconTap: () => unawaited(playStudyPlaylist(context, ref, playlist)),
      title: playlist.name,
      subtitle: playlist.folder.isEmpty
          ? loc.study_playlist_song_count(playlist.songCount)
          : '${loc.study_playlist_song_count(playlist.songCount)} · ${playlist.folder}',
      onTap: () => openStudyPlaylist(context, playlist),
      onLongPress: () =>
          unawaited(showStudyPlaylistActions(context, ref, playlist)),
    );
  }

  Widget _buildContinueTab(BuildContext context, AppLocalizations loc) {
    final continuing = ref.watch(studyContinueProvider);
    final hasRecords = !(continuing.asData?.value.isEmpty ?? true);
    return ListView(
      padding: _listPadding,
      children: <Widget>[
        // 标题已由顶部导航展示;仅保留「清空学习记录」入口,右对齐。
        if (hasRecords)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: MusicFlowButton.ghost(
                label: loc.study_clear_records,
                onPressed: () => unawaited(_clearContinueRecords()),
              ),
            ),
          ),
        continuing.when(
            loading: () => const StudyLoadingRows(),
            error: (error, _) => StudyErrorRow(
              message: loc.study_load_failed,
              onRetry: () => ref.invalidate(studyContinueProvider),
            ),
            data: (result) {
              if (result.isEmpty) {
                return StudyEmptyRow(
                  icon: AppIcons.history,
                  label: loc.study_empty_continue,
                );
              }
              final visible = result.items
                  .where((item) => _matches(item.song.title))
                  .toList(growable: false);
              // 学习歌单续播条目:标题是歌单名,副标题是上次听到的那一节。
              final visiblePlaylists = result.playlistItems
                  .where((item) =>
                      _matches(item.playlistName) || _matches(item.song.title))
                  .toList(growable: false);
              if (visible.isEmpty && visiblePlaylists.isEmpty) {
                return StudyEmptyRow(
                  icon: AppIcons.search,
                  label: loc.study_search_empty,
                );
              }
              final currentId = ref.watch(
                playerProvider.select((s) => s.currentSong?.id),
              );
              return Column(
                children: <Widget>[
                  for (final item in visiblePlaylists)
                    _SwipeDeleteRow(
                      deleteLabel: loc.common_delete,
                      onDelete: () =>
                          unawaited(_deleteContinueRecord(item)),
                      child: _ContinueRow(
                        item: item,
                        playing: item.song.id == currentId,
                        icon: AppIcons.playlist,
                        title: item.playlistName,
                        subtitle: item.song.title,
                        onTap: () => unawaited(_resumePlaylist(item)),
                      ),
                    ),
                  for (var i = 0; i < visible.length; i++)
                    _SwipeDeleteRow(
                      deleteLabel: loc.common_delete,
                      onDelete: () =>
                          unawaited(_deleteContinueRecord(visible[i])),
                      child: _ContinueRow(
                        item: visible[i],
                        playing: visible[i].song.id == currentId,
                        onTap: () => unawaited(_playContinue(visible, i)),
                      ),
                    ),
                ],
              );
            },
        ),
      ],
    );
  }

  /// 学习歌单续播:取整单曲目,定位到上次那一节,并从上次位置继续。
  Future<void> _resumePlaylist(StudyContinueItem item) async {
    final loc = AppLocalizations.of(context);
    if (item.playlistId.isEmpty) return;
    try {
      final songs = await ref.read(
        studyPlaylistTracksProvider(item.playlistId).future,
      );
      if (!mounted) return;
      if (songs.isEmpty) {
        _toast(loc.study_empty_playlist_tracks, kind: MusicFlowMessageKind.error);
        return;
      }
      final index = songs.indexWhere((s) => s.id == item.song.id);
      final start = index >= 0 ? index : 0;
      final casting =
          ref.read(castPeerControllerProvider).activePeer != null ||
          ref.read(dlnaCastProvider).isCasting;
      if (casting) {
        await playEffectiveQueue(ref, songs, startIndex: start);
        return;
      }
      await ref.read(playerProvider.notifier).playQueue(
            songs,
            startIndex: start,
            initialPosition: Duration(seconds: item.positionSec),
          );
    } catch (_) {
      if (!mounted) return;
      _toast(loc.study_load_failed, kind: MusicFlowMessageKind.error);
    }
  }

  /// 清空全部学习记录(含学习歌单续播位置,不删除音频文件)。
  Future<void> _clearContinueRecords() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showMusicFlowBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.study_clear_records,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              loc.study_clear_records_confirm,
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
                    label: loc.study_clear_records_action,
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
    try {
      await ref.read(studyApiProvider).clearProgress();
      ref.invalidate(studyContinueProvider);
      _toast(loc.study_clear_records_done);
    } catch (_) {
      if (!mounted) return;
      _toast(loc.study_clear_records_failed, kind: MusicFlowMessageKind.error);
    }
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

  void _toast(String message, {MusicFlowMessageKind kind = MusicFlowMessageKind.success}) {
    if (!mounted) return;
    ToastNotifier.show(message, kind: kind);
  }

  /// 总目录里的学习源（顶层目录）长按：整源递归加入学习歌单。
  Future<void> _showSourceActions(StudySource source) async {
    final action = await showStudyDirActionsSheet(
      context: context,
      name: source.name,
    );
    if (action != StudyDirAction.addToPlaylist || !mounted) return;
    await addStudyDirToPlaylist(
      context: context,
      ref: ref,
      sourceId: source.id,
      path: '',
    );
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

  /// 删除一条学习记录（只从「继续学习」移除，不删除音频文件）。
  Future<void> _deleteContinueRecord(StudyContinueItem item) async {
    final loc = AppLocalizations.of(context);
    try {
      await ref.read(studyApiProvider).deleteProgress(item.song.id);
      ref.invalidate(studyContinueProvider);
      _toast(loc.study_record_deleted);
    } catch (_) {
      _toast(loc.study_delete_record_failed, kind: MusicFlowMessageKind.error);
    }
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

  // 与首页分类导航同一尺寸：64×64；4 个入口 + 3 段间距在 320dp 窄屏内仍放得下。
  static const double _width = 64;

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
      minimumSize: const Size(_width, 64),
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

/// 左滑露出右侧「删除」按钮的行容器。
///
/// 拖动行内容向左偏移，松开后按位移/速度吸附到展开或收起；
/// 展开时右侧删除按钮可点，点按行内其他区域先收起。
class _SwipeDeleteRow extends StatefulWidget {
  const _SwipeDeleteRow({
    required this.child,
    required this.deleteLabel,
    required this.onDelete,
  });

  final Widget child;
  final String deleteLabel;
  final VoidCallback onDelete;

  @override
  State<_SwipeDeleteRow> createState() => _SwipeDeleteRowState();
}

class _SwipeDeleteRowState extends State<_SwipeDeleteRow> {
  static const double _actionWidth = 96;

  double _offset = 0;

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _offset = (_offset + details.delta.dx).clamp(-_actionWidth, 0.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() {
      if (velocity < -300) {
        _offset = -_actionWidth;
      } else if (velocity > 300) {
        _offset = 0;
      } else {
        _offset = _offset < -_actionWidth / 2 ? -_actionWidth : 0;
      }
    });
  }

  void _close() {
    if (_offset != 0) setState(() => _offset = 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final open = _offset != 0;
    return ClipRRect(
      borderRadius: context.musicFlowRadii.surface,
      child: Stack(
        children: <Widget>[
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _actionWidth,
            child: MusicFlowPressable(
              semanticLabel: widget.deleteLabel,
              borderRadius: BorderRadius.zero,
              minimumSize: const Size(_actionWidth, 48),
              onPressed: () {
                _close();
                widget.onDelete();
              },
              child: ColoredBox(
                color: colors.error,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        AppIcons.delete,
                        size: 18,
                        color: colors.onError,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.deleteLabel,
                        style: context.musicFlowTypography.metadata.copyWith(
                          color: colors.onError,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          GestureDetector(
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: Transform.translate(
              offset: Offset(_offset, 0),
              child: ColoredBox(
                color: colors.canvas,
                child: widget.child,
              ),
            ),
          ),
          if (open)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: _actionWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
            ),
        ],
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
    this.icon,
    this.title,
    this.subtitle,
  });

  final StudyContinueItem item;
  final bool playing;
  final VoidCallback onTap;

  /// 歌单续播行用列表图标区分;为空时按播放状态显示播放/正在播放图标。
  final IconData? icon;

  /// 主标题/副标题覆盖:歌单续播行显示歌单名 + 上次那一节。
  final String? title;
  final String? subtitle;

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
                    icon ?? (playing ? AppIcons.equalizer : AppIcons.play),
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
                    title ?? item.song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.musicFlowTypography.body.copyWith(
                      color: playing ? colors.accent : colors.ink,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle == null
                          ? '${_formatSeconds(item.positionSec)} · $percent%'
                          : '$subtitle · ${_formatSeconds(item.positionSec)} · $percent%',
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
