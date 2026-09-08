import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/offline/dynamic_cover_keys.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/ui/locale_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/widgets/main_scaffold.dart';
import 'package:musicflow_client/widgets/visible_remote_retry_scope.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/playlist_options_sheet.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show isWindowsDesktop, kWindowsWindowControlsWidth;
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/section_shift.dart';
import 'package:musicflow_client/features/discover/widgets/category_nav_bar.dart';
import 'package:musicflow_client/features/discover/widgets/random_songs_section.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';

const double _playlistCardWidth = 128;

/// 宽屏(无分类导航)时内容区顶部与首个分区之间的间距。
///
/// 取值使「随机歌曲」标题与侧边栏「主页」行落在同一水平线:
/// 侧栏 113 = 头部 64 + 分割线 1 + 列表上边距 16 + 「主页」行半高 32;
/// 内容区 = 搜索条上边距 12 + 搜索条 48 + 本间距 + 分区内边距 4 + 标题半高 24。
/// 即 113 - 88 = 25。
const double kHomeContentTopGap = 25;

/// 歌单卡片行高度:随文本缩放自适应,避免大字号下溢出。
/// 需容纳:封面(128) + 标题最多 2 行 + 「N 首」副标题。
double playlistRailHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return _playlistCardWidth + 56 + ((scale - 1) * 40).clamp(0.0, 56.0);
}

/// 首页标题:Windows 桌面端不显示标题;安卓端显示 MusicFlow;其余平台沿用「音乐流」。
String resolveMusicFlowHomeTitle(AppLocalizations loc) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    return '';
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return 'MusicFlow';
  }
  return loc.discover_music_flow_title;
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
/// 打开全屏搜索页。首页标题行搜索按钮与搜索条共用同一入口，
/// 保证各端搜索功能/逻辑一致（所有输入都在搜索页完成）。
void _openSearchPage(BuildContext context) {
  Navigator.of(context).push<void>(
    MusicFlowPageRoute<void>(
      context: context,
      builder: (context) => const SearchPage(),
    ),
  );
}

