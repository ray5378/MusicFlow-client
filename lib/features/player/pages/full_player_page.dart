import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/features/player/widgets/song_info_page.dart';
import 'package:musicflow_client/features/player/widgets/vinyl_record_cover.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

import 'package:musicflow_client/features/player/widgets/full_player_chrome.dart';
import 'package:musicflow_client/features/player/widgets/playback_controls.dart';
import 'package:musicflow_client/features/player/widgets/player_lyrics_pane.dart';
import 'package:musicflow_client/features/player/widgets/player_progress_bar.dart';
import 'package:musicflow_client/features/player/widgets/player_utility_bar.dart';
// v5.8.4 拆分兼容导出：历史测试经本文件引用这两个公开控件，其真身已移至
// 上方 widgets/ 子文件；保留 show 导出，避免既有测试缝合线漂移。
export 'package:musicflow_client/features/player/widgets/playback_controls.dart'
    show PlaybackControls;
export 'package:musicflow_client/features/player/widgets/player_progress_bar.dart'
    show ProgressBar;

/// MusicFlow's immersive now-playing scene.
class FullPlayerPage extends ConsumerStatefulWidget {
  const FullPlayerPage({super.key});

  @override
  ConsumerState<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends ConsumerState<FullPlayerPage>
    with TickerProviderStateMixin {
  bool _isClosingRoute = false;

  /// 三页滑页控制器：[歌词页(0), 封面+控件页(1), 歌曲信息页(2)]，首屏停在封面页。
  /// 手指左滑翻向更高下标——从封面左滑进歌曲信息页，右滑回歌词页。
  late final PageController _pageController;
  Animation<double> _routeForegroundOpacity =
      const AlwaysStoppedAnimation<double>(1);
  CurvedAnimation? _routeForegroundCurvedAnimation;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = context.musicFlowMotion;

    _routeForegroundCurvedAnimation?.dispose();
    final routeAnimation = ModalRoute.of(context)?.animation;
    if (routeAnimation == null) {
      _routeForegroundCurvedAnimation = null;
      _routeForegroundOpacity = const AlwaysStoppedAnimation<double>(1);
    } else {
      final foregroundOpacity = CurvedAnimation(
        parent: routeAnimation,
        curve: Interval(0.08, 0.82, curve: motion.easeOut),
        // On pop, fade every non-Hero control out during the first 75% of the
        // route flight. The flipped curve makes the exit decisive up front and
        // prevents any foreground control from flashing on the final frame.
        reverseCurve: Interval(0.25, 1, curve: motion.easeOut.flipped),
      );
      _routeForegroundCurvedAnimation = foregroundOpacity;
      _routeForegroundOpacity = foregroundOpacity;
    }
  }

