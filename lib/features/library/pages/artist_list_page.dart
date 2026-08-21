import 'package:azlistview/azlistview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/design/components/echo_page_route.dart';
import '../../../data/models/artist.dart';
import '../../../data/models/search.dart';
import '../../../features/search/widgets/entity_search_bar.dart';
import '../../../features/search/widgets/search_result_card.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../utils/az_item.dart';
import '../../../utils/pinyin_helper.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../widgets/library_collection_components.dart';
import 'artist_detail_page.dart';

/// Alphabetical artist collection with stable A-Z navigation.
class ArtistListPage extends ConsumerStatefulWidget {
  const ArtistListPage({super.key});

  @override
  ConsumerState<ArtistListPage> createState() => _ArtistListPageState();
}

class _ArtistListPageState extends ConsumerState<ArtistListPage> {
  List<AzItem<Artist>> _azArtists = const <AzItem<Artist>>[];
  int _artistsSignature = 0;
  SearchMode _searchMode = SearchMode.aggregate;
  String _searchProviderId = '';
  String _searchQuery = '';

  int _buildSignature(List<Artist> artists) {
    return Object.hashAll(
      artists.map(
        (artist) => Object.hash(
          artist.id,
          artist.name,
          artist.coverArt,
          artist.albumCount,
          artist.starred,
        ),
      ),
    );
  }

  void _processArtists(List<Artist> artists, int signature) {
    final items = artists
        .map((artist) {
          return AzItem<Artist>(
            data: artist,
            tag: PinyinUtils.getFirstChar(artist.name),
            namePinyin: PinyinUtils.getPinyin(artist.name),
          );
        })
        .toList(growable: false);
    SuspensionUtil.sortListBySuspensionTag(items);
    SuspensionUtil.setShowSuspensionStatus(items);
    _azArtists = items;
    _artistsSignature = signature;
  }

  @override
  Widget build(BuildContext context) {
    final artistsAsync = ref.watch(allArtistsProvider);
    final loadFailed = ref.watch(allArtistsLoadFailedProvider);

    return VisibleRemoteRetryScope(
      branchIndex: libraryBranchIndex,
      debugLabel: 'artist_list_page',
      shouldRetry: (ref) => loadFailed || artistsAsync.hasError,
      onRetry: (ref) => ref.invalidate(allArtistsProvider),
      child: EchoScaffold(
        topBar: EchoTopBar.back(
          context: context,
          title: '所有歌手',
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EntitySearchBar(
              kind: SearchEntityKind.artist,
              mode: _searchMode,
              providerId: _searchProviderId,
              query: _searchQuery,
              onSourceChanged: (source) => setState(() {
                _searchMode = source.mode;
                _searchProviderId = source.providerId;
              }),
              onQueryChanged: (query) => setState(() => _searchQuery = query),
            ),
            SizedBox(height: context.echoSpacing.xs),
            Expanded(
              child: _searchBody(artistsAsync, loadFailed),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBody(AsyncValue<List<Artist>> artistsAsync, bool loadFailed) {
    if (_searchQuery.isEmpty) {
      return artistsAsync.when(
        data: (artists) => _localList(artists, loadFailed),
        loading: () => const EchoMediaListSkeleton(circle: true),
        error: (error, stackTrace) => _errorState(),
      );
    }
    if (_searchMode == SearchMode.local) {
      return artistsAsync.when(
        data: (artists) {
          final filtered =
              artists.where((a) => _matches(a, _searchQuery)).toList();
          if (filtered.isEmpty) return _emptyResults();
          final signature = _buildSignature(filtered);
          if (signature != _artistsSignature ||
              _azArtists.length != filtered.length) {
            _processArtists(filtered, signature);
          }
          return _buildArtistCollection(context);
        },
        loading: () => const EchoMediaListSkeleton(circle: true),
        error: (error, stackTrace) => _errorState(),
      );
    }
    final results = ref.watch(
      searchResultsProvider(
        SearchRequest(
          kind: SearchEntityKind.artist,
          mode: _searchMode,
          query: _searchQuery,
          providerId: _searchProviderId,
        ),
      ),
    );
    return results.when(
      data: (outcome) => outcome.artists.isEmpty
          ? _emptyResults()
          : SearchResultList(kind: SearchEntityKind.artist, outcome: outcome),
      loading: () => const EchoMediaListSkeleton(circle: true),
      error: (error, stackTrace) => _errorState(),
    );
  }

  bool _matches(Artist artist, String query) =>
      artist.name.toLowerCase().contains(query.toLowerCase());

  Widget _localList(List<Artist> artists, bool loadFailed) {
    if (artists.isEmpty) {
      if (loadFailed) return _errorState();
      return const EchoEmptyState(
        title: '暂无歌手',
        description: '同步音乐库后，歌手会按名称分组显示在这里。',
        icon: AppIcons.profile,
      );
    }
    final signature = _buildSignature(artists);
    if (signature != _artistsSignature ||
        _azArtists.length != artists.length) {
      _processArtists(artists, signature);
    }
    return _buildArtistCollection(context);
  }

  Widget _buildArtistCollection(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: EchoAzIndexReveal(
          builder: (context, opacity, _) => AzListView(
            key: const ValueKey<String>('artist-list-scroll'),
            data: _azArtists,
            itemCount: _azArtists.length,
            padding: EdgeInsets.only(
              bottom: context.echoSpacing.xxl + context.echoShellBottomObstruction,
            ),
            itemBuilder: (context, index) {
              final item = _azArtists[index];
              final artist = item.data;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (item.isShowSuspension)
                    EchoLibrarySectionLabel(
                      label: item.getSuspensionTag(),
                    ),
                  EchoArtistRow(
                    artist: artist,
                    contentPadding: EdgeInsetsDirectional.fromSTEB(
                      context.echoPageHorizontalPadding,
                      context.echoSpacing.xs,
                      44,
                      context.echoSpacing.xs,
                    ),
                    onPressed: () => Navigator.of(context).push<void>(
                      EchoPageRoute<void>(
                        context: context,
                        builder: (_) => ArtistDetailPage(artistId: artist.id),
                      ),
                    ),
                  ),
                ],
              );
            },
            indexBarData: SuspensionUtil.getTagIndexList(_azArtists),
            indexBarWidth: 24,
            indexBarMargin: EdgeInsetsDirectional.only(
              end: context.echoSpacing.xxs,
            ),
            indexBarOptions: echoIndexBarOptions(
              context,
              opacity: opacity,
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyResults() => const EchoEmptyState(
        title: '未找到结果',
        description: '换个关键词或切换搜索来源试试。',
        icon: AppIcons.search,
      );

  Widget _errorState() => EchoErrorState(
        title: '加载失败',
        description: '请检查网络或服务器状态后重试。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(allArtistsProvider),
      );
}
