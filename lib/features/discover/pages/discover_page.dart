import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/logger.dart';
import '../../../data/models/recommend.dart';
import '../../../data/models/music_library.dart';
import '../../../data/models/song.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/dlna_provider.dart';
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

const double _playlistCardWidth = 128;

/// 歌单卡片行高度:随文本缩放自适应,避免大字号下溢出。
/// 需容纳:封面(128) + 标题最多 2 行 + 「N 首」副标题。
double playlistRailHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return _playlistCardWidth + 56 + ((scale - 1) * 40).clamp(0.0, 56.0);
}

/// 首页标题:Windows 桌面端不显示标题;安卓端显示 MusicFlow;其余平台沿用「音乐流」。
String resolveMusicFlowHomeTitle() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    return '';
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return 'MusicFlow';
  }
  return '音乐流';
}

/// 首页各分区 widget 的 key 映射。服务端分区清单(key)未命中时忽略该分区,
/// 保证客户端向前兼容(服务端新增分区而客户端未认识时直接跳过)。
Widget? _homeSectionWidget(String key) {
  switch (key) {
    case 'random-songs':
      return const RandomSongsSection();
    case 'recent-playlists':
      return const RecentPlaylistsSection();
    case 'home-recommend':
      return const FixedRecommendSection();
    case 'platform-recommend':
      return const PlatformRecommendSection();
    case 'local-recommend':
      return const LocalPlatformRecommendSection();
    default:
      return null;
  }
}