  @override
  void dispose() {
    // 大屏前台门控（黑胶旋转 / 大屏歌词渲染）已参数化：由页面显式传给
    // VinylRecordCover / SyncedLyricsView，页面卸载即组件销毁、动画控制器
    // dispose 自然停转——无需（也不能）在 dispose 写 provider
    // （Riverpod 禁止 unmount 期间同步改 provider）。
    _routeForegroundCurvedAnimation?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _closeToMini() {
    if (_isClosingRoute || !mounted) return;
    _isClosingRoute = true;
    Navigator.of(context).pop();
  }

  String _buildSubtitle(Song song) {
    final artist = song.artist?.trim() ?? '';
    final album = song.album?.trim() ?? '';
    if (artist.isNotEmpty && album.isNotEmpty) return '$artist · $album';
    if (artist.isNotEmpty) return artist;
    return album;
  }

  /// 打开播放队列：移动端走底部弹窗，桌面端走右侧面板开关。
  void _openQueue() {
    if (context.musicFlowWindowClass == MusicFlowWindowClass.compact) {
      unawaited(showPlayQueueSheet(context: context));
    } else {
      toggleRightQueuePanel(context: context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final currentSong = ref.watch(
      playerProvider.select((state) => state.currentSong),
    );

    if (currentSong == null) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: context.musicFlowColors.canvas,
          body: SafeArea(
            child: Column(
              children: <Widget>[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: EdgeInsets.all(context.musicFlowSpacing.xs),
                    child: Tooltip(
                      message: loc.player_close,
                      waitDuration: const Duration(milliseconds: 400),
                      child: MusicFlowIconButton(
                        icon: AppIcons.chevronDown,
                        label: loc.player_close,
                        onPressed: _closeToMini,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: MusicFlowEmptyState(
                    title: loc.player_empty_title,
                    description: loc.player_empty_desc,
                    icon: AppIcons.music,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final visuals = ref.watch(resolvedCurrentSongMediaVisualsProvider);
    final subtitle = _buildSubtitle(currentSong);
    final foregroundBrightness = visuals.foreground.computeLuminance() > 0.5
        ? Brightness.light
        : Brightness.dark;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: foregroundBrightness,
      statusBarBrightness: foregroundBrightness == Brightness.light
          ? Brightness.dark
          : Brightness.light,
      systemNavigationBarColor: visuals.stageBottom,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: foregroundBrightness,
    );

    return MusicFlowMediaColorScope(
      visuals: visuals,
      role: MusicFlowMediaSurfaceRole.stage,
      child: Builder(
        builder: (context) {
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: overlayStyle,
            child: PopScope<void>(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop) _closeToMini();
              },
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: Hero(
                        tag: playerBackgroundHeroTag,
                        flightShuttleBuilder:
                            playerBackgroundFlightShuttleBuilder,
                        child: RepaintBoundary(
                          child: MusicFlowPlayerBackdrop(
                            visuals: visuals,
                            mode: MusicFlowPlayerBackdropMode.stage,
                          ),
                        ),
                      ),
                    ),
                    _buildRouteForeground(
                      child: SafeArea(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // 布局断点区分「触屏 / 桌面」:安卓/iOS 平板即使横屏
                            // 或够宽,也保持触屏友好的竖版布局;只有桌面(键鼠/指针)
                            // 平台才启用「封面+右侧常驻歌词」的分栏大屏布局,
                            // 避免单纯按尺寸一刀切。
                            final isTouchLike = switch (Theme.of(
                              context,
                            ).platform) {
                              TargetPlatform.android ||
                              TargetPlatform.iOS => true,
                              _ => false,
                            };
                            final wideAvailable =
                                constraints.maxWidth > constraints.maxHeight ||
                                constraints.maxWidth >=
                                    context.musicFlowBreakpoints.expanded;
                            final useWideLayout = !isTouchLike && wideAvailable;
                            return useWideLayout
                                ? _buildWidePlayerLayout(
                                    currentSong,
                                    subtitle: subtitle,
                                  )
                                : _buildPortraitPlayerLayout(
                                    currentSong,
                                    subtitle: subtitle,
                                  );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRouteForeground({required Widget child}) {
    return FadeTransition(
      key: const ValueKey<String>('full_player_foreground_transition'),
      opacity: _routeForegroundOpacity,
      child: child,
    );
  }

  Widget _buildPortraitPlayerLayout(Song song, {required String subtitle}) {
    final visuals = ref.watch(resolvedCurrentSongMediaVisualsProvider);
    // 方案 A 自适应暖黄：对三段舞台底色保 4.5:1——暗底保持纯黄(参考截图观感)，
    // 亮底自动朝前景墨色加深，任何封面都可读。基色与 MINI 播放条共用。
    final lyricAccent = MusicFlowMediaVisuals.lyricAccentFor(
      visuals,
      backgrounds: <Color>[
        visuals.stageGlow,
        visuals.stageBase,
        visuals.stageBottom,
      ],
    );
    return Column(
      key: const ValueKey<String>('full_player_portrait_layout'),
      children: <Widget>[
        PlayerTopBar(controller: _pageController, onClose: _closeToMini),
        Expanded(
          child: PageView(
            controller: _pageController,
            physics: const BouncingScrollPhysics(),
            children: <Widget>[
              // 页 0：歌曲信息页（从封面右滑到达）。
              SongInfoPage(song: song),
              // 页 1：封面 + 播放控件页（默认首屏）。
              _buildCoverStagePage(song, subtitle: subtitle),
              // 页 2：歌词页（从封面左滑到达）。
              PlayerLyricsPane(activeColor: lyricAccent),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWidePlayerLayout(Song song, {required String subtitle}) {
    final spacing = context.musicFlowSpacing;
    final horizontalPadding =
        context.musicFlowWindowClass == MusicFlowWindowClass.compact
        ? spacing.md
        : context.musicFlowPageHorizontalPadding;

    return GestureDetector(
      key: const ValueKey<String>('full_player_wide_layout'),
      onTap: _closeToMini,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: <Widget>[
          // 主内容:整体垂直居中,不产生上沿白边。
          Center(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: context.musicFlowBreakpoints.maxContentWidth * 1.2,
              ),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                0, // 顶内边距=0:内容从窗口最顶端(y=0)起,消除浅色舞台上沿露出的白色细边
                horizontalPadding,
                spacing.md,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columnGap = spacing.lg;
                  final leftRightGap = spacing.xl;
                  final availableWidth =
                      constraints.maxWidth - columnGap - leftRightGap;
                  final rightPaneWidth = (availableWidth * 0.44)
                      .clamp(320.0, 540.0)
                      .toDouble();
                  final leftPaneWidth = availableWidth - rightPaneWidth;

                  // crossAxisAlignment.stretch 让左右两栏都有界高,
                  // 内部用 Expanded 分摊,杜绝无界高度导致控件溢出隐藏。
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // 左栏:封面上部 → 「歌名模块 + 播放控件」整体下移靠拢封面。
                      // 与上一版相比:顶部留白减少(封面上移),底部新增留白把
                      // 歌名/控件作为一个整体往上托,不再贴底。
                      // 矮视口(横屏小窗)下退回旧比例并取消底部留白,保证控件不被推出视口。
                      SizedBox(
                        key: const ValueKey<String>('full_player_artwork_pane'),
                        width: leftPaneWidth,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final compactHeight = constraints.maxHeight < 460;
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                // 顶部留白:把封面定位在左栏偏上区域(而非视口中段)。
                                Spacer(flex: compactHeight ? 3 : 2),
                                Expanded(
                                  flex: compactHeight ? 9 : 8,
                                  child: _buildWideArtworkPane(song),
                                ),
                                SizedBox(height: spacing.md),
                                // 歌曲信息 + 播放控件作为一个整体：信息区过长时内部滚动，
                                // 控件始终固定在该整体底部，整体随底部留白一起上移。
                                // 矮视口保持旧结构：详情可滚动，控件固定在最底部，
                                // 避免被挤出视口。正常/大屏高度下把歌名+控件作为整体，
                                // 并用底部留白把该整体上移。
                                if (compactHeight)
                                  Flexible(
                                    flex: 4,
                                    child: SingleChildScrollView(
                                      child: _buildWideDetailsPane(
                                        song,
                                        subtitle: subtitle,
                                      ),
                                    ),
                                  )
                                else
                                  Flexible(
                                    flex: 5,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        Flexible(
                                          child: SingleChildScrollView(
                                            child: _buildWideDetailsPane(
                                              song,
                                              subtitle: subtitle,
                                            ),
                                          ),
                                        ),
                                        SizedBox(height: spacing.xs),
                                        _buildControlPanel(song, compact: true),
                                      ],
                                    ),
                                  ),
                                if (compactHeight) ...<Widget>[
                                  SizedBox(height: spacing.xs),
                                  // 矮视口下控件固定在最底部，不被 Flexible 挤压。
                                  _buildControlPanel(song, compact: true),
                                ] else ...<Widget>[
                                  SizedBox(height: spacing.xs),
                                  // 底部留白:把「歌名+控件」整体上移,避免贴底。
                                  const Spacer(flex: 2),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                      SizedBox(width: leftRightGap),
                      // 右栏:常驻歌词,顶部对齐
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: columnGap),
                          child: Align(
                            key: const ValueKey<String>(
                              'full_player_details_pane',
                            ),
                            alignment: Alignment.topCenter,
                            child: const PlayerLyricsPane(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          // 顶层:整条顶部横幅可拖拽移动窗口(与正常标题栏一致)。置于内容之上,
          // 点击不关闭播放器;音量已并入底部播放控件,顶栏不再悬浮按钮。
          if (isWindowsDesktop)
            const Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: 36,
              child: WideDragBanner(),
            ),
        ],
      ),
    );
  }

  Widget _buildWideArtworkPane(Song song) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = context.musicFlowSpacing;
        final maxCoverByWidth = (constraints.maxWidth - spacing.xs * 2).clamp(
          0.0,
          520.0,
        );
        final maxCoverByHeight = (constraints.maxHeight - spacing.xs * 2).clamp(
          0.0,
          520.0,
        );
        final coverSize = maxCoverByWidth < maxCoverByHeight
            ? maxCoverByWidth
            : maxCoverByHeight;

        return Center(child: _buildCoverHero(song, coverSize, opacity: 1.0));
      },
    );
  }

  Widget _buildWideDetailsPane(Song song, {required String subtitle}) {
    final typography = context.musicFlowTypography;
    // 歌名取色与 MINI 播放器歌名一致：媒体作用域 ink（= visuals.foreground，
    // 随封面前景自动取色）；副标题用 muted，与 MINI「歌名 - 歌手」的层级一致。
    final titleStyle = typography.headline.copyWith(
      fontSize: (typography.headline.fontSize ?? 19) * 2,
      color: context.musicFlowColors.ink,
    );
    final subtitleStyle = typography.body.copyWith(
      fontSize: (typography.body.fontSize ?? 13) * 2,
      color: context.musicFlowColors.muted,
    );

    // 不用 Center 包裹:Center 在 Column 的 loose 约束下会撑满整栏高度,
    // 把底部播放控件挤出视口。信息改为自身最小高度,紧贴封面下方。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildSongIdentity(
          song: song,
          subtitle: subtitle,
          titleStyle: titleStyle,
          subtitleStyle: subtitleStyle,
          textAlign: TextAlign.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          titleMaxLines: 2,
          subtitleMaxLines: 2,
          overflow: TextOverflow.ellipsis,
          scrollable: false,
        ),
      ],
    );
  }

  /// 首屏（页 1）：黑胶封面（弹性居中）→ 歌名/歌手 → 当前歌词行 → 控制面板。
  ///
  /// 文本顺序按确认稿：歌名-歌手在上，歌词行在下；封面尺寸由剩余空间夹取，
  /// 任何字号/机型下都不会溢出。
  Widget _buildCoverStagePage(Song song, {required String subtitle}) {
    final spacing = context.musicFlowSpacing;
    final typography = context.musicFlowTypography;
    final horizontalPadding =
        context.musicFlowWindowClass == MusicFlowWindowClass.compact
        ? spacing.lg
        : spacing.xl;
    final titleStyle = typography.headline.copyWith(
      // 层级外特殊值：封面页大标题介于 display(26) 与 headline(19) 之间，
      // 无对应 token，按 display 派生（-2 = 24，值不变，随 token 漂移）。
      fontSize: (typography.display.fontSize ?? 26) - 2,
      color: context.musicFlowColors.ink,
    );
    final subtitleStyle = typography.body.copyWith(
      fontSize: typography.title.fontSize ?? 15,
      color: context.musicFlowColors.muted,
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxByWidth = constraints.maxWidth.clamp(0.0, 400.0);
                final maxByHeight = constraints.maxHeight.clamp(0.0, 400.0);
                final coverSize = maxByWidth < maxByHeight
                    ? maxByWidth
                    : maxByHeight;
                return Center(
                  child: _buildCoverHero(song, coverSize, opacity: 1),
                );
              },
            ),
          ),
          _buildSongIdentity(
            song: song,
            subtitle: subtitle,
            titleStyle: titleStyle,
            subtitleStyle: subtitleStyle,
            titleMaxLines: 2,
            subtitleMaxLines: 2,
            overflow: TextOverflow.ellipsis,
            scrollable: false,
          ),
          SizedBox(height: spacing.sm),
          const CurrentLyricLine(),
          SizedBox(height: spacing.lg),
          _buildControlPanel(song),
        ],
      ),
    );
  }

  Widget _buildCoverHero(Song song, double size, {double opacity = 1}) {
    return Opacity(
      key: const ValueKey<String>('full_player_cover'),
      opacity: opacity,
      child: Hero(
        tag: playerCoverHeroTag,
        createRectTween: playerCoverRectTween,
        child: Builder(
          builder: (context) {
            return RepaintBoundary(
              child: VinylRecordCover(
                song: song,
                size: size,
                showVinylEffect: true,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSongIdentity({
    required Song song,
    required String subtitle,
    required TextStyle titleStyle,
    required TextStyle subtitleStyle,
    TextAlign textAlign = TextAlign.center,
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.center,
    int? titleMaxLines,
    int? subtitleMaxLines,
    TextOverflow? overflow,
    bool scrollable = true,
  }) {
    final identity = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      children: <Widget>[
        Hero(
          tag: playerTitleHeroTag,
          createRectTween: playerLinearRectTween,
          flightShuttleBuilder: playerTextFlightShuttleBuilder,
          child: Material(
            type: MaterialType.transparency,
            child: Text(
              song.title,
              style: titleStyle,
              textAlign: textAlign,
              maxLines: titleMaxLines,
              overflow: overflow,
            ),
          ),
        ),
        if (subtitle.isNotEmpty) ...<Widget>[
          SizedBox(height: context.musicFlowSpacing.xxs),
          Hero(
            tag: playerSubtitleHeroTag,
            createRectTween: playerLinearRectTween,
            flightShuttleBuilder: playerTextFlightShuttleBuilder,
            child: Material(
              type: MaterialType.transparency,
              child: Text(
                subtitle,
                style: subtitleStyle,
                textAlign: textAlign,
                maxLines: subtitleMaxLines,
                overflow: overflow,
              ),
            ),
          ),
        ],
      ],
    );

    if (!scrollable) return identity;
    return SingleChildScrollView(
      primary: false,
      physics: const ClampingScrollPhysics(),
      child: identity,
    );
  }

  Widget _buildControlPanel(Song song, {bool compact = false}) {
    final spacing = context.musicFlowSpacing;
    final content = Column(
      key: const ValueKey<String>('full_player_control_panel'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        PlayerUtilityBar(
          key: const ValueKey<String>('full_player_utility_bar'),
          currentSong: song,
        ),
        SizedBox(height: compact ? spacing.xxs : spacing.sm),
        const ProgressBar(),
        SizedBox(height: compact ? spacing.xxs : spacing.sm),
        PlaybackControls(
          key: const ValueKey<String>('full_player_transport_controls'),
          compact: compact,
          onOpenQueue: _openQueue,
        ),
      ],
    );

    if (compact) return content;

    final horizontalPadding =
        context.musicFlowWindowClass == MusicFlowWindowClass.compact
        ? spacing.md
        : spacing.xl;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        spacing.xs,
        horizontalPadding,
        spacing.sm,
      ),
      child: content,
    );
  }
}
