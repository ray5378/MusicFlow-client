import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/song_group_display.dart';
import '../../../features/library/widgets/windowed_paginated_list.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/network_error_notifier.dart';
import '../../../core/utils/toast_notifier.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/song.dart';
import '../../../data/sources/subsonic_api_client.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/queue_origin_provider.dart';
import '../../../widgets/song_list_item.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../utils/library_sorting.dart';
import '../widgets/media_detail_components.dart';
import '../widgets/playlist_manage_dialogs.dart';
import '../widgets/playlist_options_sheet.dart';

/// 歌单详情 —— 窗口化分页加载(对齐主项目前端 useInfiniteList / 音乐库页):
/// - 头部元数据走轻量接口([PlaylistRepository.getPlaylistMeta]),不再一次性拉全部曲目;
/// - 曲目列表按 page/pageSize 分块拉取并窗口化渲染,滚动到哪拉到哪,内存峰值恒定;
/// - 只有「播放全部 / 非默认排序 / 加入播放列表」等需要完整顺序表的操作,
///   才在用户主动触发时后台逐页拉全量(渲染层仍保持窗口化)。
class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.initialName,
    this.initialSongCount,
    this.initialCoverArt,
  });

  final String playlistId;

  /// 预加载数据：点击歌单时从列表/卡片直接传入，避免打开后白屏等待网络。
  final String? initialName;
  final int? initialSongCount;
  final String? initialCoverArt;

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  SongSortOption _sortOption = SongSortOption.defaultOrder;

  // ---- 轻量元数据 ----
  Playlist? _meta;
  bool _metaFailed = false;

  // ---- 窗口化分页曲目列表(默认顺序) ----
  late final WindowedPaginatedList<Song> _songList =
      WindowedPaginatedList<Song>(
        fetcher: (page, pageSize, query) async {
          final repository = ref.read(playlistRepositoryProvider);
          if (repository == null) return (items: <Song>[], total: 0);
          return repository.getPlaylistTracksPage(
            widget.playlistId,
            page,
            pageSize,
          );
        },
      );

  // ---- 全量模式(非默认排序:一次拉全量后本地排序) ----
  bool _fullMode = false;
  List<_PlaylistSongEntry> _fullEntries = const <_PlaylistSongEntry>[];
  bool _fullLoading = false;
  bool _fullFailed = false;

  /// 全量模式下同曲多源组「非首个成员」的 originalIndex 集合(折叠隐藏)。
  final Set<int> _fullCollapsedSet = <int>{};

  /// 全量模式下重算折叠集合:组内首个成员保留(渲染 playbackSource),
  /// 其余成员行折叠为零高度。与分页模式的 isCollapsedGroupSlot 语义一致。
  void _rebuildFullCollapsed() {
    _fullCollapsedSet.clear();
    final seen = <String>{};
    for (final e in _fullEntries) {
      final gid = songGroupIdOf(e.song);
      if (gid == null) continue;
      if (!seen.add(gid)) _fullCollapsedSet.add(e.originalIndex);
    }
  }

  // ---- 选择/移除 ----
  final Set<int> _selectedSongIndexes = <int>{};
  bool _selectionMode = false;
  bool _isRemovingSongs = false;
  int _mutationGeneration = 0;

  /// 进入选择模式时记录的歌单内容版本;检测到外部刷新导致内容变化时,
  /// 清空选择并提示,避免按过期索引移除错误的歌曲。
  int? _selectionRevision;
  bool _selectionResetScheduled = false;

  @override
  void initState() {
    super.initState();
    _loadMeta();
    _songList.load('');
  }

  @override
  void didUpdateWidget(covariant PlaylistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistId == widget.playlistId) return;
    _mutationGeneration++;
    _selectionMode = false;
    _selectedSongIndexes.clear();
    _isRemovingSongs = false;
    _selectionRevision = null;
    _selectionResetScheduled = false;
    _meta = null;
    _metaFailed = false;
    _fullMode = false;
    _fullEntries = const <_PlaylistSongEntry>[];
    _sortOption = SongSortOption.defaultOrder;
    _loadMeta();
    _songList.load('');
  }

  @override
  void dispose() {
    _songList.dispose();
    super.dispose();
  }

  Future<void> _loadMeta() async {
    setState(() => _metaFailed = false);
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      setState(() => _metaFailed = true);
      return;
    }
    try {
      await ref.read(ensureActiveAddressProvider.future);
      final meta = await repository.getPlaylistMeta(widget.playlistId);
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _metaFailed = meta == null;
      });
    } catch (error, stackTrace) {
      Logger.warnWithTag('PLAYLIST', 'playlist meta load failed', error);
      Logger.debugWithTag(
        'PLAYLIST',
        'playlist meta stackTrace',
        null,
        stackTrace,
      );
      if (!mounted) return;
      // 元数据拉取失败但列表可能已加载:退化为用初始参数拼出的占位元数据,
      // 仍能展示封面+标题,列表独立加载不受影响。
      setState(() => _metaFailed = true);
    }
  }

  Playlist? get _displayMeta {
    if (_meta != null) return _meta;
    if (widget.initialName == null) return null;
    return Playlist(
      id: widget.playlistId,
      name: widget.initialName!,
      songCount: widget.initialSongCount ?? 0,
      duration: 0,
      coverArt: widget.initialCoverArt,
    );
  }

  int get _totalCount {
    if (_fullMode) return _fullEntries.length;
    if (_songList.total > 0) return _songList.total;
    return _meta?.songCount ?? widget.initialSongCount ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    // 监听歌单内容快照:外部刷新(惰性重建/其他端修改)导致内容变化时,
    // 在选歌状态下自动清空过期选择,避免用过期索引移除错误的歌曲。
    final currentPlaylist =
        ref.watch(playlistDetailProvider(widget.playlistId)).valueOrNull;
    _scheduleSelectionResetIfStale(currentPlaylist);

    final displayMeta = _displayMeta;
    final currentSongCount = _totalCount;
    final allSongsSelected =
        currentSongCount > 0 && _selectedSongIndexes.length >= currentSongCount;

    final topBar = _selectionMode
        ? MusicFlowTopBar(
            title: '已选 ${_selectedSongIndexes.length} 首',
            leading: MusicFlowIconButton(
              icon: AppIcons.close,
              label: '退出歌曲管理',
              onPressed: _isRemovingSongs ? null : _exitSelectionMode,
            ),
            actions: <Widget>[
              MusicFlowIconButton(
                icon: allSongsSelected ? AppIcons.clearAll : AppIcons.selectAll,
                label: allSongsSelected ? '取消全选歌曲' : '全选歌曲',
                selected: allSongsSelected,
                onPressed: currentSongCount == 0 || _isRemovingSongs
                    ? null
                    : () => _toggleSelectAll(currentSongCount),
              ),
            ],
          )
        : MusicFlowTopBar.back(
            context: context,
            title: '歌单',
            actions: <Widget>[
              MusicFlowIconButton(
                icon: AppIcons.selectAll,
                label: '管理歌单歌曲',
                onPressed: currentSongCount == 0 || _isRemovingSongs
                    ? null
                    : _enterSelectionMode,
              ),
              MusicFlowIconButton(
                icon: AppIcons.sort,
                label: '歌曲排序：${_sortOption.label}',
                onPressed: _isRemovingSongs ? null : _selectSortOption,
              ),
              MusicFlowIconButton(
                icon: AppIcons.more,
                label: '歌单操作',
                onPressed: _meta == null || _isRemovingSongs
                    ? null
                    : () => _showPlaylistActions(_meta!),
              ),
            ],
          );

    return PopScope<void>(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode && !_isRemovingSongs) {
          _exitSelectionMode();
        }
      },
      child: VisibleRemoteRetryScope(
        branchIndex: libraryBranchIndex,
        debugLabel: 'playlist_detail_page',
        shouldRetry: (ref) => _metaFailed || _songList.hasError,
        onRetry: (ref) => _retry(),
        child: MusicFlowScaffold(
          topBar: topBar,
          bottomBar: _selectionMode
              ? _PlaylistSelectionBar(
                  selectedCount: _selectedSongIndexes.length,
                  removing: _isRemovingSongs,
                  onRemove: _selectedSongIndexes.isEmpty
                      ? null
                      : () => _confirmBatchRemoval(),
                )
              : null,
          body: _body(displayMeta),
        ),
      ),
    );
  }

  Widget _body(Playlist? displayMeta) {
    // 当前播放来源：识别本歌单是否正在播放（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);
    final isNowPlaying = queueOrigin?.matchesPlaylist(widget.playlistId) ??
        false;
    if (displayMeta == null) {
      if (_metaFailed) {
        return MusicFlowErrorState(
          title: '歌单加载失败',
          description: '无法读取歌单详情。请检查网络后重试。',
          actionLabel: '重试',
          onAction: _retry,
        );
      }
      return widget.initialName != null
          ? _PlaylistLoadingPreview(
              name: widget.initialName!,
              songCount: widget.initialSongCount ?? 0,
              coverArt: widget.initialCoverArt,
            )
          : const MediaDetailLoadingView();
    }

    final playlist = displayMeta;
    final currentSongCount = _totalCount;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: AnimatedBuilder(
          animation: _songList,
          builder: (context, _) => CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _PlaylistIdentityHeader(
                  playlist: playlist,
                  songCount: currentSongCount,
                  isNowPlaying: isNowPlaying,
                ),
              ),
              if (_songList.hasError && currentSongCount == 0)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      context.musicFlowSpacing.md,
                      context.musicFlowSpacing.md,
                      context.musicFlowSpacing.md,
                      0,
                    ),
                    child: MediaLoadNotice(
                      message: '网络连接异常，当前可能显示缓存的歌单内容。',
                      onRetry: _retry,
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: MusicFlowSectionHeader(
                  title: '歌曲',
                  description: _selectionMode
                      ? '轻触歌曲选择要从歌单移除的条目'
                      : currentSongCount == 0
                      ? '歌单中暂时没有歌曲'
                      : '$currentSongCount 首 · ${_sortOption.label}',
                  trailing: MusicFlowButton.primary(
                    label: '播放全部',
                    leadingIcon: AppIcons.play,
                    // 播放全部按钮缩小为默认高度的 2/3。
                    height: context.musicFlowInteraction.buttonHeight * (2 / 3),
                    onPressed: currentSongCount == 0
                        ? null
                        : () => unawaited(_playAll()),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    context.musicFlowSpacing.md,
                    context.musicFlowSpacing.lg,
                    context.musicFlowSpacing.md,
                    context.musicFlowSpacing.xs,
                  ),
                ),
              ),
              if (currentSongCount == 0)
                const SliverToBoxAdapter(
                  child: MusicFlowEmptyState(
                    title: '歌单还是空的',
                    description: '通过歌曲操作菜单把喜欢的内容加入这个歌单。',
                    icon: AppIcons.playlistAdd,
                    padding: EdgeInsets.all(32),
                  ),
                )
              else if (_fullMode)
                ..._buildFullListSlivers()
              else if (_songList.hasError && _songList.total == 0)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: MusicFlowButton.secondary(
                        label: '加载失败，点击重试',
                        onPressed: _retry,
                      ),
                    ),
                  ),
                )
              else
                ..._buildWindowedSongSlivers(),
              SliverToBoxAdapter(
                child: SizedBox(
                  key: const ValueKey<String>('playlist-detail-bottom-spacer'),
                  height:
                      context.musicFlowSpacing.xxl +
                      (_selectionMode ? 0 : context.musicFlowShellBottomObstruction),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 默认顺序:窗口化分页渲染,滚动到哪拉到哪。
  List<Widget> _buildWindowedSongSlivers() {
    final total = _songList.total > 0 ? _songList.total : _songList.pageSize;
    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
        ),
        sliver: SliverList.builder(
          itemCount: total,
          itemBuilder: (context, index) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _songList.ensureRange(index, index),
            );
            final item = _songList[index];
            if (item == null) {
              return SizedBox(
                height: 72,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: MusicFlowSkeleton(
                    width: double.infinity,
                    height: 56,
                    borderRadius: context.musicFlowRadii.detail,
                  ),
                ),
              );
            }
            return _buildSongRow(context, index, item);
          },
        ),
      ),
      if (_songList.loading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
    ];
  }

  /// 非默认排序:使用一次拉取的全量列表本地排序后渲染。
  List<Widget> _buildFullListSlivers() {
    if (_fullLoading) {
      return const <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_fullFailed) {
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: MusicFlowButton.secondary(
                label: '加载失败，点击重试',
                onPressed: () => _applySortOption(_sortOption),
              ),
            ),
          ),
        ),
      ];
    }
    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
        ),
        sliver: SliverList.builder(
          itemCount: _fullEntries.length,
          itemBuilder: (context, index) {
            final entry = _fullEntries[index];
            // 全量模式按排序展示,但行 key/选中/移除必须使用原始歌单索引
            // (songIndexesToRemove 语义 = 原歌单位置),而非排序后的显示位置。
            return _buildSongRow(context, entry.originalIndex, entry.song);
          },
        ),
      ),
    ];
  }

  Widget _buildSongRow(BuildContext context, int index, Song song) {
    // 同曲多源组折叠:分页模式用稀疏数组扫描,全量模式用预计算的折叠集合。
    // 组内非首个成员渲染零高度;首个成员(主行)用 playbackSource 显示。
    final isCollapsed = _fullMode
        ? _fullCollapsedSet.contains(index)
        : isCollapsedGroupSlot(_songList.slots, index, groupKeyOf: songGroupIdOf);
    if (isCollapsed) return const SizedBox.shrink();
    final displaySong = song.playbackSource;
    // 当前播放歌曲 id：识别正在播放的歌曲行（封面叠加跳动竖条）。
    final currentSongId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    return KeyedSubtree(
      key: ValueKey<String>('playlist-song-$index'),
      child: SongListItem(
        song: displaySong,
        index: index,
        variant: SongListItemVariant.standard,
        isCurrent: displaySong.id == currentSongId,
        groupBadge: groupSourceBadge(displaySong),
        selectionMode: _selectionMode,
        selected: _selectedSongIndexes.contains(index),
        onToggleSelected: () => _toggleSongSelection(index),
        onTap: () => unawaited(_playAt(index)),
        onLongPress: () => _enterSelectionMode(originalIndex: index),
        onMorePressed: () => _showSongActions(song, index),
      ),
    );
  }

  Future<void> _playAll() async {
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) return;
    try {
      final all = await repository.getAllPlaylistSongs(widget.playlistId);
      if (!mounted) return;
      await playEffectiveQueue(
        ref,
        all,
        startIndex: 0,
        origin: QueueOrigin(QueueOriginKind.playlist, widget.playlistId),
      );
    } catch (_) {
      if (mounted) NetworkErrorNotifier.show('网络异常，无法播放歌单');
    }
  }

  Future<void> _playAt(int index) async {
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) return;
    try {
      final all = await repository.getAllPlaylistSongs(widget.playlistId);
      if (!mounted) return;
      await playEffectiveQueue(
        ref,
        all,
        startIndex: index.clamp(0, all.length - 1),
        origin: QueueOrigin(QueueOriginKind.playlist, widget.playlistId),
      );
    } catch (_) {
      final song = _songList[index];
      if (song == null || !mounted) return;
      await playEffectiveQueue(ref, <Song>[song], startIndex: 0);
    }
  }

  Future<void> _selectSortOption() async {
    final option = await showMediaSongSortSheet(
      context: context,
      current: _sortOption,
    );
    if (!mounted || option == null || option == _sortOption) return;
    await _applySortOption(option);
  }

  Future<void> _applySortOption(SongSortOption option) async {
    if (option == SongSortOption.defaultOrder) {
      setState(() {
        _sortOption = option;
        _fullMode = false;
        _fullEntries = const <_PlaylistSongEntry>[];
        _fullFailed = false;
      });
      _songList.load('');
      return;
    }
    setState(() {
      _sortOption = option;
      _fullMode = true;
      _fullLoading = true;
      _fullFailed = false;
      _fullEntries = const <_PlaylistSongEntry>[];
    });
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      if (mounted) setState(() => _fullFailed = true);
      return;
    }
    try {
      final all = await repository.getAllPlaylistSongs(widget.playlistId);
      if (!mounted) return;
      setState(() {
        _fullEntries = _sortPlaylistEntries(all, option);
        _rebuildFullCollapsed();
        _fullLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fullLoading = false;
        _fullFailed = true;
      });
    }
  }

  Future<List<Song>> _loadAllSortedSongs() async {
    if (_fullMode) {
      return _fullEntries.map((entry) => entry.song).toList(growable: false);
    }
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) return const <Song>[];
    final all = await repository.getAllPlaylistSongs(widget.playlistId);
    return _sortPlaylistEntries(
      all,
      _sortOption,
    ).map((entry) => entry.song).toList(growable: false);
  }

  void _retry() {
    _loadMeta();
    _songList.load('');
  }

  void _enterSelectionMode({int? originalIndex}) {
    if (_isRemovingSongs) return;
    final revision = _playlistRevision(
      ref.read(playlistDetailProvider(widget.playlistId)).valueOrNull,
    );
    setState(() {
      if (_selectionRevision != revision) {
        _selectedSongIndexes.clear();
      }
      _selectionMode = true;
      _selectionRevision = revision;
      if (originalIndex != null) {
        _selectedSongIndexes.add(originalIndex);
      }
    });
  }

  void _exitSelectionMode() {
    if (_isRemovingSongs) return;
    setState(() {
      _selectionMode = false;
      _selectedSongIndexes.clear();
      _selectionRevision = null;
    });
  }

  void _toggleSongSelection(int originalIndex) {
    if (_isRemovingSongs) return;
    setState(() {
      if (!_selectedSongIndexes.add(originalIndex)) {
        _selectedSongIndexes.remove(originalIndex);
      }
    });
  }

  void _toggleSelectAll(int totalCount) {
    if (_isRemovingSongs || totalCount <= 0) return;
    setState(() {
      final allSelected = _selectedSongIndexes.length >= totalCount;
      if (allSelected) {
        _selectedSongIndexes.clear();
      } else {
        _selectedSongIndexes
          ..clear()
          ..addAll(Iterable<int>.generate(totalCount));
      }
    });
  }

  Future<void> _showSongActions(Song song, int originalIndex) {
    return showSongOptionsSheet(
      context: context,
      song: song,
      extraActions: <SongOptionsExtraAction>[
        SongOptionsExtraAction(
          icon: AppIcons.removeCircle,
          title: '从歌单移除',
          isDestructive: true,
          onPressed: () => _removeSongEntries(
            originalIndexes: <int>[originalIndex],
            successMessage: '已从歌单移除《${song.title}》',
          ),
        ),
      ],
    );
  }

  Future<void> _confirmBatchRemoval() async {
    if (_selectedSongIndexes.isEmpty || _isRemovingSongs) return;
    final playlist = _displayMeta;
    if (playlist == null) return;
    final count = _selectedSongIndexes.length;
    final confirmed = await showMusicFlowBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: '移除歌曲',
        subtitle: '只会修改当前歌单，不会删除音乐文件。',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '确定从「${playlist.name}」中移除选中的 $count 首歌曲吗？',
              style: sheetContext.musicFlowTypography.body.copyWith(
                color: sheetContext.musicFlowColors.muted,
              ),
            ),
            SizedBox(height: sheetContext.musicFlowSpacing.lg),
            Row(
              children: <Widget>[
                Expanded(
                  child: MusicFlowButton.secondary(
                    label: '取消',
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                  ),
                ),
                SizedBox(width: sheetContext.musicFlowSpacing.sm),
                Expanded(
                  child: MusicFlowButton.destructive(
                    label: '移除',
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
    if (_selectedSongIndexes.isEmpty) return;
    await _removeSongEntries(
      originalIndexes: Set<int>.of(_selectedSongIndexes),
      successMessage: '已移除 $count 首歌曲',
    );
  }

  Future<void> _removeSongEntries({
    required Iterable<int> originalIndexes,
    required String successMessage,
  }) async {
    if (_isRemovingSongs) return;
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show('未选择音乐库');
      return;
    }
    final ensureAddress = ref.read(ensureActiveAddressProvider.future);

    final totalCount = _totalCount;
    final indexes =
        originalIndexes
            .where((index) => index >= 0 && index < totalCount)
            .toSet()
            .toList()
          ..sort((left, right) => right.compareTo(left));
    if (indexes.isEmpty) return;

    final mutationToken = ++_mutationGeneration;
    setState(() => _isRemovingSongs = true);
    try {
      await ensureAddress;
      if (!_isCurrentMutation(mutationToken)) return;
      await repository.updatePlaylist(
        playlistId: widget.playlistId,
        songIndexesToRemove: indexes,
      );
      if (mounted) {
        ref.invalidate(playlistsProvider);
      }
      if (!_isCurrentMutation(mutationToken)) return;
      setState(() {
        _isRemovingSongs = false;
        _selectionMode = false;
        _selectedSongIndexes.clear();
        _selectionRevision = null;
      });
      // 窗口化列表与元数据一并刷新:先重新拉轻量元数据再重载分页列表。
      _loadMeta();
      _songList.load('');
      ToastNotifier.show(successMessage, kind: MusicFlowMessageKind.success);
    } catch (error) {
      if (!_isCurrentMutation(mutationToken)) return;
      setState(() => _isRemovingSongs = false);
      if (error is SubsonicException && error.code == 50) {
        NetworkErrorNotifier.show('无权修改该歌单，或该歌单不支持移除歌曲');
      } else if (error is SubsonicException) {
        final message = error.message.trim();
        NetworkErrorNotifier.show(
          message.isEmpty ? '服务器拒绝移除歌曲' : '移除失败：$message',
        );
      } else {
        NetworkErrorNotifier.show('网络异常，移除失败');
      }
    }
  }

  bool _isCurrentMutation(int token) {
    return mounted && _mutationGeneration == token;
  }

  /// 选择状态下若歌单内容版本发生变化,安排在下一次帧清空过期选择。
  void _scheduleSelectionResetIfStale(Playlist? playlist) {
    final selectionRevision = _selectionRevision;
    if (!_selectionMode ||
        selectionRevision == null ||
        playlist == null ||
        playlist.id != widget.playlistId ||
        _playlistRevision(playlist) == selectionRevision ||
        _selectionResetScheduled) {
      return;
    }

    final playlistId = widget.playlistId;
    _selectionResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionResetScheduled = false;
      if (!mounted ||
          widget.playlistId != playlistId ||
          !_selectionMode ||
          _selectionRevision != selectionRevision) {
        return;
      }
      final latest =
          ref.read(playlistDetailProvider(playlistId)).valueOrNull;
      if (latest == null || _playlistRevision(latest) == selectionRevision) {
        return;
      }
      _resetStaleSelection();
    });
  }

  void _resetStaleSelection() {
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedSongIndexes.clear();
      _selectionRevision = null;
    });
    ToastNotifier.show('歌单内容已更新，请重新选择');
  }

  Future<void> _showPlaylistActions(Playlist playlist) async {
    final action = await showPlaylistOptionsSheet(
      context: context,
      playlist: playlist,
      hasSongs: _totalCount > 0,
    );
    if (!mounted || action == null) return;
    await _onMoreActionSelected(playlist, action);
  }

  Future<void> _onMoreActionSelected(
    Playlist playlist,
    PlaylistOptionsAction action,
  ) async {
    switch (action) {
      case PlaylistOptionsAction.addToQueue:
        await _addPlaylistToQueue();
      case PlaylistOptionsAction.edit:
        await _editPlaylist(playlist);
      case PlaylistOptionsAction.delete:
        await _deletePlaylist(playlist);
    }
  }

  Future<void> _addPlaylistToQueue() async {
    final songs = await _loadAllSortedSongs();
    if (songs.isEmpty) {
      NetworkErrorNotifier.show('歌单暂无可用歌曲');
      return;
    }
    ref.read(playerProvider.notifier).addAllToQueue(songs);
    ToastNotifier.show(
      '已添加 ${songs.length} 首到播放列表',
      kind: MusicFlowMessageKind.success,
    );
  }

  Future<void> _editPlaylist(Playlist playlist) async {
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show('未选择音乐库');
      return;
    }

    final formResult = await showPlaylistFormDialog(
      context: context,
      title: '修改歌单',
      confirmText: '保存',
      initialName: playlist.name,
      initialComment: playlist.comment ?? '',
      initialPublic: playlist.public,
    );
    if (formResult == null) return;
    final currentComment = (playlist.comment ?? '').trim();
    if (formResult.name == playlist.name &&
        formResult.comment == currentComment &&
        formResult.isPublic == playlist.public) {
      return;
    }

    try {
      await ref.read(ensureActiveAddressProvider.future);
      await repository.updatePlaylist(
        playlistId: playlist.id,
        name: formResult.name,
        comment: formResult.comment,
        public: formResult.isPublic,
      );
      ref.invalidate(playlistsProvider);
      _loadMeta();
      if (mounted) {
        ToastNotifier.show(
          '已更新歌单「${formResult.name}」',
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (_) {
      NetworkErrorNotifier.show('网络异常，修改失败');
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final repository = ref.read(playlistRepositoryProvider);
    if (repository == null) {
      NetworkErrorNotifier.show('未选择音乐库');
      return;
    }

    final confirmed = await showDeletePlaylistConfirmDialog(
      context: context,
      playlistName: playlist.name,
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(ensureActiveAddressProvider.future);
      await repository.deletePlaylist(playlist.id);
      ref.invalidate(playlistsProvider);
      if (mounted) {
        Navigator.of(context).pop();
        ToastNotifier.show(
          '已删除歌单「${playlist.name}」',
          kind: MusicFlowMessageKind.success,
        );
      }
    } catch (_) {
      NetworkErrorNotifier.show('网络异常，删除失败');
    }
  }
}

class _PlaylistSongEntry {
  const _PlaylistSongEntry({required this.song, required this.originalIndex});

  final Song song;
  final int originalIndex;
}

/// 歌单内容版本:由元数据与歌曲明细共同决定,用于识别选择期间歌单被外部刷新。
int _playlistRevision(Playlist? playlist) {
  if (playlist == null) return 0;
  final songs = playlist.songs ?? const <Song>[];
  return Object.hash(
    playlist.id,
    playlist.changed?.microsecondsSinceEpoch,
    playlist.songCount,
    playlist.duration,
    Object.hashAll(
      songs.map(
        (song) => Object.hash(
          song.id,
          song.title,
          song.artistId,
          song.albumId,
          song.duration,
        ),
      ),
    ),
  );
}

List<_PlaylistSongEntry> _sortPlaylistEntries(
  List<Song> songs,
  SongSortOption option,
) {
  final entries = List<_PlaylistSongEntry>.generate(
    songs.length,
    (index) => _PlaylistSongEntry(song: songs[index], originalIndex: index),
    growable: false,
  );
  if (option == SongSortOption.defaultOrder || entries.length < 2) {
    return entries;
  }

  final pinyinOf = createSharedPinyinResolver();
  entries.sort((left, right) {
    final comparison =
        compareSongsForSortCached(left.song, right.song, option, pinyinOf);
    return comparison == 0
        ? left.originalIndex.compareTo(right.originalIndex)
        : comparison;
  });
  return entries;
}

class _PlaylistSelectionBar extends StatelessWidget {
  const _PlaylistSelectionBar({
    required this.selectedCount,
    required this.removing,
    required this.onRemove,
  });

  final int selectedCount;
  final bool removing;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final count = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('从当前歌单移除', style: context.musicFlowTypography.title),
        SizedBox(height: context.musicFlowSpacing.xxs),
        Text(
          '已选择 $selectedCount 首，不会删除音乐文件',
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.muted,
          ),
        ),
      ],
    );

    MusicFlowButton removeButton({required bool expand}) => MusicFlowButton.destructive(
      label: removing ? '移除中…' : '移除选中',
      semanticLabel: '移除选中歌曲',
      leadingIcon: AppIcons.removeCircle,
      expand: expand,
      onPressed: removing ? null : onRemove,
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
                removeButton(expand: true),
              ],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(child: count),
              SizedBox(width: context.musicFlowSpacing.md),
              removeButton(expand: false),
            ],
          );
        },
      ),
    );
  }
}