/// 分区清单加载失败/未就绪时的回落顺序(与历史首页一致)。
const List<String> kDefaultHomeSectionKeys = <String>[
  'random-songs',
  'recent-playlists',
  'home-recommend',
  'platform-recommend',
  'local-recommend',
];

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
      ref.refresh(homeSectionsProvider.future),
      ref.refresh(playlistsProvider.future),
      ref.refresh(recentPlaylistsProvider.future),
      ref.refresh(homeCardsProvider.future),
      ref.refresh(homeRecommendSectionProvider.future),
      ref.refresh(recommendChannelsProvider.future),
      ref.refresh(localRecommendChannelsProvider.future),
    ]);
    notifyRandomSongsChanged();
  }

  @override
  Widget build(BuildContext context) {
    final randomSongsLoadFailed = ref.watch(randomSongsLoadFailedProvider);
    final homeCardsFailed = ref.watch(homeCardsLoadFailedProvider);
    final recommendFailed = ref.watch(recommendChannelsLoadFailedProvider);
    final recentFailed = ref.watch(recentPlaylistsLoadFailedProvider);
    final localRecommendFailed =
        ref.watch(localRecommendChannelsLoadFailedProvider);

    // 数据驱动解耦:按服务端分区清单渲染首页。清单未就绪/为空时回落默认顺序,
    // 保证首屏立即有内容;清单已就绪则由服务端决定分区顺序与可见性。
    final manifestSections = ref.watch(homeSectionsProvider).valueOrNull;
    final orderedKeys = <String>[
      if (manifestSections != null)
        ...manifestSections
            .where((s) => s.visible)
            .map((s) => s.key)
            .toSet(),
    ];
    final sectionKeys =
        orderedKeys.isEmpty ? kDefaultHomeSectionKeys : orderedKeys;
    final sectionWidgets = <String, Widget>{};
    for (final key in sectionKeys) {
      final sectionWidget = _homeSectionWidget(key);
      if (sectionWidget == null) continue;
      sectionWidgets[key] = sectionWidget;
    }
    final visibleSectionKeys = sectionWidgets.keys.toList();

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
          localRecommendFailed ||
          ref.read(localRecommendChannelsProvider).hasError ||
          recentFailed ||
          ref.read(recentPlaylistsProvider).hasError,
      onRetry: (ref) {
        ref.invalidate(randomSongsProvider);
        ref.invalidate(playlistsProvider);
        ref.invalidate(recentPlaylistsProvider);
        ref.invalidate(homeCardsProvider);
        ref.invalidate(homeRecommendSectionProvider);
        ref.invalidate(recommendChannelsProvider);
        ref.invalidate(localRecommendChannelsProvider);
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
                title: resolveMusicFlowHomeTitle(),
                leading: shouldShowPageDrawerTrigger(context)
                    ? MusicFlowIconButton(
                        icon: AppIcons.menu,
                        label: '打开应用菜单',
                        onPressed: openMusicFlowAppDrawer,
                      )
                    : null,
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
                      // 降低垂直缓存区：只构建视口附近分区，避免冷启动时
                      // 一次性拉起所有横向列表的封面请求，保证视口内封面优先加载。
                      cacheExtent: 400,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: <Widget>[
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            context.musicFlowPageHorizontalPadding,
                            // 分类导航自带竖向内边距，这里不再叠加，让首个模块
                            // 紧贴库按钮（对齐箭头音乐的紧凑首屏）。
                            0,
                            context.musicFlowPageHorizontalPadding,
                            context.musicFlowSpacing.xxl +
                                context.musicFlowShellBottomObstruction,
                          ),
                          sliver: SliverList.separated(
                            itemCount: visibleSectionKeys.length,
                            // KeyedSubtree 保证分区顺序变化时各分区(尤其状态型 RandomSongsSection)状态稳定。
                            itemBuilder: (context, index) {
                              final key = visibleSectionKeys[index];
                              final child = KeyedSubtree(
                                key: ValueKey<String>('home-section-$key'),
                                child: sectionWidgets[key]!,
                              );
                              // 按参考稿精确位移（负内边距只上移视觉位置，
                              // 由分区自身的 padding 兜底，不产生重叠）：
                              // - 随机歌曲整体上移 5px；
                              // - 最近更新的歌单上移 10px（其下区块自然跟随）。
                              final topInset = switch (key) {
                                'random-songs' => -5.0,
                                'recent-playlists' => -6.0,
                                _ => 0.0,
                              };
                              final bottomInset = key == 'random-songs'
                                  ? -4.0
                                  : 0.0;
                              return Padding(
                                padding: EdgeInsets.only(
                                  top: topInset,
                                  bottom: bottomInset,
                                ),
                                child: child,
                              );
                            },
                            // 模块间距对齐箭头音乐（更紧凑）。
                            separatorBuilder: (context, index) => SizedBox(
                              height: context.musicFlowSpacing.xxs,
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

// 随机歌曲区块有本地状态(轮次 token/滚动控制器/自动重试等),在
// SliverList.builder 的惰性布局里需要保持存活,避免滑出视口后状态丢失。
class _RandomSongsSectionState extends ConsumerState<RandomSongsSection>
    with AutomaticKeepAliveClientMixin {
  /// 首页随机歌曲本地缓存的有效期(TTL):超过该时长即便本地有缓存,
  /// 也会后台拉取一次最新结果,避免「换了一批 / 歌单更新后首页仍显示旧歌」。
  /// 30 分钟内视为新鲜,直接使用本地缓存秒开。
  static const Duration _randomCacheTtl = Duration(minutes: 30);

  bool _autoContinue = false;
  int _roundToken = 0;
  StreamSubscription<int>? _randomSongsSubscription;

  /// 自动重试定时器与计数:首载失败(无缓存)时自动补拉,有界重试,
  /// 成功加载或区块真正无数据时停止,避免瞬时网络问题把区块永久隐藏。
  Timer? _autoRetryTimer;
  int _autoRetryCount = 0;
  static const int _maxAutoRetry = 3;
  static const Duration _autoRetryDelay = Duration(seconds: 3);

  /// 最近一次可展示的歌曲(本地缓存或远程结果)。打开首页时先用它秒出内容,
  /// 同时后台拉取远程最新结果,避免每次都阻塞在远程请求与后端惰性刷新上。
  List<Song>? _lastKnownSongs;

  @override
  bool get wantKeepAlive => true;

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
    // 说明:initState 里不能用 ref.listen(riverpod 2.6.1 只允许在 build 内调用,
    // 且随机歌曲区块本身由 SliverList 惰性构建,debugDoingBuild 为 false)。
    // 改用 ref.listenManual(专为 initState 设计),widget 卸载时自动释放订阅。
    ref.listenManual<MusicLibrary?>(
      activeLibraryProvider,
      (prev, next) {
        if (next == null) return;
        if (prev != null && prev.id == next.id) return;
        if (_lastKnownSongs != null) return;
        unawaited(_loadCachedSongs());
      },
    );
    // 监听投屏队列自然播完:DLNA 设备整轮播放完毕后自动加载下一轮随机歌曲续播。
    ref.listenManual<CastPeerState>(
      castPeerControllerProvider,
      (prev, next) {
        if (!_autoContinue) return;
        if (next.endOfQueueCount > (prev?.endOfQueueCount ?? -1)) {
          Logger.infoWithTag(
            'DISCOVER',
            'cast queue ended, loading next round',
          );
          unawaited(_loadNextRound());
        }
      },
    );
    // 自愈兜底:随机歌曲首载若因「地址探测/线路的瞬时失败」被置为 failed 且本机又
    // 无缓存时,区块会整块隐藏。这里监听 failed 信号自动补拉一次(有界重试),
    // 避免整块永久隐藏,造成「Windows 一直提示网络异常 / 随机歌曲不显示」的表象。
    ref.listenManual<bool>(randomSongsLoadFailedProvider, (prev, next) {
      if (!mounted) return;
      if (!next) return;
      _scheduleAutoRetry();
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
          _resetAutoRetry();
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
      // 缓存读取异常也不阻断首屏:回退到网络拉取一次。
      // 这是「Windows 冷启动拉不到随机歌曲」的关键兜底——此前缓存坏数据
      // 抛异常后被直接吞掉,后续从未触发 _fetchLatestForDisplay。
      if (mounted) unawaited(_fetchLatestForDisplay());
    }
  }

  /// 后台拉取最新随机歌曲并更新展示(不阻塞 UI,失败静默)。
  Future<void> _fetchLatestForDisplay() async {
    try {
      final songs = await ref.refresh(randomSongsProvider.future);
      if (!mounted) return;
      if (songs.isNotEmpty) {
        _resetAutoRetry();
        setState(() => _lastKnownSongs = songs);
      }
    } catch (e) {
      Logger.warnWithTag('DISCOVER', 'fetch latest random songs failed', e);
    }
  }

  /// 自动补拉调度:仅当「区块尚无内容」且未超上限时,延迟一段时间后重拉。
  /// 成功拿到内容后由 [_resetAutoRetry] 重置计数;无内容时最多重试
  /// [_maxAutoRetry] 次,避免在真正离线(无服务器)时无限空转。
  void _scheduleAutoRetry() {
    if (_autoRetryTimer != null) return;
    if (_lastKnownSongs != null) return;
    if (_autoRetryCount >= _maxAutoRetry) return;
    _autoRetryTimer = Timer(_autoRetryDelay, () {
      _autoRetryTimer = null;
      if (!mounted) return;
      if (_lastKnownSongs != null) return;
      _autoRetryCount++;
      Logger.infoWithTag(
        'DISCOVER',
        'auto-retry random songs (#$_autoRetryCount/$_maxAutoRetry)',
      );
      unawaited(_loadCachedSongs());
    });
  }

  /// 成功拿到可展示内容后重置自动重试计数,让后续瞬时失败仍有机会自愈。
  void _resetAutoRetry() {
    _autoRetryCount = 0;
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

  /// 队列播完(下一轮)时拉取新一批随机歌曲并**追加**到队尾继续播,而非整批替换。
  ///
  /// - 保留已播的旧轮次歌曲在队首(可往前切回),新一批从追加点无缝接上;
  /// - 新一批与旧内容按 id 去重,避免刚播完的歌立即又出现;
  /// - 本机链路用合并队列 + 从新批首首续播;投屏/DLNA 链路由其内部换批续播。
  Future<void> _loadNextRound() async {
    final token = ++_roundToken;
    final songs = await ref.refresh(randomSongsProvider.future);
    if (!mounted || token != _roundToken || !_autoContinue) return;
    if (songs.isEmpty) return;
    // 先读当前已展示/已播的历史批,再更新展示,否则 _lastKnownSongs 已被新批覆盖、
    // fresh 永远为空,无法实现「追加」。
    final current = _lastKnownSongs ?? const <Song>[];
    final currentIds = current.map((s) => s.id).toSet();
    final fresh = songs.where((s) => !currentIds.contains(s.id)).toList();
    if (fresh.isEmpty) return;
    _roundSongIds = songs.map((s) => s.id).toSet();
    setState(() => _lastKnownSongs = songs);
    final merged = <Song>[...current, ...fresh];
    await playEffectiveQueue(ref, merged, startIndex: current.length);
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
    } else if (ref.read(dlnaCastProvider).isCasting) {
      // 链路 B（局域网 DLNA 直投）：追加到直投队列末尾。
      final queuedIds = <String>{
        for (final t in ref.read(dlnaCastProvider).queue) t.songId,
      };
      if (queuedIds.isEmpty || !queuedIds.any(_roundSongIds.contains)) return;
      for (final s in songs) {
        if (!queuedIds.contains(s.id)) fresh.add(s);
      }
      if (fresh.isEmpty) return;
      await ref.read(dlnaCastProvider.notifier).enqueueSongs(fresh);
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
    // 宽度撑开:保证底部「歌手 · 时长」信息行只占一行(过窄会折成两行)。
    final itemWidth =
        (MediaQuery.sizeOf(context).width * 0.72).clamp(260.0, 360.0);
    if (songs.isEmpty) return const SizedBox.shrink();

    final columnCount = (songs.length + 2) ~/ 3;
    // 每列最多 3 行。参考箭头音乐把随机歌曲整体改紧凑:
    // 行高最小约束 64 + 两处 2px 行距,再留少量余量兜底。
    const double tileRowMinHeight = 64;
    const double rowGap = 2;
    final columnHeight = tileRowMinHeight * 3 + rowGap * 2 + 10; // = 206

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
                    for (var row = 0; row < rowsInColumn; row++) ...[
                      // Flexible 让每行共享整块高度,行内内容更高(如大字号)时由
                      // ClipRect 裁剪而**不触发 RenderFlex 溢出异常**——保持「紧凑
                      // 三行带」观感的同时,兼容 200% 字号这类极端缩放场景。
                      Flexible(
                        child: ClipRect(
                          child: SizedBox(
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
    _autoRetryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
    // 数据驱动解耦:服务端暂无随机歌曲数据且本机也无缓存时,整块隐藏,不展示
    // 「网络异常/不可用」的错误提示(该失败通常是慢探测/地址未就绪的瞬时态,
    // ensureActiveAddressProvider 会自愈)。有缓存/有数据 → 正常展示;加载中 →
    // 骨架屏;仅当「无数据且加载态」之外的内容都没有缓存时才回落骨架。
    if (!hasContent && loadFailed) {
      return const SizedBox.shrink();
    }
    final Widget content;
    if (hasContent) {
      content = _buildSongsContent(knownSongs);
    } else {
      content = const _RandomSongsLoading();
    }

    // 去掉外框(原 surface 背景 + 描边):参考箭头音乐,随机歌曲区块直接融入
    // 页面底色,不再用卡片包裹。保留 key 供测试定位。
    return Padding(
      key: const Key('discover-random-mix'),
      padding: EdgeInsets.symmetric(
        horizontal: context.musicFlowSpacing.sm,
        vertical: context.musicFlowSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          MusicFlowSectionHeader.compact(
            title: '随机歌曲',
            // 刷新按钮挨着模块标题,播放按钮由 Spacer 推到最右。
            trailingFollowsTitle: true,
            trailing: Row(
              children: <Widget>[
                MusicFlowIconButton(
                  icon: AppIcons.refresh,
                  label: '换一批随机歌曲',
                  onPressed: _refresh,
                ),
                const Spacer(),
                MusicFlowIconButton(
                  icon: AppIcons.play,
                  label: '播放随机歌曲',
                  onPressed: _playRound,
                ),
              ],
            ),
          ),
          SizedBox(height: context.musicFlowSpacing.xxs),
          content,
        ],
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
    // 宽度撑开:保证底部「歌手 · 时长」信息行只占一行(过窄会折成两行)。
    final itemWidth =
        (MediaQuery.sizeOf(context).width * 0.72).clamp(260.0, 360.0);
    // 高度与数据态 _buildSongsContent 保持一致,避免「加载态→数据态」跳变。
    const double skeletonColumnHeight = 206;
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
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: context.musicFlowSpacing.xxs,
        ),
          child: Row(
            children: <Widget>[
              const MusicFlowSkeleton(width: 56, height: 56),
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
        MusicFlowSectionHeader.compact(
          title: '最近更新的歌单',
          // 刷新按钮挨着模块标题。
          trailingFollowsTitle: true,
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
              // 数据驱动解耦:服务端暂无歌单数据时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),避免空数据/失败占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: '歌单暂时不可用',
                description: '请检查网络或当前线路，然后重试。',
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(recentPlaylistsProvider),
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
        MusicFlowSectionHeader.compact(
          title: '为你推荐',
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
        sectionAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (section) {
            if (section.isEmpty) {
              // 数据驱动解耦:服务端暂无推荐歌单时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),不让空数据/占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: '为你推荐暂时不可用',
                description: '请检查网络或当前线路，然后重试。',
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(homeRecommendSectionProvider),
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
    showMusicFlowToast(context, '推荐服务暂不可用，请检查平台推荐插件是否已启用');
    return;
  }
  final repo = ref.read(recommendRepositoryProvider);
  if (repo == null) {
    showMusicFlowToast(context, '未连接到音乐库');
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
      showMusicFlowToast(context, '导入歌单失败：$msg');
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
        MusicFlowSectionHeader.compact(
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
              // 数据驱动解耦:服务端暂无平台推荐数据时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),避免空数据/失败占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: '平台推荐暂时不可用',
                description: '请检查网络或当前线路，然后重试。',
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(recommendChannelsProvider),
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

/// 本地随机分区标题:优先用后端透传的 subtag(如「每日更新」),缺省回落「本地随机」。
/// 名称去掉末尾「音乐」与主项目前端保持一致。
String localChannelTitle(LocalRecommendChannel channel) {
  final base = channel.name.endsWith('音乐')
      ? channel.name.substring(0, channel.name.length - '音乐'.length)
      : channel.name;
  final tag = (channel.subtag != null && channel.subtag!.isNotEmpty)
      ? channel.subtag!
      : '本地随机';
  return '$base·$tag';
}

/// 本地随机(按平台):由后端 /v1/local-recommend 提供,从本地库按平台随机挑歌单。
/// 与主项目前端一致:歌单均已入库,点击直接打开本地歌单,无需导入刷新。
class LocalPlatformRecommendSection extends ConsumerWidget {
  const LocalPlatformRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsAsync = ref.watch(localRecommendChannelsProvider);
    final loadFailed = ref.watch(localRecommendChannelsLoadFailedProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(title: '本地随机'),
        SizedBox(height: context.musicFlowSpacing.xxs),
        channelsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (channels) {
            final allPlaylists =
                channels.expand((c) => c.playlists).toList();
            if (allPlaylists.isEmpty) {
              // 数据驱动解耦:服务端暂无本地随机数据时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),避免空数据/失败占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: '本地随机暂时不可用',
                description: '请检查网络或当前线路，然后重试。',
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(localRecommendChannelsProvider),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final channel in channels)
                  if (channel.playlists.isNotEmpty) ...<Widget>[
                    if (channels.length > 1) ...<Widget>[
                      SizedBox(height: context.musicFlowSpacing.sm),
                      // 分区标题优先用后端透传的 subtag(如「每日更新」),缺省回落「本地随机」。
                      Text(
                        localChannelTitle(channel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.label.copyWith(
                          color: context.musicFlowColors.accent,
                        ),
                      ),
                      // 有说明性 tagline 时作为副标题展示(缺省不显示)。
                      if (channel.tagline case final tagline?
                          when tagline.isNotEmpty) ...[
                        SizedBox(height: context.musicFlowSpacing.xxs),
                        Text(
                          tagline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.musicFlowTypography.metadata,
                        ),
                      ],
                      SizedBox(height: context.musicFlowSpacing.xxs),
                    ],
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
            title: '本地随机加载失败',
            description: '请检查网络或切换线路后重试。',
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(localRecommendChannelsProvider),
          ),
        ),
      ],
    );
  }
}
