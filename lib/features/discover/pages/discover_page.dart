import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, listEquals, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/providers/ui/home_section_layout_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/widgets/main_scaffold.dart';
import 'package:musicflow_client/widgets/visible_remote_retry_scope.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/discover/home_section_registry.dart';
import 'package:musicflow_client/features/discover/pages/home_section_edit_page.dart';
import 'package:musicflow_client/features/discover/widgets/section_shift.dart';
import 'package:musicflow_client/features/discover/widgets/category_nav_bar.dart';
import 'package:musicflow_client/features/discover/widgets/random_songs_section.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_section.dart';

// v5.8.4 大页面拆分子组件：分区 widget 与共用辅助已移至同级文件（行为零变更）。
import 'package:musicflow_client/features/discover/widgets/fixed_recommend_section.dart';
import 'package:musicflow_client/features/discover/widgets/home_search_entry.dart';
import 'package:musicflow_client/features/discover/widgets/local_platform_recommend_section.dart';
import 'package:musicflow_client/features/discover/widgets/platform_recommend_section.dart';
import 'package:musicflow_client/features/discover/widgets/recent_playlists_section.dart';
// v5.8.4 拆分兼容导出：历史测试经本文件引用分区 widget 与播放辅助，其真身已
// 移至上述子文件；保留导出避免既有测试缝合线漂移。
export 'package:musicflow_client/features/discover/discover_page_support.dart';
export 'package:musicflow_client/features/discover/widgets/fixed_recommend_section.dart';
export 'package:musicflow_client/features/discover/widgets/home_search_entry.dart';
export 'package:musicflow_client/features/discover/widgets/local_platform_recommend_section.dart';
export 'package:musicflow_client/features/discover/widgets/platform_recommend_section.dart';
export 'package:musicflow_client/features/discover/widgets/recent_playlists_section.dart';

/// 屏外分区预取错开步长:**首屏(视口 + cacheExtent 内分区)数据全部就绪后**,
/// 才按首页排版顺序逐个触发屏外分区预取 —— 启动阶段的连接池与带宽
/// 全部让给首屏分区,加快启动显示;用户滑到任一分区时数据已在加载或已就绪。
const int _kSectionPrefetchStaggerMs = 100;

/// 首页分区 → 屏外预取触发器(首屏就绪后延迟补齐,v5.8.6)。
///
/// 背景:分区数据 provider 均为 keepAlive FutureProvider,首次被 watch
/// (即分区 widget 首次被 SliverList 构建)时才发起请求。CustomScrollView
/// 的 cacheExtent 只覆盖视口外 400px,更远的分区要等用户滑近才拉取 ——
/// 滑到时才看到 loading。这里在首屏就绪后按排版顺序错开补触发:
///
/// - 触发时机 = 视口 + cacheExtent 内分区的 provider future **全部完成**
///   (见 [_DiscoverPageState._prefetchAfterViewportSettled])。启动阶段
///   绝不与首屏抢带宽:慢网络下等待更久,首屏永远优先;
/// - `ref.read(provider.future)` 对「已在加载/已加载」的 provider **幂等**
///   (返回同一个 future,不会重复请求):等待期只 await 已构建分区(对其
///   read 是无害空转),真正被错开触发的只有屏外分区;
/// - 「随机歌曲」刻意不预取:该区块按需拉取(缓存秒出 + 广播信号触发),
///   整页刷新/预取都不应触发其远程请求(见 [_DiscoverPageState._refresh]);
/// - 「播放控制」无需预取:恒被 hoist 到排版首位 = 恒在首屏,build 即
///   watch;且其 provider 是 autoDispose,无 watcher 的 read 预取会违背
///   「隐藏分区 = 零请求」(R22)的语义。
final Map<String, Future<void> Function(WidgetRef ref)>
_homeSectionPrefetch = <String, Future<void> Function(WidgetRef ref)>{
  'recent-playlists': (ref) => ref.read(recentPlaylistsProvider.future),
  'home-recommend': (ref) => ref.read(homeRecommendSectionProvider.future),
  'local-recommend': (ref) => ref.read(localRecommendChannelsProvider.future),
  'platform-recommend': (ref) => ref.read(recommendChannelsProvider.future),
};

