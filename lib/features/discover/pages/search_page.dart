import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/album.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/search.dart';
import '../../../data/models/search_history.dart';
import '../../../data/models/song.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../widgets/song_list_item.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../library/pages/album_detail_page.dart';
import '../../library/pages/artist_detail_page.dart';
import '../../library/pages/playlist_detail_page.dart';
import '../../library/widgets/library_collection_components.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../../../widgets/windows_title_bar.dart'
    show isWindowsDesktop, kWindowsWindowControlsWidth;
import '../../search/local_search_providers.dart';
import '../../search/search_history.dart';
import '../../search/search_scope.dart';
import '../../search/widgets/search_result_card.dart';
import '../../search/widgets/search_scope_picker.dart';
import '../../discover/widgets/discover_media_widgets.dart';

/// 搜索页。
///
/// 交互(方案 A):进入即聚焦输入框并浮出「搜索范围」浮层;浮层浮出时
/// 输入框**仍可输入**,用户可以直接打字,无需先选范围;一旦输入了关键词
/// 浮层自动收起让位给结果,清空后重新浮出。
///
/// 结果沿用「本地结果 + 全网结果」聚合模式:
/// - 本地结果:本地库按关键词匹配,按 歌单 → 歌曲 → 专辑 → 艺术家 堆叠;
/// - 全网结果:已启用插件的合并搜索(卡片带插件·平台标签)。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    this.initialQuery = '',
    this.initialScope = SearchScope.all,
  });

  /// 首页带入的初始关键词(非空时直接出结果,不再浮出范围浮层)。
  final String initialQuery;

  /// 首页带入的初始搜索范围。
  final SearchScope initialScope;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  static const Duration _searchDebounce = Duration(milliseconds: 450);

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'search_page_query');
  Timer? _searchTimer;
  String _draftQuery = '';
  String _query = '';
  late SearchScope _scope;

  /// 范围浮层是否可见。进入页面(且无初始关键词)时浮出。
  bool _overlayVisible = true;

  @override
  void initState() {
    super.initState();
    _scope = widget.initialScope;
    final initial = widget.initialQuery.trim();
    if (initial.isNotEmpty) {
      _searchController.text = initial;
      _draftQuery = initial;
      _query = initial;
      _overlayVisible = false;
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _searchTimer?.cancel();
    _searchTimer = null;

    final query = value.trim();
    if (_draftQuery != query) {
      setState(() => _draftQuery = query);
    }
    if (query.isEmpty) {
      // 清空:回到「选范围 / 热门 / 历史」态,浮层重新浮出。
      setState(() => _overlayVisible = true);
      _commitSearch('');
      return;
    }
    // 已输入关键词:收起浮层,让结果可见(输入框保持可继续输入)。
    if (_overlayVisible) setState(() => _overlayVisible = false);
    if (query == _query) return;

    _searchTimer = Timer(_searchDebounce, () {
      _searchTimer = null;
      if (!mounted) return;
      _commitSearch(query);
    });
  }

  void _submitSearch(String value) {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchFocusNode.unfocus();
    setState(() => _overlayVisible = false);
    _commitSearch(value);
  }

  void _commitSearch(String value) {
    final query = value.trim();
    if (_query == query && _draftQuery == query) return;
    setState(() {
      _draftQuery = query;
      _query = query;
    });
    if (query.isNotEmpty) {
      unawaited(ref.read(searchHistoryProvider.notifier).record(query));
    }
  }

  void _clearSearch() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchController.clear();
    setState(() => _overlayVisible = true);
    _commitSearch('');
    _searchFocusNode.requestFocus();
  }

  /// 点击热门词/历史词:直接以该词搜索。
  void _runTerm(String term) {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchController.text = term;
    _searchFocusNode.unfocus();
    setState(() => _overlayVisible = false);
    _commitSearch(term);
  }

  void _onScopeChanged(SearchScope scope) {
    setState(() {
      _scope = scope;
      _overlayVisible = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final horizontal = context.musicFlowPageHorizontalPadding;

    return VisibleRemoteRetryScope(
      branchIndex: discoverBranchIndex,
      debugLabel: 'search_page',
      shouldRetry: (ref) => _hasNetworkError(ref),
      onRetry: (ref) {
        for (final scope in _scope.stackedScopes) {
          final kind = scope.kind;
          if (kind == null) continue;
          ref.invalidate(
            searchResultsProvider(
              SearchRequest(
                kind: kind,
                mode: SearchMode.aggregate,
                query: _query,
                providerId: '',
              ),
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: context.musicFlowColors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontal,
                  spacing.sm,
                  // Windows 无系统标题栏:右上角是窗口控制按钮,输入框右侧
                  // 留出等宽空白,避免被按钮压住。
                  horizontal + (isWindowsDesktop ? kWindowsWindowControlsWidth : 0),
                  0,
                ),
                child: Row(
                  children: <Widget>[
                    MusicFlowIconButton(
                      icon: AppIcons.back,
                      label: '返回',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    SizedBox(width: spacing.xs),
                    Expanded(child: _buildTextField()),
                  ],
                ),
              ),
              SizedBox(height: spacing.xs),
              SearchScopeTabs(value: _scope, onChanged: _onScopeChanged),
              SizedBox(height: spacing.xxs),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    if (_query.isEmpty)
                      _buildDiscovery()
                    else
                      _buildResults(),
                    if (_overlayVisible && _query.isEmpty) _buildOverlay(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasNetworkError(WidgetRef ref) {
    if (_query.isEmpty) return false;
    for (final scope in _scope.stackedScopes) {
      final kind = scope.kind;
      if (kind == null) continue;
      final async = ref.read(
        searchResultsProvider(
          SearchRequest(
            kind: kind,
            mode: SearchMode.aggregate,
            query: _query,
            providerId: '',
          ),
        ),
      );
      if (async.hasError) return true;
    }
    return false;
  }

  Widget _buildTextField() {
    final colors = context.musicFlowColors;
    return SizedBox(
      height: 48,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, child) {
          return TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            onSubmitted: _submitSearch,
            onTap: () {
              // 空词时点回输入框:重新浮出范围选择。
              if (!_overlayVisible && value.text.trim().isEmpty) {
                setState(() => _overlayVisible = true);
              }
            },
            decoration: InputDecoration(
              hintText: '搜索歌曲、歌单、艺术家、专辑',
              hintStyle: context.musicFlowTypography.body.copyWith(
                color: colors.muted,
              ),
              prefixIcon: Icon(
                AppIcons.search,
                size: 20,
                color: colors.muted,
              ),
              suffixIcon: value.text.isEmpty
                  ? null
                  : MusicFlowIconButton(
                      icon: AppIcons.close,
                      label: '清空搜索',
                      iconSize: 18,
                      onPressed: _clearSearch,
                    ),
              isDense: true,
              filled: true,
              fillColor: colors.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: context.musicFlowRadii.pill,
                borderSide: BorderSide(color: colors.controlBoundary),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: context.musicFlowRadii.pill,
                borderSide: BorderSide(color: colors.controlBoundary),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: context.musicFlowRadii.pill,
                borderSide: BorderSide(color: colors.accent),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 范围浮层:无遮罩下拉,锚定在输入框下方,点面板外任意处收起。
  ///
  /// 不用全屏 scrim:浮层下方就是热门搜索/搜索历史,需要保持可见可点
  /// (进入页面即直接带出,与首页示意图一致);遮罩会把它们挡住并拦截点击。
  Widget _buildOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Semantics(
        label: '搜索范围浮层',
        child: TapRegion(
          onTapOutside: (_) {
            if (!_overlayVisible) return;
            setState(() => _overlayVisible = false);
          },
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: context.musicFlowSpacing.xs),
              child: SearchScopePanel(
                value: _scope,
                onChanged: _onScopeChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 未输入关键词时:热门搜索 + 搜索历史。
  Widget _buildDiscovery() {
    final spacing = context.musicFlowSpacing;
    return ListView(
      key: const ValueKey<String>('search_discovery'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        spacing.xs,
        context.musicFlowPageHorizontalPadding,
        spacing.xxl + context.musicFlowShellBottomObstruction,
      ),
      children: <Widget>[
        _HotSearchBlock(onTap: _runTerm),
        SizedBox(height: spacing.lg),
        _SearchHistoryBlock(onTap: _runTerm),
      ],
    );
  }

  /// 已提交关键词:本地结果 → 分隔线 → 全网结果。
  Widget _buildResults() {
    final spacing = context.musicFlowSpacing;
    return ListView(
      key: const ValueKey<String>('search_results_list'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        0,
        spacing.xs,
        0,
        context.musicFlowShellBottomObstruction,
      ),
      children: <Widget>[
        Semantics(
          container: true,
          liveRegion: true,
          label: '正在显示“$_query”的结果',
          child: const SizedBox.shrink(),
        ),
        _LocalResultsBlock(scope: _scope, query: _query),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowPageHorizontalPadding,
            vertical: spacing.md,
          ),
          child: const Divider(height: 1),
        ),
        _NetworkResultsBlock(scope: _scope, query: _query),
      ],
    );
  }
}

/// 区块标题(本地结果 / 全网结果)。
class _BlockHeader extends StatelessWidget {
  const _BlockHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: context.musicFlowTypography.title.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
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

/// 分组小标题(歌单 / 歌曲 / 专辑 / 艺术家)+ 条数。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.sm,
        context.musicFlowPageHorizontalPadding,
        context.musicFlowSpacing.xxs,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: context.musicFlowTypography.label.copyWith(
                color: context.musicFlowColors.accent,
              ),
            ),
          ),
          if (count != null)
            Text(
              '$count 项',
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
        ],
      ),
    );
  }
}

/// 本地结果区块:按 歌单 → 歌曲 → 专辑 → 艺术家 分组堆叠。
class _LocalResultsBlock extends ConsumerWidget {
  const _LocalResultsBlock({required this.scope, required this.query});

  final SearchScope scope;
  final String query;

  bool _hasData(WidgetRef ref, SearchScope item) => switch (item) {
        SearchScope.song =>
          (ref.watch(localSongSearchProvider(query)).valueOrNull?.items ??
                  const <Song>[])
              .isNotEmpty,
        SearchScope.album =>
          (ref.watch(localAlbumSearchProvider(query)).valueOrNull?.items ??
                  const <Album>[])
              .isNotEmpty,
        SearchScope.artist =>
          (ref.watch(localArtistSearchProvider(query)).valueOrNull?.items ??
                  const <Artist>[])
              .isNotEmpty,
        SearchScope.playlist =>
          (ref.watch(localPlaylistSearchProvider(query)).valueOrNull?.items ??
                  const <Playlist>[])
              .isNotEmpty,
        SearchScope.all => false,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scopes = scope.stackedScopes;
    final hasAny = scopes.any((item) => _hasData(ref, item));
    final isLoading = scopes.any((item) => _isLoading(ref, item));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _BlockHeader(title: '本地结果', subtitle: '当前音乐库'),
        for (final item in scopes)
          KeyedSubtree(
            key: ValueKey<String>('local-group-${item.name}'),
            child: _LocalGroup(scope: item, query: query),
          ),
        if (!hasAny)
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowPageHorizontalPadding,
              isLoading ? 0 : context.musicFlowSpacing.xs,
              context.musicFlowPageHorizontalPadding,
              context.musicFlowSpacing.xs,
            ),
            child: isLoading
                ? const MusicFlowMediaListSkeleton(count: 3)
                : Text(
                    '本地没有找到相关结果',
                    style: context.musicFlowTypography.metadata.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
          ),
      ],
    );
  }

  bool _isLoading(WidgetRef ref, SearchScope item) => switch (item) {
        SearchScope.song =>
          ref.watch(localSongSearchProvider(query)).isLoading,
        SearchScope.album =>
          ref.watch(localAlbumSearchProvider(query)).isLoading,
        SearchScope.artist =>
          ref.watch(localArtistSearchProvider(query)).isLoading,
        SearchScope.playlist =>
          ref.watch(localPlaylistSearchProvider(query)).isLoading,
        SearchScope.all => false,
      };
}

/// 单个本地分组(按类型渲染)。
class _LocalGroup extends ConsumerWidget {
  const _LocalGroup({required this.scope, required this.query});

  final SearchScope scope;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (scope) {
      SearchScope.song => _songs(context, ref),
      SearchScope.album => _albums(context, ref),
      SearchScope.artist => _artists(context, ref),
      SearchScope.playlist => _playlists(context, ref),
      SearchScope.all => const SizedBox.shrink(),
    };
  }

  Widget _songs(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localSongSearchProvider(query));
    final songs = async.valueOrNull?.items ?? const <Song>[];
    if (songs.isEmpty) return const SizedBox.shrink();
    final currentSongId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _GroupHeader(title: '歌曲', count: async.valueOrNull?.total),
        for (var index = 0; index < songs.length; index++)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
            ),
            child: MusicFlowSongRow(
              song: songs[index],
              index: index,
              isCurrent: songs[index].id == currentSongId,
              onPressed: () =>
                  playEffectiveQueue(ref, songs, startIndex: index),
              onLongPress: () =>
                  showSongOptionsSheet(context: context, song: songs[index]),
              onMorePressed: () =>
                  showSongOptionsSheet(context: context, song: songs[index]),
            ),
          ),
      ],
    );
  }

  Widget _albums(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localAlbumSearchProvider(query));
    final albums = async.valueOrNull?.items ?? const <Album>[];
    if (albums.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _GroupHeader(title: '专辑', count: async.valueOrNull?.total),
        for (final album in albums)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
              vertical: context.musicFlowSpacing.xxs,
            ),
            child: MusicFlowAlbumRow(
              album: album,
              onPressed: () => Navigator.of(context).push<void>(
                MusicFlowPageRoute<void>(
                  context: context,
                  builder: (context) => AlbumDetailPage(albumId: album.id),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _artists(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localArtistSearchProvider(query));
    final artists = async.valueOrNull?.items ?? const <Artist>[];
    if (artists.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _GroupHeader(title: '艺术家', count: async.valueOrNull?.total),
        for (final artist in artists)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
              vertical: context.musicFlowSpacing.xxs,
            ),
            child: MusicFlowArtistRow(
              artist: artist,
              onPressed: () => Navigator.of(context).push<void>(
                MusicFlowPageRoute<void>(
                  context: context,
                  builder: (context) => ArtistDetailPage(artistId: artist.id),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _playlists(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localPlaylistSearchProvider(query));
    final playlists = async.valueOrNull?.items ?? const <Playlist>[];
    if (playlists.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _GroupHeader(title: '歌单', count: async.valueOrNull?.total),
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.musicFlowPageHorizontalPadding,
            context.musicFlowSpacing.xs,
            context.musicFlowPageHorizontalPadding,
            0,
          ),
          child: Wrap(
            spacing: context.musicFlowSpacing.sm,
            runSpacing: context.musicFlowSpacing.sm,
            children: <Widget>[
              for (final playlist in playlists)
                DiscoverPlaylistCard(
                  width: 128,
                  title: playlist.name,
                  subtitle: '${playlist.songCount} 首',
                  coverArtId: playlist.coverArt,
                  onPressed: () => Navigator.of(context).push<void>(
                    MusicFlowPageRoute<void>(
                      context: context,
                      builder: (context) => PlaylistDetailPage(
                        playlistId: playlist.id,
                        initialName: playlist.name,
                        initialSongCount: playlist.songCount,
                        initialCoverArt: playlist.coverArt,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 全网结果区块:已启用插件的合并搜索,按类型分组堆叠。
class _NetworkResultsBlock extends ConsumerWidget {
  const _NetworkResultsBlock({required this.scope, required this.query});

  final SearchScope scope;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scopes = scope.stackedScopes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _BlockHeader(
          title: '全网结果',
          subtitle: '已启用插件的合并搜索,卡片带插件·平台标签',
        ),
        for (var i = 0; i < scopes.length; i++)
          KeyedSubtree(
            key: ValueKey<String>('network-group-${scopes[i].name}'),
            child: _NetworkGroup(
              scope: scopes[i],
              query: query,
              includeBottomPadding: i == scopes.length - 1,
            ),
          ),
      ],
    );
  }
}

class _NetworkGroup extends ConsumerWidget {
  const _NetworkGroup({
    required this.scope,
    required this.query,
    required this.includeBottomPadding,
  });

  final SearchScope scope;
  final String query;
  final bool includeBottomPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = scope.kind;
    if (kind == null) return const SizedBox.shrink();
    final request = SearchRequest(
      kind: kind,
      mode: SearchMode.aggregate,
      query: query,
      providerId: '',
    );
    final async = ref.watch(searchResultsProvider(request));

    return async.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
        ),
        child: const MusicFlowMediaListSkeleton(count: 3),
      ),
      error: (error, stackTrace) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Text(
          '${scope.sectionTitle}搜索失败,可下拉重试',
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.muted,
          ),
        ),
      ),
      data: (outcome) {
        if (outcome.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _GroupHeader(title: scope.sectionTitle),
            SearchResultList(
              kind: kind,
              outcome: outcome,
              includeBottomPadding: includeBottomPadding,
            ),
          ],
        );
      },
    );
  }
}

/// 热门搜索(本地兜底:来自收藏的艺术家/专辑名)。
class _HotSearchBlock extends ConsumerWidget {
  const _HotSearchBlock({required this.onTap});

  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(hotSearchTermsProvider);
    final terms = async.valueOrNull ?? const <String>[];
    if (terms.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _BlockHeader(title: '热门搜索'),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowPageHorizontalPadding,
          ),
          child: _TermWrap(terms: terms, onTap: onTap),
        ),
      ],
    );
  }
}

