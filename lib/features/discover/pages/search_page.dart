import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/features/discover/widgets/search_result_blocks.dart';
import 'package:musicflow_client/features/discover/widgets/search_aux_blocks.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/widgets/visible_remote_retry_scope.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show isWindowsDesktop, kWindowsWindowControlsWidth;
import 'package:musicflow_client/features/search/search_history.dart';
import 'package:musicflow_client/features/search/search_scope.dart';
import 'package:musicflow_client/features/search/widgets/search_scope_picker.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

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
    final loc = AppLocalizations.of(context);
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
                      label: loc.search_back,
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
    final loc = AppLocalizations.of(context);
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
              hintText: loc.search_hint,
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
                      label: loc.search_clear,
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
    final loc = AppLocalizations.of(context);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Semantics(
        label: loc.search_scope_overlay,
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
        HotSearchBlock(onTap: _runTerm),
        SizedBox(height: spacing.lg),
        SearchHistoryBlock(onTap: _runTerm),
      ],
    );
  }

  /// 已提交关键词:本地结果 → 分隔线 → 全网结果。
  Widget _buildResults() {
    final loc = AppLocalizations.of(context);
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
          label: loc.search_showing_results(_query),
          child: const SizedBox.shrink(),
        ),
        LocalResultsBlock(scope: _scope, query: _query),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowPageHorizontalPadding,
            vertical: spacing.md,
          ),
          child: const Divider(height: 1),
        ),
        NetworkResultsBlock(scope: _scope, query: _query),
      ],
    );
  }
}