/// 宽屏(无分类导航)时内容区顶部与首个分区之间的间距。
///
/// 取值使「随机歌曲」标题与侧边栏「主页」行落在同一水平线:
/// 侧栏 113 = 头部 64 + 分割线 1 + 列表上边距 16 + 「主页」行半高 32;
/// 内容区 = 搜索条上边距 12 + 搜索条 48 + 本间距 + 分区内边距 4 + 标题半高 24。
/// 即 113 - 88 = 25。
const double kHomeContentTopGap = 25;

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
    case kRemoteControlSectionKey:
      return const RemoteControlSection();
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

/// 分区清单加载失败/未就绪时的回落顺序(与历史首页一致,仅推荐两模块按
/// 新定位排序:「平台推荐」(本地库,local-recommend)在「插件推荐」
/// (platform-recommend)之前)。
// kDefaultHomeSectionKeys / normalizeRecommendSectionOrder / 分区显示名与
// 编辑模式顺序构建已迁至 home_section_registry.dart(首页与编辑页共用)。

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  /// 已调度过屏外预取的分区清单(防重复调度;布局/清单变化后重新调度)。
  List<String>? _prefetchScheduledKeys;

  /// 已进入构建范围(视口 + cacheExtent)的分区 key —— itemBuilder 登记。
  /// 屏外预取的等待期只 await 这些分区的数据就绪(对其 read 幂等空转,
  /// 不重复请求);未构建的屏外分区绝不提前触发(v5.8.6 启动加速)。
  final Set<String> _builtSectionKeys = <String>{};

  /// 本轮错开预取的 Timer 收口:State dispose(或重新调度)时撤销未触发的
  /// Timer,避免 widget test 判定「Timer is still pending」与孤儿回调。
  final List<Timer> _prefetchTimers = <Timer>[];

  /// 首帧后安排屏外分区预取(**首屏数据全部就绪后才启动**,v5.8.6)。
  ///
  /// 首帧内 SliverList 只构建视口 + cacheExtent 范围内的分区,这些分区在
  /// build 中 watch provider 即时拉取 = 首屏分区立即触发,启动带宽全部
  /// 用于首屏;更远的分区由 [_prefetchAfterViewportSettled] 在首屏就绪后
  /// 按排版顺序错开补触发(详见 [_homeSectionPrefetch])。
  /// 调度以「可见分区清单」为键去重:用户编辑布局/清单变化后重新调度。
  void _scheduleSectionPrefetch(List<String> keys) {
    if (listEquals(_prefetchScheduledKeys, keys)) return;
    _prefetchScheduledKeys = List<String>.of(keys);
    // 重新调度前撤销上一轮未触发的错开 Timer(已触发的 cancel 无害),
    // 避免新旧两轮预取叠加,也保证 State dispose 后无孤儿 Timer。
    for (final timer in _prefetchTimers) {
      timer.cancel();
    }
    _prefetchTimers.clear();
    // 重新调度 = 布局/清单变化:已构建分区集合随之重建,由 itemBuilder
    // 在新一轮构建中重新登记。
    _builtSectionKeys.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_prefetchAfterViewportSettled(keys));
    });
  }

  /// 等**首屏分区数据全部就绪**,再按排版顺序错开预取屏外分区。
  ///
  /// 「首屏就绪」的判定:只 await 已进入构建范围(视口 + cacheExtent,
  /// 由 itemBuilder 登记,见 [_builtSectionKeys])的分区 —— 这些分区的
  /// provider 已被 watch,对其 `ref.read(provider.future)` 是幂等空转
  /// (返回同一个 future,不会重复请求);**屏外分区不进集合**,其请求
  /// 绝不会在首屏就绪前发出。这样启动阶段(首屏 loading 期间)连接池
  /// 与带宽全部让给首屏,冷启动显示最快;首屏出齐后的空闲期再补齐
  /// 屏外,用户滑到即秒出。
  Future<void> _prefetchAfterViewportSettled(List<String> keys) async {
    final pending = <Future<void>>[];
    for (final key in keys) {
      if (!_builtSectionKeys.contains(key)) continue; // 屏外:不碰,不提前触发
      final prefetch = _homeSectionPrefetch[key];
      if (prefetch == null) continue; // random-songs/remote-control 无预取项
      // 已构建分区 = 已 watch:read 幂等空转。失败 future 也要放行等待期
      // (失败分区不应阻塞屏外预取),逐个吞掉错误。
      pending.add(prefetch(ref).then((_) {}, onError: (Object _) {}));
    }
    await Future.wait(pending);
    if (!mounted) return;
    for (final entry in keys.indexed) {
      final key = entry.$2;
      // 视口内分区已就绪(或正在渲染),只补屏外分区;random-songs /
      // remote-control 无预取项自然跳过。
      if (_builtSectionKeys.contains(key)) continue;
      final prefetch = _homeSectionPrefetch[key];
      if (prefetch == null) continue;
      // 排版序 × 步长错开:排在前面的先发(加载优先级跟随排版顺序)。
      _prefetchTimers.add(
        Timer(
          Duration(milliseconds: _kSectionPrefetchStaggerMs * entry.$1),
          () {
            if (!mounted) return;
            unawaited(prefetch(ref));
          },
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final timer in _prefetchTimers) {
      timer.cancel();
    }
    _prefetchTimers.clear();
    super.dispose();
  }

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

  /// 打开首页分区编辑页（拖拽排序 + 显隐开关；保存后本页经 provider
  /// 状态即时重建，隐藏分区随之停止拉取）。
  void _openHomeSectionEditPage(BuildContext context) {
    Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(
        context: context,
        builder: (context) => const HomeSectionEditPage(),
      ),
    );
  }

  /// 首页分区列表最末的「编辑首页模块」入口（客户端自治入口，安静样式，
  /// 不与内容分区抢视觉焦点）。
  Widget _buildHomeSectionEditEntry(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    return Center(
      child: MusicFlowPressable(
        semanticLabel: loc.home_section_customize_entry,
        onPressed: () => _openHomeSectionEditPage(context),
        borderRadius: context.musicFlowRadii.pill,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(AppIcons.settings, size: 16, color: colors.muted),
              SizedBox(width: spacing.xs),
              Text(
                loc.home_section_customize_entry,
                style: context.musicFlowTypography.label
                    .copyWith(color: colors.muted),
              ),
            ],
          ),
        ),
      ),
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
    // 客户端自治分区:无论服务端清单含不含「播放控制」块都注入并置顶。
    // 该块是纯客户端能力,后端没有对应数据源,等后端下发会让存量用户永远
    // 拿不到它。用户的隐藏与排序仍由下面的 applyHomeSectionLayout 兜住。
    final baseSectionKeys = injectClientOwnedSection(
      normalizeRecommendSectionOrder(
        orderedKeys.isEmpty ? kDefaultHomeSectionKeys : orderedKeys,
      ),
    );
    // 客户端自治:用户本地布局覆盖服务端清单 —— 顺序以用户排序优先
    // (服务端新增分区追加尾部),用户隐藏的分区不渲染(分区 widget 不构建,
    // 其数据 provider 无人 watch,自然不会向服务端拉取)。
    final userLayout = ref.watch(homeSectionLayoutProvider).valueOrNull ??
        HomeSectionLayout.empty;
    // 存量用户保护:applyHomeSectionLayout 的语义是「未排过 → 追加尾部」,
    // 老用户升级后「播放控制」属于未排过 → 会被沉到尾部。hoist 覆盖该语义
    // (仅在该 key 未被用户排过时生效;用户排过则尊重用户位置)。
    final sectionKeys = hoistClientOwnedSection(
      applyHomeSectionLayout(baseSectionKeys, userLayout),
      userLayout,
    );
    final sectionWidgets = <String, Widget>{};
    for (final key in sectionKeys) {
      final sectionWidget = _homeSectionWidget(key);
      if (sectionWidget == null) continue;
      sectionWidgets[key] = sectionWidget;
    }
    final visibleSectionKeys = sectionWidgets.keys.toList();
    // 视口优先加载:首屏分区已随首帧 build 即时拉取(启动带宽全给首屏,
    // 加快启动显示);屏外分区等首屏数据全部就绪后,才按排版顺序错开
    // 补触发(见 _scheduleSectionPrefetch)。
    _scheduleSectionPrefetch(visibleSectionKeys);
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
                HomeSearchEntry(),
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
                            itemCount: visibleSectionKeys.length + 1,
                            // KeyedSubtree 保证分区顺序变化时各分区(尤其状态型 RandomSongsSection)状态稳定。
                            itemBuilder: (context, index) {
                              // 列表最末:客户端自治入口 —— 打开首页分区编辑页
                              // (拖拽排序 + 显隐开关,用户手动管理首页模块)。
                              if (index == visibleSectionKeys.length) {
                                return _buildHomeSectionEditEntry(context);
                              }
                              final key = visibleSectionKeys[index];
                              // 登记已构建分区(视口 + cacheExtent 范围):
                              // 屏外预取的等待期只等这些分区的数据就绪,
                              // 不碰任何屏外分区(见 _builtSectionKeys)。
                              _builtSectionKeys.add(key);
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