/// 播放本地歌单（供首页歌单卡封面播放按钮与长按菜单使用）。
/// 加载歌单全部歌曲后整单播放，并记录队列来源为歌单（封面叠加跳动竖条）。
///
/// [coverArtId]/[playlistName] 非空时，顺带把该歌单封面（非动态）写入离线缓存，
/// 供首页断网时离线展示。
Future<void> playLocalPlaylistById(
  WidgetRef ref,
  String playlistId, {
  String? coverArtId,
  String? playlistName,
}) async {
  final loc = l10nNow(ref.read(appLanguageProvider).preference);
  final repository = ref.read(playlistRepositoryProvider);
  if (repository == null) {
    NetworkErrorNotifier.show(loc.discover_no_library_selected);
    return;
  }
  try {
    final songs = await repository.getAllPlaylistSongs(playlistId);
    if (songs.isEmpty) {
      NetworkErrorNotifier.show(loc.discover_playlist_empty);
      return;
    }
    // 缓存歌单封面（非动态）供首页离线展示；动态歌单由 cachePlaylistCover 判定跳过。
    final effectiveCover = (coverArtId != null && coverArtId.isNotEmpty)
        ? coverArtId
        : songs.first.coverArt;
    if (effectiveCover != null && effectiveCover.isNotEmpty) {
      unawaited(
        ref
            .read(offlineCacheDaemonProvider)
            .cachePlaylistCover(effectiveCover, playlistName: playlistName),
      );
    }
    await playEffectiveQueue(
      ref,
      songs,
      startIndex: 0,
      shuffleRandomStart: true,
      origin: QueueOrigin(QueueOriginKind.playlist, playlistId),
    );
  } catch (_) {
    NetworkErrorNotifier.show(loc.discover_network_failed_play_playlist);
  }
}

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

  /// 首页顶部栏。compact 布局下用大项目标题作为「更多」入口：点击标题打开
  /// 应用菜单（显示更多），不再单独放菜单按钮；标题为空（Windows 等不显示
  /// 首页标题的平台）或宽屏布局（菜单已由侧边栏提供）时回退为原顶部栏。
  Widget _buildHomeHeader(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final title = resolveMusicFlowHomeTitle(loc);
    final showDrawerTrigger = shouldShowPageDrawerTrigger(context);
    // 宽屏(侧边栏已提供导航与品牌标题)且该平台不显示首页标题(Windows)时:
    // 不再渲染空标题栏 —— 空 header 会把「随机歌曲」整体压低约 72px,
    // 永远对不齐侧边栏的「主页」行。
    if (!showDrawerTrigger && title.isEmpty) {
      return const SizedBox.shrink();
    }
    final headerPadding = EdgeInsets.fromLTRB(
      context.musicFlowPageHorizontalPadding - 5,
      context.musicFlowSpacing.sm,
      context.musicFlowPageHorizontalPadding - 5,
      context.musicFlowSpacing.sm,
    );

    // compact + 有标题：大标题本身即「更多」入口，移到原按钮位置（最左端）。
    if (showDrawerTrigger && title.isNotEmpty) {
      // SizedBox(width: ∞) 撑满列宽：外层 Column 默认 crossAxisAlignment.center
      // 给子级的是无界宽松约束,若不撑满,Row 宽度=内容自然宽度,窄屏(320dp)+
      // 大字体(200% 缩放)下超长标题会把整行撑爆(RenderFlex overflow 165px)。
      return SizedBox(
        width: double.infinity,
        child: Padding(
          padding: headerPadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // 标题整体作为按钮：点击打开应用菜单（显示更多导航/设置）。
              // 字号缩到 headline(19,原 display 26 视觉占位过大);Flexible loose
              // 让按钮宽度按文字自然宽度收住,不再 Expanded 占满剩余——
              // 解决「MusicFlow 按钮区域太长」;文字过长仍单行省略。
              // 按钮 minimumSize 保留默认 48×48,与右侧 IconButton 同高,
              // 两者中心均 = 24px → 视觉垂直居中对齐。
              Flexible(
                fit: FlexFit.loose,
                child: MusicFlowPressable(
                  semanticLabel: loc.discover_open_app_menu,
                  onPressed: openMusicFlowAppDrawer,
                  child: Semantics(
                    header: true,
                    namesRoute: true,
                    child: Text(
                      title,
                      style: context.musicFlowTypography.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              // v3.4.51 曾为修「标题按钮区域太长」把标题改 Flexible(loose)。
              // v3.4.62 搜索按钮已移入分类导航首位(「探索」)，标题行不再放按钮。
            ],
          ),
        ),
      );
    }

    return MusicFlowPageHeader(
      title: title,
      // 与下方内容区(页级边距-5)对齐：菜单/更多设置按钮与标题同列。
      padding: headerPadding,
      leading: showDrawerTrigger
          ? MusicFlowIconButton(
              icon: AppIcons.menu,
              label: loc.discover_open_app_menu,
              onPressed: openMusicFlowAppDrawer,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
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
    // 分类导航只在 compact 展示(见下方 Column);宽屏没有它时,内容区需要
    // 自己补一段顶部间距,让首个分区(随机歌曲)标题落在侧边栏「主页」行
    // 的水平线上:侧栏 = 头部 64 + 分割线 1 + 列表上边距 16 + 行半高 32 = 113;
    // 内容区 = 搜索条上边距 12 + 搜索条 48 + 本间距 + 分区内边距 4 + 标题半高 24。
    final showCategoryNav = shouldShowPageDrawerTrigger(context);

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
              // 首页顶部：compact 布局下直接用大项目标题作为「更多」入口
              // （点击标题打开应用菜单），不再单独放置菜单按钮；标题为空或
              // 宽屏布局（菜单已由侧边栏提供）时保持原样。
              _buildHomeHeader(context),
              // 搜索条只在宽屏(Windows 等)展示；compact 标题行右侧已有
              // 搜索按钮(同一入口)，移动端不再重复放一条占位搜索框(v3.4.50)。
              if (!(showCategoryNav &&
                  resolveMusicFlowHomeTitle(loc).isNotEmpty))
                _HomeSearchEntry(),
              // 分类导航(喜欢/歌单/歌曲/艺术家/专辑)只在 compact 布局展示:
              // 宽屏/桌面端侧边抽屉已提供同样的入口,内容区不再重复一行,
              // 同时让「随机歌曲」标题能与侧边栏「主页」行对齐。
              if (showCategoryNav) const CategoryNavBar(),
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
                            context.musicFlowPageHorizontalPadding - 5,
                            // 分类导航自带竖向内边距，这里不再叠加，让首个模块
                            // 紧贴库按钮（对齐箭头音乐的紧凑首屏）；宽屏没有
                            // 分类导航时改为 [kHomeContentTopGap]，把「随机歌曲」
                            // 顶到与侧边栏「主页」行同一水平线。
                            showCategoryNav ? 0 : kHomeContentTopGap - 25,
                            context.musicFlowPageHorizontalPadding - 5,
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
                              // 按参考稿精确位移（整体上移并等量收缩布局占位，
                              // 由分区自身的 padding 兜底，不产生重叠）：
                              // - 随机歌曲整体上移 5px、底部收缩 4px；
                              // - 最近更新的歌单上移 6px（其下区块自然跟随）。
                              // 不能用负 EdgeInsets：RenderPadding 在 debug 断言
                              // padding.isNonNegative，会把整个区块从树上摘除。
                              final topInset = switch (key) {
                                'random-songs' => -5.0,
                                'recent-playlists' => -6.0,
                                _ => 0.0,
                              };
                              final bottomInset = key == 'random-songs'
                                  ? -4.0
                                  : 0.0;
                              return SectionShift(
                                top: topInset,
                                bottom: bottomInset,
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


/// 首页顶部搜索入口:点击进入搜索页(自动聚焦并浮出搜索范围)。
///
/// 只读入口,不持有输入状态:首页只负责跳转,所有输入都在搜索页完成,
/// 避免首页与搜索页两份输入状态不同步。
class _HomeSearchEntry extends StatelessWidget {
  const _HomeSearchEntry();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    // Windows 无系统标题栏:右上角是窗口控制按钮(最小化/最大化/关闭),
    // 搜索条右侧留出等宽空白,避免被按钮压住。
    final rightInset = isWindowsDesktop ? kWindowsWindowControlsWidth : 0.0;
    // 与下方内容分区同一套约束(Align topCenter + maxWidth 1400):宽窗口下
    // 分区被 maxWidth 居中收窄,搜索框若留在约束盒外会贴窗口左缘,
    // 永远对不齐内容区左缘(分区标题栏)。套进同一约束后左缘恒对齐。
    // 注意:约束盒内必须用 SizedBox 撑满宽度——ConstrainedBox 是收缩包裹,
    // 若直接放 widthFactor 0.5 的 FractionallySizedBox,整条链会收缩成
    // 半宽并被外层 Align 居中,搜索框反而跑到窗口正中间。
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
          key: const ValueKey<String>('home-search-entry'),
          padding: EdgeInsets.fromLTRB(
            context.musicFlowPageHorizontalPadding - 5,
            // 整体下移 10px,让搜索条与侧边栏顶部留白节奏一致。
            spacing.sm + 10,
            context.musicFlowPageHorizontalPadding - 5 + rightInset,
            spacing.sm,
          ),
          // 首页大搜索框占满整行过于臃肿,收窄为可用宽度的一半并左对齐,
          // 保留原左侧位置(入口仅 Windows 等宽屏渲染)。
          child: FractionallySizedBox(
            widthFactor: 0.5,
            alignment: Alignment.centerLeft,
            child: MusicFlowPressable(
              semanticLabel: loc.discover_search,
              onPressed: () => _openSearchPage(context),
              borderRadius: context.musicFlowRadii.pill,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: context.musicFlowRadii.pill,
                  border:
                      Border.all(color: colors.controlBoundary, width: 0.5),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(AppIcons.search, size: 20, color: colors.muted),
                    SizedBox(width: spacing.sm),
                    Expanded(
                      child: Text(
                        loc.search_hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.body.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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
    final loc = AppLocalizations.of(context);
    final playlistsAsync = ref.watch(recentPlaylistsProvider);
    final loadFailed = ref.watch(recentPlaylistsLoadFailedProvider);
    // 当前播放来源：识别正在播放的歌单（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);

    // 歌单封面在「展示」时即写离线缓存（非动态歌单），供首页断网离线展示；
    // 动态歌单（今日漫游/每日推荐等）由 cachePlaylistCover 内部判定跳过。
    ref.listen(recentPlaylistsProvider, (_, next) {
      final data = next.valueOrNull;
      if (data == null || data.isEmpty) return;
      final daemon = ref.read(offlineCacheDaemonProvider);
      for (final pl in data) {
        final cover = pl.coverArt?.trim() ?? '';
        if (cover.isEmpty) continue;
        unawaited(daemon.cachePlaylistCover(cover, playlistName: pl.name));
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(
          title: loc.discover_recent_playlists,
          // 刷新按钮挨着模块标题。
          trailingFollowsTitle: true,
          trailing: MusicFlowIconButton(
            icon: AppIcons.refresh,
            label: loc.discover_refresh_recent_playlists,
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
                title: loc.discover_section_unavailable_playlist,
                description: loc.discover_error_desc_check_route,
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
                  // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                  cacheExtent: 0,
                  padding: EdgeInsets.zero,
                  itemCount: playlists.length,
                  separatorBuilder: (context, index) =>
                      SizedBox(width: context.musicFlowSpacing.sm),
                  itemBuilder: (context, index) {
                    final pl = playlists[index];
                    return DiscoverPlaylistCard(
                      width: _playlistCardWidth,
                      title: pl.name,
                      subtitle: loc.discover_track_count('${pl.songCount}'),
                      coverArtId: pl.coverArt,
                      isNowPlaying: queueOrigin?.matchesPlaylist(pl.id) ??
                          false,
                      onLongPress: () => showPlaylistOptionsSheet(
                        context: context,
                        playlist: pl,
                      ),
                      onPlay: () => playLocalPlaylistById(
                            ref,
                            pl.id,
                            coverArtId: pl.coverArt,
                            playlistName: pl.name,
                          ),
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
              padding: EdgeInsets.zero,
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: loc.discover_recent_playlists_load_failed,
            description: loc.discover_error_desc_switch_route,
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
    final loc = AppLocalizations.of(context);
    final sectionAsync = ref.watch(homeRecommendSectionProvider);
    final loadFailed = ref.watch(homeCardsLoadFailedProvider);
    // 当前播放来源：识别正在播放的歌单（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(
          title: loc.discover_for_you,
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
                title: loc.discover_unavailable_recommend,
                description: loc.discover_error_desc_check_route,
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
                  // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                  cacheExtent: 0,
                  padding: EdgeInsets.zero,
                  itemCount: cards.length,
                  separatorBuilder: (context, index) =>
                      SizedBox(width: context.musicFlowSpacing.sm),
                  itemBuilder: (context, index) {
                    final card = cards[index];
                    return DiscoverPlaylistCard(
                      width: _playlistCardWidth,
                      title: card.name,
                      subtitle: loc.discover_track_count('${card.songCount}'),
                      coverArtId: card.coverArt,
                      isNowPlaying:
                          queueOrigin?.matchesPlaylist(card.playlistId) ??
                          false,
                      // 动态歌单封面每日变化：不读不写离线缓存，冷启动每次重拉。
                      alwaysFresh:
                          DynamicCoverKeys.isDynamicPlaylist(
                            card.name,
                            id: card.playlistId,
                          ),
                      onLongPress: () => showPlaylistOptionsSheet(
                        context: context,
                        playlist: Playlist(
                          id: card.playlistId,
                          name: card.name,
                          songCount: card.songCount,
                          coverArt: card.coverArt,
                          duration: 0,
                        ),
                      ),
                      onPlay: () => playLocalPlaylistById(
                            ref,
                            card.playlistId,
                            coverArtId: card.coverArt,
                            playlistName: card.name,
                          ),
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
              padding: EdgeInsets.zero,
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: loc.discover_recommend_load_failed,
            description: loc.discover_error_desc_switch_route,
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
  final loc = AppLocalizations.of(context);
  if (providerId == null || providerId.isEmpty) {
    showMusicFlowToast(context, loc.discover_recommend_service_unavailable);
    return;
  }
  final repo = ref.read(recommendRepositoryProvider);
  if (repo == null) {
    showMusicFlowToast(context, loc.discover_not_connected_library);
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
      showMusicFlowToast(context, loc.discover_import_playlist_failed(msg));
    }
  } finally {
    ref.read(recommendImportingProvider.notifier).state = null;
  }
}

/// 播放平台推荐歌单（封面播放按钮）。
/// - **已入库**：直接反查本地 playlistId 后整单播放，不再导入刷新；
/// - **未入库**：先经 /v1/online/:providerId/recommend/import 幂等导入，
///   拿到真实 library playlistId 再整单播放（与 _openRecommendPlaylist 同链路）。
Future<void> _playRecommendPlaylist(
  WidgetRef ref,
  String? providerId,
  RecommendPlaylist pl,
) async {
  final loc = l10nNow(ref.read(appLanguageProvider).preference);
  if (providerId == null || providerId.isEmpty) {
    NetworkErrorNotifier.show(loc.discover_recommend_service_unavailable);
    return;
  }
  final repo = ref.read(recommendRepositoryProvider);
  if (repo == null) {
    NetworkErrorNotifier.show(loc.discover_not_connected_library);
    return;
  }
  try {
    String? localId;
    if (pl.imported) {
      try {
        localId = await repo.findImportedPlaylistId(providerId, pl.id);
      } catch (_) {
        // 反查失败则回退到导入流程（幂等，无副作用）。
      }
    }
    localId ??= await repo.importRecommendPlaylist(providerId, <String, dynamic>{
      'source': pl.source,
      'id': pl.id,
      'name': pl.name,
      'cover': pl.cover ?? '',
      'creator': pl.creator,
      'trackCount': pl.trackCount,
      'link': pl.link,
    });
    if (localId.isEmpty) {
      NetworkErrorNotifier.show(loc.discover_import_no_valid_id);
      return;
    }
    await playLocalPlaylistById(ref, localId);
  } catch (e) {
    final msg =
        e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
    NetworkErrorNotifier.show(loc.discover_play_playlist_failed(msg));
  }
}

/// 不同插件的平台推荐歌单:整体上下滚动不同平台,
/// 同一平台内歌单横向滑动(与网页一致)。
class PlatformRecommendSection extends ConsumerWidget {
  const PlatformRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final channelsAsync = ref.watch(recommendChannelsProvider);
    final loadFailed = ref.watch(recommendChannelsLoadFailedProvider);
    final providerId = ref.watch(recommendProviderIdProvider).valueOrNull;
    final importingId = ref.watch(recommendImportingProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(
          title: loc.discover_platform_recommend,
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
                title: loc.discover_unavailable_platform,
                description: loc.discover_error_desc_check_route,
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
                          // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                          cacheExtent: 0,
                          padding: EdgeInsets.zero,
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
                                  ? loc.discover_track_count(pl.trackCount)
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
                              // 封面右下角播放按钮：未入库先幂等导入再整单播放。
                              onPlay: isImporting
                                  ? null
                                  : () => _playRecommendPlaylist(
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
              padding: EdgeInsets.zero,
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: loc.discover_platform_load_failed,
            description: loc.discover_error_desc_switch_route,
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
String localChannelTitle(AppLocalizations loc, LocalRecommendChannel channel) {
  final base = channel.name.endsWith(loc.discover_music_suffix)
      ? channel.name.substring(0, channel.name.length - loc.discover_music_suffix.length)
      : channel.name;
  final tag = (channel.subtag != null && channel.subtag!.isNotEmpty)
      ? channel.subtag!
      : loc.discover_local_random;
  return '$base·$tag';
}

/// 本地随机(按平台):由后端 /v1/local-recommend 提供,从本地库按平台随机挑歌单。
/// 与主项目前端一致:歌单均已入库,点击直接打开本地歌单,无需导入刷新。
class LocalPlatformRecommendSection extends ConsumerWidget {
  const LocalPlatformRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final channelsAsync = ref.watch(localRecommendChannelsProvider);
    final loadFailed = ref.watch(localRecommendChannelsLoadFailedProvider);
    // 当前播放来源：识别正在播放的歌单（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(title: loc.discover_local_random),
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
                title: loc.discover_unavailable_local_random,
                description: loc.discover_error_desc_check_route,
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
                        localChannelTitle(loc, channel),
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
                          // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                          cacheExtent: 0,
                          padding: EdgeInsets.zero,
                          itemCount: channel.playlists.length,
                          separatorBuilder: (context, index) =>
                              SizedBox(width: context.musicFlowSpacing.sm),
                          itemBuilder: (context, index) {
                            final pl = channel.playlists[index];
                            return DiscoverPlaylistCard(
                              width: _playlistCardWidth,
                              title: pl.name,
                              subtitle: loc.discover_track_count('${pl.songCount}'),
                              coverArtId: pl.coverArt,
                              isNowPlaying:
                                  queueOrigin?.matchesPlaylist(pl.id) ??
                                  false,
                              onLongPress: () => showPlaylistOptionsSheet(
                                context: context,
                                playlist: Playlist(
                                  id: pl.id,
                                  name: pl.name,
                                  songCount: pl.songCount,
                                  coverArt: pl.coverArt,
                                  duration: 0,
                                ),
                              ),
                              onPlay: () => playLocalPlaylistById(
                            ref,
                            pl.id,
                            coverArtId: pl.coverArt,
                            playlistName: pl.name,
                          ),
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
              padding: EdgeInsets.zero,
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: _playlistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: loc.discover_local_random_load_failed,
            description: loc.discover_error_desc_switch_route,
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(localRecommendChannelsProvider),
          ),
        ),
      ],
    );
  }
}

