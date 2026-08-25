import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/logger.dart';
import '../../../data/models/recommend.dart';
import '../../../data/models/music_library.dart';
import '../../../data/models/song.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/metadata_cache_provider.dart';
import '../../../providers/music_provider.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/playlist_provider.dart';
import '../../../providers/recommend_provider.dart';
import '../../../widgets/main_scaffold.dart';
import '../../../widgets/visible_remote_retry_scope.dart';
import '../../library/pages/album_list_page.dart';
import '../../library/pages/artist_list_page.dart';
import '../../library/pages/playlist_detail_page.dart';
import '../../library/pages/playlist_search_page.dart';
import '../../library/pages/song_list_page.dart';
import '../../library/pages/starred_page.dart';
import '../../player/widgets/song_options_sheet.dart';
import '../widgets/discover_media_widgets.dart';
import '../widgets/hoverable_horizontal_scroll.dart';
import 'search_page.dart';

const double _playlistCardWidth = 152;

/// 歌单卡片行高度:随文本缩放自适应,避免大字号下溢出。
/// 需容纳:封面(152) + 标题最多 2 行 + 「N 首」副标题 ——
/// 固定余量从 56 提到 70,保证标题换行时数量行不被挤出可视区。
double playlistRailHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return _playlistCardWidth + 70 + ((scale - 1) * 48).clamp(0.0, 72.0);
}