class _PlaylistIdentityHeader extends StatelessWidget {
  const _PlaylistIdentityHeader({
    required this.playlist,
    required this.songCount,
    this.isNowPlaying = false,
  });

  final Playlist playlist;
  final int songCount;

  /// 该歌单是否正在播放：封面右下角叠加半透明遮罩 + 白色跳动竖条。
  final bool isNowPlaying;

  @override
  Widget build(BuildContext context) {
    final comment = playlist.comment?.trim();

    return MediaDetailHeaderSurface(
      coverArtId: playlist.coverArt,
      child: Padding(
        padding: EdgeInsets.all(context.musicFlowSpacing.lg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 680;
            final cover = SizedBox.square(
              dimension: wide ? 176 : 120,
              child: MediaDetailArtwork(
                coverArtId: playlist.coverArt,
                semanticLabel: '${playlist.name} 封面',
                heroTag: 'playlist-cover-${playlist.id}',
                requestSize: 480,
                isNowPlaying: isNowPlaying,
              ),
            );
            final information = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    playlist.name,
                    style: context.musicFlowTypography.display,
                  ),
                ),
                if (comment != null && comment.isNotEmpty) ...<Widget>[
                  SizedBox(height: context.musicFlowSpacing.xs),
                  Text(comment, style: context.musicFlowTypography.body),
                ],
                SizedBox(height: context.musicFlowSpacing.sm),
                Wrap(
                  spacing: context.musicFlowSpacing.xs,
                  runSpacing: context.musicFlowSpacing.xxs,
                  children: <Widget>[
                    Text(
                      '$songCount 首',
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                    Text(
                      playlist.durationString,
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                    Text(
                      playlist.public ? '公开歌单' : '私人歌单',
                      style: context.musicFlowTypography.metadata.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ],
                ),
              ],
            );

            if (!wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  cover,
                  SizedBox(width: context.musicFlowSpacing.md),
                  Expanded(child: information),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                cover,
                SizedBox(width: context.musicFlowSpacing.xl),
                Expanded(child: information),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 歌单详情加载中的占位预览：利用列表传入的预加载数据立即展示封面+标题，
/// 避免用户点击后看到白屏 loading spinner。
class _PlaylistLoadingPreview extends StatelessWidget {
  const _PlaylistLoadingPreview({
    required this.name,
    required this.songCount,
    this.coverArt,
  });

  final String name;
  final int songCount;
  final String? coverArt;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: MediaDetailHeaderSurface(
                coverArtId: coverArt,
                child: Padding(
                  padding: EdgeInsets.all(context.musicFlowSpacing.lg),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox.square(
                        dimension: 120,
                        child: MediaDetailArtwork(
                          coverArtId: coverArt,
                          semanticLabel: '$name 封面',
                          heroTag: 'playlist-cover-$name',
                          requestSize: 480,
                        ),
                      ),
                      SizedBox(width: context.musicFlowSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(name, style: context.musicFlowTypography.display),
                            SizedBox(height: context.musicFlowSpacing.sm),
                            Text(
                              '$songCount 首',
                              style: context.musicFlowTypography.metadata.copyWith(
                                color: context.musicFlowColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
