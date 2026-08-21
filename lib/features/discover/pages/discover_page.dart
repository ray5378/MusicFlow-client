import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../widgets/main_scaffold.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../library/pages/playlist_detail_page.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../widgets/discover_media_widgets.dart';
import 'search_page.dart';

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
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final randomSongsLoadFailed = ref.watch(randomSongsLoadFailedProvider);

    return VisibleRemoteRetryScope(
      branchIndex: discoverBranchIndex,
      debugLabel: 'discover_page',
      shouldRetry: (ref) =>
          randomSongsLoadFailed ||
          ref.read(randomSongsProvider).hasError ||
          ref.read(playlistsProvider).hasError,
      onRetry: (ref) {
        ref.invalidate(randomSongsProvider);
        ref.invalidate(playlistsProvider);
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
                          const FixedPlaylistsSection(),
                          SizedBox(height: context.echoSpacing.xl),
                          const PlatformPlaylistsSection(),
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

class RandomSongsSection extends ConsumerStatefulWidget {
  const RandomSongsSection({super.key});

  @override
  ConsumerState<RandomSongsSection> createState() => _RandomSongsSectionState();
}

class _RandomSongsSectionState extends ConsumerState<RandomSongsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final randomSongsAsync = ref.watch(randomSongsProvider);
    final loadFailed = ref.watch(randomSongsLoadFailedProvider);
    final loadedSongs = randomSongsAsync.valueOrNull;
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

        final displayCount = _expanded
            ? songs.length
            : (songs.length > 5 ? 5 : songs.length);
        final visibleSongs = songs.take(displayCount).toList(growable: false);

        return LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(1);
            final columns = textScale > 1.3 || constraints.maxWidth < 720
                ? 1
                : 2;
            final gap = context.echoSpacing.md;
            final itemWidth =
                (constraints.maxWidth - gap * (columns - 1)) / columns;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: gap,
                  runSpacing: context.echoSpacing.xxs,
                  children: <Widget>[
                    for (var index = 0; index < visibleSongs.length; index++)
                      SizedBox(
                        width: itemWidth,
                        child: DiscoverSongTile(
                          song: visibleSongs[index],
                          onPressed: () {
                            ref
                                .read(playerProvider.notifier)
                                .playQueue(songs, startIndex: index);
                          },
                          onOpenActions: () => showSongOptionsSheet(
                            context: context,
                            song: visibleSongs[index],
                          ),
                        ),
                      ),
                  ],
                ),
                if (songs.length > 5) ...<Widget>[
                  SizedBox(height: context.echoSpacing.xs),
                  EchoButton.ghost(
                    label: _expanded ? '收起' : '更多歌曲',
                    leadingIcon: _expanded
                        ? AppIcons.chevronUp
                        : AppIcons.chevronDown,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ],
            );
          },
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
              title: '随心听',
              description: '从音乐库随机挑选，点一首即可开始。',
              trailing: EchoButton.primary(
                label: '立即播放',
                semanticLabel: '播放随心听',
                leadingIcon: AppIcons.shuffle,
                onPressed: loadedSongs == null || loadedSongs.isEmpty
                    ? null
                    : () => ref
                          .read(playerProvider.notifier)
                          .playQueue(loadedSongs),
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

/// 固定歌单推荐模块
class FixedPlaylistsSection extends ConsumerWidget {
  const FixedPlaylistsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final loadFailed = ref.watch(playlistsLoadFailedProvider);

    return playlistsAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      data: (playlists) {
        if (playlists.isEmpty) {
          return DiscoverSectionMessage(
            title: loadFailed ? '歌单暂时不可用' : '暂无歌单推荐',
            description: loadFailed
                ? '请检查网络或当前线路，然后重试。'
                : '创建歌单后，可以在这里快速访问。',
            icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
            onRetry: loadFailed
                ? () => ref.invalidate(playlistsProvider)
                : null,
          );
        }

        final fixedPlaylists =
            playlists.where((p) => !p.isImported).toList();

        if (fixedPlaylists.isEmpty) {
          return DiscoverSectionMessage(
            title: loadFailed ? '歌单暂时不可用' : '暂无歌单推荐',
            description: loadFailed
                ? '请检查网络或当前线路，然后重试。'
                : '创建歌单后，可以在这里快速访问。',
            icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
            onRetry: loadFailed ? () => ref.invalidate(playlistsProvider) : null,
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(1);
            final columns = textScale > 1.3 || constraints.maxWidth < 720
                ? 1
                : 2;
            final gap = context.echoSpacing.md;
            final itemWidth =
                (constraints.maxWidth - gap * (columns - 1)) / columns;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: gap,
                  runSpacing: context.echoSpacing.xxs,
                  children: <Widget>[
                    for (var index = 0;
                        index < fixedPlaylists.length;
                        index++)
                      SizedBox(
                        width: itemWidth,
                        child: DiscoverPlaylistTile(
                          playlist: fixedPlaylists[index],
                          onPressed: () {
                            Navigator.of(context).push<void>(
                              EchoPageRoute<void>(
                                context: context,
                                builder: (context) => PlaylistDetailPage(
                                  playlistId: fixedPlaylists[index].id,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        );
      },
      loading: () => const DiscoverPlaylistLoading(),
      error: (error, stackTrace) => DiscoverSectionMessage(
        title: '歌单加载失败',
        description: '请检查网络或切换线路后重试。',
        icon: AppIcons.cloudOff,
        onRetry: () => ref.invalidate(playlistsProvider),
      ),
    );
  }
}

/// 不同平台歌单推荐模块
class PlatformPlaylistsSection extends ConsumerWidget {
  const PlatformPlaylistsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final loadFailed = ref.watch(playlistsLoadFailedProvider);

    return playlistsAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      data: (playlists) {
        final platformPlaylists =
            playlists.where((p) => p.isImported).toList();

        if (platformPlaylists.isEmpty) {
          return DiscoverSectionMessage(
            title: loadFailed ? '歌单暂时不可用' : '暂无平台歌单推荐',
            description: loadFailed
                ? '请检查网络或当前线路，然后重试。'
                : '从不同平台发现更多音乐。',
            icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
            onRetry: loadFailed
                ? () => ref.invalidate(playlistsProvider)
                : null,
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(1);
            final columns = textScale > 1.3 || constraints.maxWidth < 720
                ? 1
                : 2;
            final gap = context.echoSpacing.md;
            final itemWidth =
                (constraints.maxWidth - gap * (columns - 1)) / columns;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: gap,
                  runSpacing: context.echoSpacing.xxs,
                  children: <Widget>[
                    for (var index = 0;
                        index < platformPlaylists.length;
                        index++)
                      SizedBox(
                        width: itemWidth,
                        child: DiscoverPlaylistTile(
                          playlist: platformPlaylists[index],
                          onPressed: () {
                            Navigator.of(context).push<void>(
                              EchoPageRoute<void>(
                                context: context,
                                builder: (context) => PlaylistDetailPage(
                                  playlistId: platformPlaylists[index].id,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        );
      },
      loading: () => const DiscoverPlaylistLoading(),
      error: (error, stackTrace) => DiscoverSectionMessage(
        title: '平台歌单加载失败',
        description: '请检查网络或切换线路后重试。',
        icon: AppIcons.cloudOff,
        onRetry: () => ref.invalidate(playlistsProvider),
      ),
    );
  }
}