/// 音乐流首页 - Tab 1
class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  Future<void> _refresh() async {
    // 随机歌曲由区块按需拉取:这里只刷新其余区块,再广播「歌单变更」信号,
    // 让区块自行重拉最新随机歌曲,避免整页刷新也触发随机歌单远程请求。
    await Future.wait<Object?>(<Future<Object?>>[
      ref.refresh(playlistsProvider.future),
      ref.refresh(recentPlaylistsProvider.future),
      ref.refresh(homeCardsProvider.future),
      ref.refresh(homeRecommendSectionProvider.future),
      ref.refresh(recommendChannelsProvider.future),
    ]);
    notifyRandomSongsChanged();
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
        ref.invalidate(homeRecommendSectionProvider);
        ref.invalidate(recommendChannelsProvider);
        // 广播变更信号,让随机歌曲区块按需重拉(区块不再 watch provider)。
        notifyRandomSongsChanged();
      },
      child: Scaffold(
        backgroundColor: context.musicFlowColors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              MusicFlowPageHeader(
                title: '音乐流',
                leading: shouldShowPageDrawerTrigger(context)
                    ? MusicFlowIconButton(
                        icon: AppIcons.menu,
                        label: '打开应用菜单',
                        onPressed: openMusicFlowAppDrawer,
                      )
                    : null,
                trailing: MusicFlowIconButton(
                  icon: AppIcons.search,
                  label: '搜索音乐库',
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MusicFlowPageRoute<void>(
                        context: context,
                        builder: (context) => const SearchPage(),
                      ),
                    );
                  },
                ),
              ),
              const CategoryNavBar(),
              Expanded(
                child: MusicFlowRefreshView(
                  onRefresh: _refresh,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1400),
                      child: CustomScrollView(
                        cacheExtent: 1500,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: <Widget>[
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              context.musicFlowPageHorizontalPadding,
                              context.musicFlowSpacing.xs,
                              context.musicFlowPageHorizontalPadding,
                              context.musicFlowSpacing.xxl +
                                  context.musicFlowShellBottomObstruction,
                            ),
                            sliver: SliverList(
                              delegate: SliverChildListDelegate(
                                <Widget>[
                                  const RandomSongsSection(),
                                  SizedBox(height: context.musicFlowSpacing.sm),
                                  const RecentPlaylistsSection(),
                                  SizedBox(height: context.musicFlowSpacing.sm),
                                  const FixedRecommendSection(),
                                  SizedBox(height: context.musicFlowSpacing.sm),
                                  const PlatformRecommendSection(),
                                ],
                              ),
                            ),
                          ),
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
  ];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '分类导航',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowPageHorizontalPadding,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            for (var i = 0; i < _items.length; i++) ...<Widget>[
              if (i > 0)
                SizedBox(width: context.musicFlowSpacing.md),
              _CategoryNavItem(
                label: _items[i].$1,
                icon: _items[i].$2,
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MusicFlowPageRoute<void>(
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
      child: MusicFlowPressable(
        onPressed: onPressed,
        minimumSize: const Size(64, 64),
        borderRadius: context.musicFlowRadii.surface,
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 26, color: context.musicFlowColors.accent),
              SizedBox(height: context.musicFlowSpacing.xxs),
              Text(
                label,
                style: context.musicFlowTypography.metadata,
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
  /// 首页随机歌曲本地缓存的有效期(TTL):超过该时长即便本地有缓存,
  /// 也会后台拉取一次最新结果,避免「换了一批 / 歌单更新后首页仍显示旧歌」。
  /// 30 分钟内视为新鲜,直接使用本地缓存秒开。
  static const Duration _randomCacheTtl = Duration(minutes: 30);

  bool _autoContinue = false;
  int _roundToken = 0;
  final ScrollController _scrollCtrl = ScrollController();
  StreamSubscription<int>? _randomSongsSubscription;

  /// 最近一次可展示的歌曲(本地缓存或远程结果)。打开首页时先用它秒出内容,
  /// 同时后台拉取远程最新结果,避免每次都阻塞在远程请求与后端惰性刷新上。
  List<Song>? _lastKnownSongs;

  /// 本轮随机歌曲的 id 集合:用于判断当前播放队列是否仍是随机轮次,
  /// 避免歌单更新推送把随机歌曲误追加到用户手动切换的其他歌单。
  Set<String> _roundSongIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadCachedSongs());
    // 监听随机歌曲歌单「变更推送」:主项目插件维护刷新歌单后主动发信号,
    // 客户端收到后按需重拉,**不再轮询**,避免打开页面等待后端惰性重建。
    _randomSongsSubscription = randomSongsChangedStream().listen((_) {
      if (!mounted) return;
      Logger.infoWithTag('DISCOVER', 'random songs changed, refreshing');
      // 歌单更新:正在播放随机轮次时**追加**到队列末尾(不替换、不中断),
      // 否则仅刷新展示。
      unawaited(_handleRandomSongsChanged());
    });
    // 活跃库就绪后若还没有内容(无缓存 + 首次冷启动),补一次缓存读取/后台拉取。
    ref.listen<MusicLibrary?>(activeLibraryProvider, (prev, next) {
      if (next == null) return;
      if (prev != null && prev.id == next.id) return;
      if (_lastKnownSongs != null) return;
      unawaited(_loadCachedSongs());
    });
    // 监听投屏队列自然播完:DLNA 设备整轮播放完毕后自动加载下一轮随机歌曲续播。
    ref.listen<CastPeerState>(castPeerControllerProvider, (prev, next) {
      if (!_autoContinue) return;
      if (next.endOfQueueCount > (prev?.endOfQueueCount ?? -1)) {
        Logger.infoWithTag('DISCOVER', 'cast queue ended, loading next round');
        unawaited(_loadNextRound());
      }
    });
  }

  /// 先读本地缓存的随机歌曲,让区块立即有内容可展示,不等远程。
  /// 冷启动时活跃库可能尚未从 drift 就绪(libraryId 为 null),
  /// 回退到最近使用的库 ID 读取缓存,避免首屏一直空等网络/探测。
  /// 若本地也没有缓存,后台拉取一次填充(仅首次,不阻塞展示)。
  Future<void> _loadCachedSongs() async {
    try {
      final cache = ref.read(metadataCacheRepositoryProvider);
      var libraryId = ref.read(activeLibraryProvider)?.id;
      if (libraryId == null || libraryId.isEmpty) {
        libraryId = await cache.getLastLibraryId();
      }
      if (libraryId == null || libraryId.isEmpty) return;
      // 带写入时间的缓存:即使命中,也据此判断是否已超过 TTL,需要后台刷新。
      final cachedMeta = await cache.getRandomSongsWithMeta(libraryId);
      if (!mounted) return;
      if (cachedMeta != null && cachedMeta.songs.isNotEmpty) {
        // 远程数据已就绪时不再用旧缓存覆盖,避免「新内容 → 旧缓存」的闪回。
        if (_lastKnownSongs == null) {
          setState(() => _lastKnownSongs = cachedMeta.songs);
        }
        // 库指纹失效 + TTL:缓存按库 id 分区,库切换天然用各自缓存;
        // 超过有效期即便有缓存也后台拉最新,保证首页不会一直显示过期旧歌。
        final age = DateTime.now().difference(cachedMeta.cachedAt);
        if (age > _randomCacheTtl) {
          Logger.infoWithTag(
            'DISCOVER',
            'random songs cache stale (age=${age.inMinutes}m), '
            'refreshing in background',
          );
          unawaited(_fetchLatestForDisplay());
        }
        return;
      }
      // 无缓存:首次打开后台拉取一次,供首屏使用。
      unawaited(_fetchLatestForDisplay());
    } catch (e) {
      Logger.warnWithTag('DISCOVER', 'random songs cache read failed', e);
    }
  }

  /// 后台拉取最新随机歌曲并更新展示(不阻塞 UI,失败静默)。
  Future<void> _fetchLatestForDisplay() async {
    try {
      final songs = await ref.refresh(randomSongsProvider.future);
      if (!mounted) return;
      if (songs.isNotEmpty) {
        setState(() => _lastKnownSongs = songs);
      }
    } catch (e) {
      Logger.warnWithTag('DISCOVER', 'fetch latest random songs failed', e);
    }
  }

  Future<void> _playRound() async {
    final token = ++_roundToken;
    List<Song> songs;
    try {
      songs = await ref.refresh(randomSongsProvider.future);
    } catch (_) {
      songs = _lastKnownSongs ?? const <Song>[];
    }
    if (!mounted || token != _roundToken) return;
    if (songs.isEmpty) return;
    _autoContinue = true;
    _roundSongIds = songs.map((s) => s.id).toSet();
    setState(() => _lastKnownSongs = songs);
    await playEffectiveQueue(ref, songs);
  }

  Future<void> _loadNextRound() async {
    final token = ++_roundToken;
    final songs = await ref.refresh(randomSongsProvider.future);
    if (!mounted || token != _roundToken || !_autoContinue) return;
    if (songs.isEmpty) return;
    _roundSongIds = songs.map((s) => s.id).toSet();
    setState(() => _lastKnownSongs = songs);
    await playEffectiveQueue(ref, songs);
  }

  /// 随机歌曲歌单更新后的处理:
  /// - 刷新区块展示;
  /// - 若当前正在播放本轮随机歌曲(自动续播中且队列仍是随机轮次),
  ///   把新歌**追加**到播放队列末尾,而非替换队列 —— 保证播放不中断、
  ///   当前轮播完后能无缝接上最新一批。
  Future<void> _handleRandomSongsChanged() async {
    List<Song> songs;
    try {
      songs = await ref.refresh(randomSongsProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted || songs.isEmpty) return;
    setState(() => _lastKnownSongs = songs);
    if (!_autoContinue || _roundSongIds.isEmpty) return;
    // 仅当当前播放队列仍是本轮随机歌曲时才追加,避免污染用户切到的其他歌单。
    final cast = ref.read(castPeerControllerProvider);
    final fresh = <Song>[];
    if (cast.activePeer != null) {
      final queuedIds = <String>{
        for (final it in cast.castQueue)
          if (it['songId'] is String) it['songId'] as String,
      };
      if (queuedIds.isEmpty ||
          !queuedIds.any(_roundSongIds.contains)) {
        return;
      }
      for (final s in songs) {
        if (!queuedIds.contains(s.id)) fresh.add(s);
      }
      if (fresh.isEmpty) return;
      await ref
          .read(castPeerControllerProvider.notifier)
          .enqueueSongs(fresh);
    } else {
      final queue = ref.read(playerProvider).queue;
      if (queue.isEmpty || !queue.any((s) => _roundSongIds.contains(s.id))) {
        return;
      }
      final queuedIds = queue.map((s) => s.id).toSet();
      for (final s in songs) {
        if (!queuedIds.contains(s.id)) fresh.add(s);
      }
      if (fresh.isEmpty) return;
      ref.read(playerProvider.notifier).addAllToQueue(fresh);
    }
    Logger.infoWithTag('DISCOVER', 'appended ${fresh.length} new random songs');
  }

  void _refresh() {
    _autoContinue = false;
    _roundSongIds = <String>{};
    _roundToken++;
    unawaited(_fetchLatestForDisplay());
  }

  /// 歌曲横滑网格(每列 3 行),供数据态与缓存占位态共用,布局完全一致。
/// 使用有界高度 + ListView.builder 实现**真懒加载**:只对可视列惰性构建,
/// 不再一次性创建全部 20 首歌曲的 widget,降低大歌单的内存占用。
/// 注意:外层 sliver 给的是无界高度,横向 ListView 必须有界高度,
/// 否则(同样的问题)会导致水平 viewport 高度异常、随机歌曲重叠无法操作,
/// 并拖垮下方歌单区块的布局。
  Widget _buildSongsContent(List<Song> songs) {
    final itemWidth =
        (MediaQuery.sizeOf(context).width * 0.72).clamp(260.0, 360.0);
    if (songs.isEmpty) return const SizedBox.shrink();

    final columnCount = (songs.length + 2) ~/ 3;
    // 每列最多 3 行。《随机歌曲》行高最小约束 72 + 两处 2px 行距,再留少量
    // 余量兜底(个别长标题换行时避免溢出),ClipRect 负责裁剪。
    const double tileRowMinHeight = 72;
    const double rowGap = 2;
    final columnHeight = tileRowMinHeight * 3 + rowGap * 2 + 10; // = 230

    return ClipRect(
      child: SizedBox(
        height: columnHeight,
        child: HoverableHorizontalScroll(
          builder: (context, controller) => ListView.builder(
            controller: controller,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowSpacing.xs,
            ),
            itemCount: columnCount,
            itemBuilder: (context, col) {
              final firstRow = col * 3;
              final rowsInColumn = (songs.length - firstRow).clamp(0, 3);
              return Padding(
                padding: EdgeInsets.only(right: context.musicFlowSpacing.sm),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (var row = 0; row < rowsInColumn; row++) ...<Widget>[
                      SizedBox(
                        width: itemWidth,
                        child: DiscoverSongTile(
                          song: songs[firstRow + row],
                          onPressed: () {
                            playEffectiveQueue(
                              ref,
                              songs,
                              startIndex: firstRow + row,
                            );
                          },
                          onOpenActions: () => showSongOptionsSheet(
                            context: context,
                            song: songs[firstRow + row],
                          ),
                        ),
                      ),
                      if (row + 1 < rowsInColumn) const SizedBox(height: rowGap),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _randomSongsSubscription?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loadFailed = ref.watch(randomSongsLoadFailedProvider);
    final knownSongs = _lastKnownSongs;
    final hasContent = knownSongs != null && knownSongs.isNotEmpty;

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

    // 打开页面不触发远程请求:先秒出本地缓存,只有播放/手动刷新/收到歌单变更
    // 推送时才按需拉取,避免「打开客户端 → 后端惰性重建 → 长时间等待」。
    final Widget content;
    if (hasContent) {
      content = _buildSongsContent(knownSongs!);
    } else if (loadFailed) {
      content = DiscoverSectionMessage(
        title: '随心听暂时不可用',
        description: '请检查网络或当前线路，然后重试。',
        icon: AppIcons.cloudOff,
        onRetry: () => unawaited(_fetchLatestForDisplay()),
      );
    } else {
      content = const _RandomSongsLoading();
    }

    return DecoratedBox(
      key: const Key('discover-random-mix'),
      decoration: BoxDecoration(
        color: context.musicFlowColors.surface,
        borderRadius: context.musicFlowRadii.surface,
        border: Border.all(color: context.musicFlowColors.divider),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowSpacing.sm,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            MusicFlowSectionHeader(
              title: '随机歌曲',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  MusicFlowIconButton(
                    icon: AppIcons.refresh,
                    label: '换一批随机歌曲',
                    onPressed: _refresh,
                  ),
                  SizedBox(width: context.musicFlowSpacing.xs),
                  MusicFlowIconButton(
                    icon: AppIcons.play,
                    label: '播放随机歌曲',
                    onPressed: _playRound,
                  ),
                ],
              ),
            ),
            SizedBox(height: context.musicFlowSpacing.xs),
            content,
          ],
        ),
      ),
    );
  }
}

/// 随机歌曲加载态:横滑 + 每列 3 行骨架,与数据态布局(横滑列、每列 3 行)
/// 完全一致,避免「刚打开是 5 行、刷新后跳成 3 行」的高度跳变。
class _RandomSongsLoading extends StatelessWidget {
  const _RandomSongsLoading();

  @override
  Widget build(BuildContext context) {
    final itemWidth =
        (MediaQuery.sizeOf(context).width * 0.72).clamp(260.0, 360.0);
    // 高度与数据态 _buildSongsContent 保持一致,避免「加载态→数据态」跳变。
    const double skeletonColumnHeight = 230;
    return ClipRect(
      child: SizedBox(
        height: skeletonColumnHeight,
        child: HoverableHorizontalScroll(
          builder: (context, controller) => SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: context.musicFlowSpacing.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var col = 0; col < 3; col++)
                  Padding(
                    padding: EdgeInsets.only(right: context.musicFlowSpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (var row = 0; row < 3; row++) ...[
                          SizedBox(
                            width: itemWidth,
                            child: const _RandomSongTileSkeleton(),
                          ),
                          if (row < 2) const SizedBox(height: 2),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单行歌曲骨架(封面 + 两行文字),与 DiscoverSongTile 高度对齐。
class _RandomSongTileSkeleton extends StatelessWidget {
  const _RandomSongTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: context.musicFlowSpacing.xxs,
        ),
        child: Row(
          children: <Widget>[
            const MusicFlowSkeleton(width: 48, height: 48),
            SizedBox(width: context.musicFlowSpacing.sm),
            const Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  MusicFlowSkeleton.line(height: 16),
                  SizedBox(height: 8),
                  MusicFlowSkeleton.line(width: 112, height: 12),
                ],
              ),
            ),
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
        MusicFlowSectionHeader(
          title: '最近更新的歌单',
          trailing: MusicFlowIconButton(
            icon: AppIcons.refresh,
            label: '刷新最近更新歌单',
            onPressed: () => ref.invalidate(recentPlaylistsProvider),
          ),
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
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
            return HoverableHorizontalScroll(
              builder: (context, controller) => SizedBox(
                height: playlistRailHeight(context),
                child: ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                    horizontal: context.musicFlowPageHorizontalPadding,
                  ),
                  itemCount: playlists.length,
                  separatorBuilder: (context, index) =>
                      SizedBox(width: context.musicFlowSpacing.sm),
                  itemBuilder: (context, index) {
                    final pl = playlists[index];
                    return DiscoverPlaylistCard(
                      width: _playlistCardWidth,
                      title: pl.name,
                      subtitle: '${pl.songCount} 首',
                      coverArtId: pl.coverArt,
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          MusicFlowPageRoute<void>(
                            context: context,
                            builder: (context) => PlaylistDetailPage(
                              playlistId: pl.id,
                              initialName: pl.name,
                              initialSongCount: pl.songCount,
                              initialCoverArt: pl.coverArt,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            );
          },
          loading: () => SizedBox(
            height: playlistRailHeight(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: context.musicFlowPageHorizontalPadding,
              ),
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
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

/// 固定推荐歌单 + 随机歌单（对齐主项目首页「为你推荐」顶部）：
/// 固定卡（今日漫游/每日推荐/本地推荐，>30 首门槛）+ 随机补位的本地歌单，
/// 合计 homeCount 张（每日推荐插件配置，默认 8，含今日漫游固定卡）。
class FixedRecommendSection extends ConsumerWidget {
  const FixedRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sectionAsync = ref.watch(homeRecommendSectionProvider);
    final loadFailed = ref.watch(homeCardsLoadFailedProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader(
          title: '为你推荐',
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
        sectionAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (section) {
            if (section.isEmpty) {
              return DiscoverSectionMessage(
                title: loadFailed ? '为你推荐暂时不可用' : '暂无推荐歌单',
                description: loadFailed
                    ? '请检查网络或当前线路，然后重试。'
                    : '启用推荐插件后，这里会显示每日推荐等歌单。',
                icon: loadFailed ? AppIcons.cloudOff : AppIcons.playlist,
                onRetry: loadFailed
                    ? () => ref.invalidate(homeRecommendSectionProvider)
                    : null,
              );
            }
            // 固定卡 + 随机歌单合并为横向卡片行，样式与「平台推荐」完全一致：
            // 152 宽封面、playlistRailHeight 行高、HoverableHorizontalScroll 左右滑动。
            final cards = <({String id, String name, String coverArt, int songCount, String playlistId})>[
              for (final c in section.fixed)
                (
                  id: c.playlistId,
                  name: c.playlistName.isNotEmpty ? c.playlistName : c.name,
                  coverArt: c.coverArt ?? '',
                  songCount: c.songCount,
                  playlistId: c.playlistId,
                ),
              for (final p in section.random)
                (
                  id: p.id,
                  name: p.name,
                  coverArt: p.coverArt ?? '',
                  songCount: p.songCount,
                  playlistId: p.id,
                ),
            ];
            return HoverableHorizontalScroll(
              builder: (context, controller) => SizedBox(
                height: playlistRailHeight(context),
                child: ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                    horizontal: context.musicFlowPageHorizontalPadding,
                  ),
                  itemCount: cards.length,
                  separatorBuilder: (context, index) =>
                      SizedBox(width: context.musicFlowSpacing.sm),
                  itemBuilder: (context, index) {
                    final card = cards[index];
                    return DiscoverPlaylistCard(
                      width: _playlistCardWidth,
                      title: card.name,
                      subtitle: '${card.songCount} 首',
                      coverArtId: card.coverArt,
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          MusicFlowPageRoute<void>(
                            context: context,
                            builder: (context) => PlaylistDetailPage(
                              playlistId: card.playlistId,
                              initialName: card.name,
                              initialSongCount: card.songCount,
                              initialCoverArt: card.coverArt,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            );
          },
          loading: () => SizedBox(
            height: playlistRailHeight(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: context.musicFlowPageHorizontalPadding,
              ),
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: '为你推荐加载失败',
            description: '请检查网络或切换线路后重试。',
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(homeRecommendSectionProvider),
          ),
        ),
      ],
    );
  }
}

/// 打开平台推荐歌单。
/// - **已入库**的歌单（recommend 数据带 imported 标记）：直接经
///   /recommend/local 反查本地 playlistId 打开，**不再重新导入刷新**；
/// - **未入库**的歌单：与主项目一致，先经 /v1/online/:providerId/recommend/import
///   导入（幂等 upsert）拿到真实 library playlistId，再以本地歌单打开播放。
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
  final repo = ref.read(recommendRepositoryProvider);
  if (repo == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('未连接到音乐库')),
    );
    return;
  }

  // 已入库：直接打开本地歌单，跳过导入刷新。
  if (pl.imported) {
    try {
      final localId = await repo.findImportedPlaylistId(providerId, pl.id);
      if (localId != null && localId.isNotEmpty) {
        if (!context.mounted) return;
        Navigator.of(context).push<void>(
          MusicFlowPageRoute<void>(
            context: context,
            builder: (context) => PlaylistDetailPage(playlistId: localId),
          ),
        );
        return;
      }
    } catch (_) {
      // 反查失败则回退到导入流程（幂等，无副作用）。
    }
  }

  ref.read(recommendImportingProvider.notifier).state = pl.id;
  try {
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
      MusicFlowPageRoute<void>(
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
        MusicFlowSectionHeader(
          title: '平台推荐',
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
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
                    SizedBox(height: context.musicFlowSpacing.sm),
                    Text(
                      channel.name,
                      style: context.musicFlowTypography.label.copyWith(
                        color: context.musicFlowColors.accent,
                      ),
                    ),
                    SizedBox(height: context.musicFlowSpacing.xxs),
                  ],
                  if (channel.playlists.isNotEmpty)
                    HoverableHorizontalScroll(
                      builder: (context, controller) => SizedBox(
                        height: playlistRailHeight(context),
                        child: ListView.separated(
                          controller: controller,
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.symmetric(
                            horizontal: context.musicFlowPageHorizontalPadding,
                          ),
                          itemCount: channel.playlists.length,
                          separatorBuilder: (context, index) =>
                              SizedBox(width: context.musicFlowSpacing.sm),
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
                    ),
                ],
              ],
            );
          },
          loading: () => SizedBox(
            height: playlistRailHeight(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: context.musicFlowPageHorizontalPadding,
              ),
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
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