/// 搜索历史(持久化,支持单条删除与清空)。
class _SearchHistoryBlock extends ConsumerWidget {
  const _SearchHistoryBlock({required this.onTap});

  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(searchHistoryProvider);
    final entries = async.valueOrNull ?? const <SearchHistoryEntry>[];
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.musicFlowPageHorizontalPadding,
            context.musicFlowSpacing.xs,
            context.musicFlowPageHorizontalPadding - 5,
            context.musicFlowSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              Expanded(child: const _BlockHeader(title: '搜索历史')),
              MusicFlowIconButton(
                icon: AppIcons.delete,
                label: '清空搜索历史',
                iconSize: 20,
                onPressed: () =>
                    ref.read(searchHistoryProvider.notifier).clear(),
              ),
            ],
          ),
        ),
        for (final entry in entries)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowPageHorizontalPadding,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  AppIcons.history,
                  size: 18,
                  color: context.musicFlowColors.muted,
                ),
                SizedBox(width: context.musicFlowSpacing.sm),
                Expanded(
                  child: MusicFlowPressable(
                    semanticLabel: '搜索 ${entry.query}',
                    onPressed: () => onTap(entry.query),
                    minimumSize: const Size.fromHeight(44),
                    borderRadius: context.musicFlowRadii.detail,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        entry.query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.body,
                      ),
                    ),
                  ),
                ),
                MusicFlowIconButton(
                  icon: AppIcons.close,
                  label: '删除历史 ${entry.query}',
                  iconSize: 18,
                  onPressed: () => ref
                      .read(searchHistoryProvider.notifier)
                      .remove(entry.query),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 关键词 chip 云（热门搜索）。
class _TermWrap extends StatelessWidget {
  const _TermWrap({required this.terms, required this.onTap});

  final List<String> terms;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    return Wrap(
      spacing: spacing.xs,
      runSpacing: spacing.xs,
      children: <Widget>[
        for (final term in terms)
          MusicFlowPressable(
            semanticLabel: '搜索 $term',
            onPressed: () => onTap(term),
            borderRadius: context.musicFlowRadii.pill,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: context.musicFlowRadii.pill,
                border: Border.all(color: colors.controlBoundary, width: 0.5),
              ),
              child: Text(term, style: context.musicFlowTypography.body),
            ),
          ),
      ],
    );
  }
}
