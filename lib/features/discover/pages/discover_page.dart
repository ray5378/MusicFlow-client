import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:remixicon/remixicon.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/recommend.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/recommend_provider.dart';
import '../../../widgets/main_scaffold.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../explore/pages/explore_page.dart';
import '../../library/pages/album_list_page.dart';
import '../../library/pages/artist_list_page.dart';
import '../../library/pages/playlist_detail_page.dart';
import '../../library/pages/playlist_search_page.dart';
import '../../library/pages/song_list_page.dart';
import '../../library/pages/starred_page.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../widgets/discover_media_widgets.dart';
import 'search_page.dart';

const double _playlistCardWidth = 152;

/// 音乐流首页 - Tab 1
class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  Future<void> _refresh() async {
    await Future.wait<Object?>(<Future<Object?>>[
      ref.refresh(randomSongsProvider.future),
      ref.refresh(playlistsProvider.future),
      ref.refresh(recentPlaylistsProvider.future),
      ref.refresh(homeCardsProvider.future),
      ref.refresh(recommendChannelsProvider.future),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final randomSongsLoadFailed = ref.watch(randomSongsLoadFailedProvider);
    final homeCardsFailed = ref.watch(homeCardsLoadFailedProvider);
    final recommendFailed = ref.watch(recommendChannelsLoadFailedProvider);
    final recentFailed = ref.watch(recentPlaylistsLoadFailedProvider);

    return VisibleRemoteRetryScope(
      branchIndex: discoverBranchIndex,
      debugLabel: 'discover_page',
      shouldRetry: (ref) =>
          randomSongsLoadFailed ||
          ref.read(randomSongsProvider).hasError ||
          ref.read(playlistsProvider).hasError ||
          homeCardsFailed ||
          ref.read(homeCardsProvider).hasError ||
          recommendFailed ||
          ref.read(recommendChannelsProvider).hasError ||
          recentFailed ||
          ref.read(recentPlaylistsProvider).hasError,
      onRetry: (ref) {
        ref.invalidate(randomSongsProvider);
        ref.invalidate(playlistsProvider);
        ref.invalidate(recentPlaylistsProvider);
        ref.invalidate(homeCardsProvider);
        ref.invalidate(recommendChannelsProvider);
      },
      child: Scaffold(
        backgroundColor: context.echoColors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              EchoPageHeader(
                title: '音乐流',
                leading: shouldShowPageDrawerTrigger(context)
                    ? EchoIconButton(
                        icon: AppIcons.menu,
                        label: '打开应用菜单',
                        onPressed: openEchoAppDrawer,
                      )
                    : null,
                trailing: EchoIconButton(
                  icon: AppIcons.search,
                  label: '搜索音乐库',
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      EchoPageRoute<void>(
                        context: context,
                        builder: (context) => const SearchPage(),
                      ),
                    );
                  },
                ),
              ),
              const CategoryNavBar(),
              Expanded(
                child: EchoRefreshView(
                  onRefresh: _refresh,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1400),
                      child: ListView(
                        cacheExtent: 1500,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          context.echoPageHorizontalPadding,
                          context.echoSpacing.xs,
                          context.echoPageHorizontalPadding,
                          context.echoSpacing.xxl +
                              context.echoShellBottomObstruction,
                        ),
                        children: <Widget>[
                          const RandomSongsSection(),
                          SizedBox(height: context.echoSpacing.xl),
                          const RecentPlaylistsSection(),
                          SizedBox(height: context.echoSpacing.xl),
                          const FixedRecommendSection(),
                          SizedBox(height: context.echoSpacing.xl),
                          const PlatformRecommendSection(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部分类导航条(可左右滑动):艺术家/专辑/歌曲/歌单/喜爱/风格
class CategoryNavBar extends StatelessWidget {
  const CategoryNavBar({super.key});

  static final List<(String, IconData, Widget)> _items = <(String, IconData, Widget)>[
    ('艺术家', AppIcons.profile, const ArtistListPage()),
    ('专辑', AppIcons.album, const AlbumListPage()),
    ('歌曲', AppIcons.music, const SongListPage()),
    ('歌单', AppIcons.playlist, const PlaylistSearchPage()),
    ('喜爱', AppIcons.heart, const StarredPage()),
    ('风格', Remix.price_tag_3_line, const ExplorePage()),
  ];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '分类导航',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: context.echoPageHorizontalPadding,
          vertical: context.echoSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            for (var i = 0; i < _items.length; i++) ...<Widget>[
              if (i > 0)
                SizedBox(width: context.echoSpacing.md),
              _CategoryNavItem(
                label: _items[i].$1,
                icon: _items[i].$2,
                onPressed: () {
                  Navigator.of(context).push<void>(
                    EchoPageRoute<void>(
                      context: context,
                      builder: (context) => _items[i].$3,
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryNavItem extends StatelessWidget {
  const _CategoryNavItem({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: EchoPressable(
        onPressed: onPressed,
        minimumSize: const Size(64, 64),
        borderRadius: context.echoRadii.surface,
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 26, color: context.echoColors.accent),
              SizedBox(height: context.echoSpacing.xxs),
              Text(
                label,
                style: context.echoTypography.metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 随机歌曲模块:标题旁刷新按钮 + 右侧播放按钮;每轮 20 首,
/// 一轮内不重复,播完自动换下一轮。
class RandomSongsSection extends ConsumerStatefulWidget {
  const RandomSongsSection({super.key});

  @override
  ConsumerState<RandomSongsSection> createState() => _RandomSongsSectionState();
}

class _RandomSongsSectionState extends ConsumerState<RandomSongsSection> {
  bool _autoContinue = false;
  int _roundToken = 0;

  Future<void> _playRound() async {
    final songs = ref.read(randomSongsProvider).valueOrNull;
    if (songs == null || songs.isEmpty) return;
    _autoContinue = true;
    _roundToken++;
    await ref.read(playerProvider.notifier).playQueue(songs);
  }

  Future<void> _loadNextRound() async {
    final token = ++_roundToken;
    final songs = await ref.refresh(randomSongsProvider.future);
    if (!mounted || token != _roundToken || !_autoContinue) return;
    if (songs.isEmpty) return;
    await ref.read(playerProvider.notifier).playQueue(songs);
  }

  void _refresh() {
    _autoContinue = false;
    _roundToken++;
    ref.invalidate(randomSongsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final randomSongsAsync = ref.watch(randomSongsProvider);
    final loadFailed = ref.watch(randomSongsLoadFailedProvider);

    // 一轮(20 首)播完自动换下一轮
    ref.listen<PlayerState>(playerProvider, (prev, next) {
      if (!_autoContinue) return;
      final queue = next.queue;
      if (queue.isEmpty) return;
      if (next.processingState == ProcessingState.completed &&
          next.currentIndex == queue.length - 1) {
        unawaited(_loadNextRound());
      }
    });

    final content = randomSongsAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      data: (songs) {
        if (songs.isEmpty) {
          return DiscoverSectionMessage(
            title: loadFailed ? '随心听暂时不可用' : '还没有可播放的歌曲',
            description: loadFailed
                ? '请检查网络或当前线路，然后重试。'
                : '音乐库中有歌曲后，这里会准备一组随心选择。',
            icon: loadFailed ? AppIcons.cloudOff : AppIcons.music,
            onRetry: loadFailed
                ? () => ref.invalidate(randomSongsProvider)
                : null,
          );
        }

        final itemWidth =
            (MediaQuery.sizeOf(context).width * 0.72).clamp(260.0, 360.0);

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: context.echoPageHorizontalPadding,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var col = 0; col < (songs.length / 3).ceil(); col++)
                Padding(
                  padding: EdgeInsets.only(right: context.echoSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (var row = 0;
                          row < 3 && col * 3 + row < songs.length;
                          row++) ...<Widget>[
                        SizedBox(
                          width: itemWidth,
                          child: DiscoverSongTile(
                            song: songs[col * 3 + row],
                            onPressed: () {
                              ref
                                  .read(playerProvider.notifier)
                                  .playQueue(songs, startIndex: col * 3 + row);
                            },
                            onOpenActions: () => showSongOptionsSheet(
                              context: context,
                              song: songs[col * 3 + row],
                            ),
                          ),
                        ),
                        if (row < 2) SizedBox(height: context.echoSpacing.xxs),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
      loading: () => const DiscoverSongLoading(count: 5),
      error: (error, stackTrace) => DiscoverSectionMessage(
        title: '随心听加载失败',
        description: '请检查网络或切换线路后重试。',
        icon: AppIcons.cloudOff,
        onRetry: () => ref.invalidate(randomSongsProvider),
      ),
    );

    return DecoratedBox(
      key: const Key('discover-random-mix'),
      decoration: BoxDecoration(
        color: context.echoColors.surface,
        borderRadius: context.echoRadii.surface,
        border: Border.all(color: context.echoColors.divider),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.echoSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            EchoSectionHeader(
              title: '随机歌曲',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  EchoIconButton(
                    icon: AppIcons.refresh,
                    label: '换一批随机歌曲',
                    onPressed: _refresh,
                  ),
                  SizedBox(width: context.echoSpacing.xs),
                  EchoIconButton(
                    icon: AppIcons.play,
                    label: '播放随机歌曲',
                    onPressed: _playRound,
                  ),
                ],
              ),
            ),
            SizedBox(height: context.echoSpacing.md),
            content,
          ],
        ),
      ),
    );
  }
}

/// 最近更新的歌单(横滑卡片行)
class RecentPlaylistsSection extends ConsumerWidget {
  const RecentPlaylistsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(recentPlaylistsProvider);
    final loadFailed = ref.watch(recentPlaylistsLoadFailedProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        EchoSectionHeader(
          title: '最近更新的歌单',
          trailing: EchoIconButton(
            icon: AppIcons.refresh,
            label: '刷新最近更新歌单',
            onPressed: () => ref.invalidate(recentPlaylistsProvider),
          ),
        ),
        SizedBox(height: context.echoSpacing.xs),
        playlistsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (playlists) {
            if (playlists.isEmpty) {
              return DiscoverSectionMessage(
                title: loadFailed ? '歌单暂时不可用' : '暂无歌单',
                description: loadFailed
                    ? '请检查网络或当前线路，然后重试。'
                    : '创建或导入歌单后，这里会显示最近更新的内容。',
                icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
                onRetry: loadFailed
                    ? () => ref.invalidate(recentPlaylistsProvider)
                    : null,
              );
            }
            return SizedBox(
              height: _playlistCardWidth + 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                  horizontal: context.echoPageHorizontalPadding,
                ),
                itemCount: playlists.length,
                separatorBuilder: (context, index) =>
                    SizedBox(width: context.echoSpacing.sm),
                itemBuilder: (context, index) {
                  final pl = playlists[index];
                  return DiscoverPlaylistCard(
                    width: _playlistCardWidth,
                    title: pl.name,
                    subtitle: '${pl.songCount} 首',
                    coverArtId: pl.coverArt,
                    onPressed: () {
                      Navigator.of(context).push<void>(
                        EchoPageRoute<void>(
                          context: context,
                          builder: (context) =>
                              PlaylistDetailPage(playlistId: pl.id),
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
          loading: () => SizedBox(
            height: _playlistCardWidth + 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: context.echoPageHorizontalPadding,
              ),
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.echoSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: '最近更新歌单加载失败',
            description: '请检查网络或切换线路后重试。',
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(recentPlaylistsProvider),
          ),
        ),
      ],
    );
  }
}

/// 固定推荐歌单(来自主项目插件,如每日推荐/今日漫游/本地推荐),横滑卡片
class FixedRecommendSection extends ConsumerWidget {
  const FixedRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(homeCardsProvider);
    final loadFailed = ref.watch(homeCardsLoadFailedProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        EchoSectionHeader(
          title: '固定推荐',
        ),
        SizedBox(height: context.echoSpacing.xs),
        cardsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (cards) {
            if (cards.isEmpty) {
              return DiscoverSectionMessage(
                title: loadFailed ? '固定推荐暂时不可用' : '暂无固定推荐歌单',
                description: loadFailed
                    ? '请检查网络或当前线路，然后重试。'
                    : '启用推荐插件后，这里会显示每日推荐等歌单。',
                icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
                onRetry: loadFailed
                    ? () => ref.invalidate(homeCardsProvider)
                    : null,
              );
            }
            return SizedBox(
              height: _playlistCardWidth + 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                  horizontal: context.echoPageHorizontalPadding,
                ),
                itemCount: cards.length,
                separatorBuilder: (context, index) =>
                    SizedBox(width: context.echoSpacing.sm),
                itemBuilder: (context, index) {
                  final card = cards[index];
                  return DiscoverPlaylistCard(
                    width: _playlistCardWidth,
                    title: card.playlistName.isNotEmpty
                        ? card.playlistName
                        : card.name,
                    subtitle: '${card.songCount} 首',
                    coverArtId: card.coverArt,
                    onPressed: () {
                      Navigator.of(context).push<void>(
                        EchoPageRoute<void>(
                          context: context,
                          builder: (context) => PlaylistDetailPage(
                            playlistId: card.playlistId,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
          loading: () => SizedBox(
            height: _playlistCardWidth + 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: context.echoPageHorizontalPadding,
              ),
              itemCount: 3,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.echoSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: '固定推荐加载失败',
            description: '请检查网络或切换线路后重试。',
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(homeCardsProvider),
          ),
        ),
      ],
    );
  }
}

/// 打开平台推荐歌单:与主项目一致,先经 /v1/online/:providerId/recommend/import
/// 导入(幂等 upsert)拿到真实 library playlistId,再以本地歌单打开播放。
Future<void> _openRecommendPlaylist(
  BuildContext context,
  WidgetRef ref,
  String? providerId,
  RecommendPlaylist pl,
) async {
  if (providerId == null || providerId.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('推荐服务暂不可用，请检查平台推荐插件是否已启用')),
    );
    return;
  }
  ref.read(recommendImportingProvider.notifier).state = pl.id;
  try {
    final repo = ref.read(recommendRepositoryProvider);
    if (repo == null) throw Exception('未连接到音乐库');
    final playlistId = await repo.importRecommendPlaylist(providerId, <String, dynamic>{
      'source': pl.source,
      'id': pl.id,
      'name': pl.name,
      'cover': pl.cover ?? '',
      'creator': pl.creator,
      'trackCount': pl.trackCount,
      'link': pl.link,
    });
    if (!context.mounted) return;
    Navigator.of(context).push<void>(
      EchoPageRoute<void>(
        context: context,
        builder: (context) => PlaylistDetailPage(playlistId: playlistId),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      final msg = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入歌单失败：$msg')),
      );
    }
  } finally {
    ref.read(recommendImportingProvider.notifier).state = null;
  }
}

/// 不同插件的平台推荐歌单:整体上下滚动不同平台,
/// 同一平台内歌单横向滑动(与网页一致)。
class PlatformRecommendSection extends ConsumerWidget {
  const PlatformRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsAsync = ref.watch(recommendChannelsProvider);
    final loadFailed = ref.watch(recommendChannelsLoadFailedProvider);
    final providerId = ref.watch(recommendProviderIdProvider).valueOrNull;
    final importingId = ref.watch(recommendImportingProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        EchoSectionHeader(
          title: '平台推荐',
        ),
        SizedBox(height: context.echoSpacing.xs),
        channelsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (result) {
            final channels = result.channels;
            final allPlaylists =
                channels.expand((c) => c.playlists).toList();
            if (allPlaylists.isEmpty) {
              return DiscoverSectionMessage(
                title: loadFailed ? '平台推荐暂时不可用' : '暂无平台推荐歌单',
                description: loadFailed
                    ? '请检查网络或当前线路，然后重试。'
                    : '启用平台推荐插件后，这里会显示各平台的精选歌单。',
                icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
                onRetry: loadFailed
                    ? () => ref.invalidate(recommendChannelsProvider)
                    : null,
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final channel in channels) ...<Widget>[
                  if (channels.length > 1) ...<Widget>[
                    SizedBox(height: context.echoSpacing.sm),
                    Text(
                      channel.name,
                      style: context.echoTypography.label.copyWith(
                        color: context.echoColors.accent,
                      ),
                    ),
                    SizedBox(height: context.echoSpacing.xxs),
                  ],
                  if (channel.playlists.isNotEmpty)
                    SizedBox(
                      height: _playlistCardWidth + 56,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.symmetric(
                          horizontal: context.echoPageHorizontalPadding,
                        ),
                        itemCount: channel.playlists.length,
                        separatorBuilder: (context, index) =>
                            SizedBox(width: context.echoSpacing.sm),
                        itemBuilder: (context, index) {
                          final pl = channel.playlists[index];
                          final isImporting = importingId == pl.id;
                          return DiscoverPlaylistCard(
                            width: _playlistCardWidth,
                            title: pl.name,
                            subtitle: pl.trackCount.isNotEmpty
                                ? '${pl.trackCount} 首'
                                : null,
                            coverUrl: pl.cover,
                            loading: isImporting,
                            onPressed: isImporting
                                ? () {}
                                : () => _openRecommendPlaylist(
                                      context,
                                      ref,
                                      providerId,
                                      pl,
                                    ),
                          );
                        },
                      ),
                    ),
                ],
              ],
            );
          },
          loading: () => SizedBox(
            height: _playlistCardWidth + 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: context.echoPageHorizontalPadding,
              ),
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.echoSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: '平台推荐加载失败',
            description: '请检查网络或切换线路后重试。',
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(recommendChannelsProvider),
          ),
        ),
      ],
    );
  }
}
