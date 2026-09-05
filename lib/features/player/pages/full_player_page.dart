import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/song.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/dlna_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/frozen_playback_provider.dart';
import '../../../providers/lyrics_cover_provider.dart';
import '../../../providers/palette_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/sleep_timer_provider.dart';
import '../widgets/mini_player.dart' show PlayerSwitcherSheet, VolumeButton;
import '../widgets/local_dlna_cast_sheet.dart';
import '../widgets/play_queue_sheet.dart';
import '../widgets/player_hero_helpers.dart';
import '../widgets/player_scrubber.dart';
import '../widgets/song_info_page.dart';
import '../widgets/synced_lyrics_view.dart';
import '../widgets/vinyl_record_cover.dart';
import '../../../widgets/windows_title_bar.dart';
import '../../../l10n/generated/app_localizations.dart';

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

  void _showMessage(
    String message, {
    MusicFlowMessageKind kind = MusicFlowMessageKind.info,
  }) {
    if (!mounted) return;
    showMusicFlowMessage(context, message, kind: kind);
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
        _PlayerTopBar(controller: _pageController, onClose: _closeToMini),
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
              _PlayerLyricsPane(activeColor: lyricAccent),
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
                            child: const _PlayerLyricsPane(),
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
              child: _WideDragBanner(),
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
      fontSize: 24,
      color: context.musicFlowColors.ink,
    );
    final subtitleStyle = typography.body.copyWith(
      fontSize: 15,
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
          const _CurrentLyricLine(),
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
        _PlayerUtilityBar(
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

class _WideDragBanner extends StatelessWidget {
  const _WideDragBanner();

  Future<void> _invoke(String method) async {
    try {
      await kWindowsWindowChannel.invokeMethod<void>(method);
    } on PlatformException {
      // 窗口控制失败不影响播放。
    } on MissingPluginException {
      // 非 Windows 平台无对应原生实现。
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 单击吞掉(不触发外层 onTap=_closeToMini),仅拖拽/双击交给窗口。
      onTap: () {},
      onPanStart: (_) => _invoke('start_move'),
      onDoubleTap: () => _invoke('maximize_toggle'),
      child: const SizedBox.expand(),
    );
  }
}

class _PlayerTopBar extends StatelessWidget {
  const _PlayerTopBar({required this.controller, required this.onClose});

  final PageController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.musicFlowSpacing.xs),
      child: SizedBox(
        height: 56,
        child: Row(
          children: <Widget>[
            _PlayerIconButton(
              icon: AppIcons.chevronDown,
              label: loc.player_collapse,
              onPressed: onClose,
            ),
            Expanded(
              child: Center(child: _PageDots(controller: controller)),
            ),
            // 右侧对称占位:与左侧收起按钮等宽,保证圆点指示器水平居中。
            const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }
}

/// 三等宽圆点页签指示器：与 [PageController] 实时联动，滑动时亮度平滑插值。
/// 顺序与页面一致（左→右 = 歌词页 / 封面页 / 信息页）。
class _PageDots extends StatelessWidget {
  const _PageDots({required this.controller});

  static const double _dotSize = 6;
  static const double _dotGap = 6;

  final PageController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final ink = context.musicFlowColors.ink;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final page = controller.hasClients
            ? (controller.page ?? controller.initialPage.toDouble())
            : controller.initialPage.toDouble();
        final activeIndex = page.round().clamp(0, 2);
        return Semantics(
          label: loc.player_page_dots(activeIndex + 1, 3),
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var index = 0; index < 3; index += 1) ...<Widget>[
                  if (index > 0) const SizedBox(width: _dotGap),
                  Opacity(
                    opacity:
                        0.38 +
                        0.62 * (1 - (page - index).abs()).clamp(0.0, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: ink,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox.square(dimension: _dotSize),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PlayerLyricsPane extends ConsumerWidget {
  const _PlayerLyricsPane({this.activeColor});

  final Color? activeColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(currentLyricsProvider);
    final loc = AppLocalizations.of(context);
    // 高亮颜色跟随当前主题强调色；未显式指定时不再使用硬编码黄色。
    final lyricActiveColor = activeColor ?? context.musicFlowColors.accent;
    // RepaintBoundary：歌词列表即便发生重建/滚动，也只重绘本窗格，不扩散整页。
    return RepaintBoundary(
      child: lyricsAsync.when(
        data: (lyrics) {
          if (lyrics == null || lyrics.isEmpty) {
            return _PlayerLyricsMessage(
              icon: AppIcons.lyrics,
              title: loc.player_no_lyrics_title,
              description: loc.player_no_lyrics_desc,
            );
          }
          final bestLyrics = lyrics.getBest();
          if (bestLyrics == null) {
            return _PlayerLyricsMessage(
              icon: AppIcons.lyrics,
              title: loc.player_no_lyrics_title,
              description: loc.player_no_lyrics_desc,
            );
          }
          return SyncedLyricsView(
            lyrics: bestLyrics,
            // 大屏前台门控参数化：本页即大屏，显式开启歌词渲染。
            fullPlayerActive: true,
            activePrimaryColor: lyricActiveColor,
            activeSecondaryColor: lyricActiveColor,
            inactivePrimaryColor: context.musicFlowColors.muted,
            inactiveSecondaryColor: context.musicFlowColors.muted,
          );
        },
        loading: () => const _PlayerLyricsLoading(),
        error: (error, stackTrace) => _PlayerLyricsMessage(
          icon: AppIcons.error,
          title: loc.player_lyrics_load_failed_title,
          description: loc.player_lyrics_load_failed_desc,
          actionLabel: loc.widgets_retry,
          onAction: () => ref.invalidate(currentLyricsProvider),
        ),
      ),
    );
  }
}

/// 首屏的当前歌词行：歌名-歌手下方，1–2 行居中，muted 色（参考截图样式）。
/// 无歌词或未同步时整体隐藏，不占位。
class _CurrentLyricLine extends ConsumerWidget {
  const _CurrentLyricLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(currentLyricsProvider);
    // 用冻结进度：窗口不可见时当前歌词行不再随播放推进而重建。
    final position = ref.watch(frozenPositionProvider);
    // RepaintBoundary：首屏歌词行虽随进度 200~500ms 重建，但重绘隔离在本行内，
    // 不连带整页（含黑胶/背景）重绘。
    return RepaintBoundary(
      child: lyricsAsync.when(
        data: (lyrics) {
          if (lyrics == null || lyrics.isEmpty) {
            return const SizedBox.shrink();
          }
          final best = lyrics.getBest();
          if (best == null || !best.synced || best.lines.isEmpty) {
            return const SizedBox.shrink();
          }
          final index = syncedLyricIndexFor(best, position);
          final (primary, secondary) = lyricLineParts(best.lines[index].value);
          if (primary.isEmpty && (secondary?.isEmpty ?? true)) {
            return const SizedBox.shrink();
          }
          final muted = context.musicFlowColors.muted;
          final typography = context.musicFlowTypography;
          final duration = context.musicFlowMotion.resolve(
            context,
            context.musicFlowMotion.state,
          );
          return AnimatedSwitcher(
            duration: duration,
            child: Column(
              key: ValueKey<int>(index),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (primary.isNotEmpty)
                  Text(
                    primary,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.body.copyWith(fontSize: 15, color: muted),
                  ),
                if (secondary != null && secondary.isNotEmpty) ...<Widget>[
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(
                    secondary,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typography.body.copyWith(
                      fontSize: 13,
                      color: muted.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        loading: () => const SizedBox.shrink(),
        error: (Object error, StackTrace stackTrace) => const SizedBox.shrink(),
      ),
    );
  }
}

class _PlayerLyricsMessage extends StatelessWidget {
  const _PlayerLyricsMessage({
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.musicFlowSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              liveRegion: true,
              label: '$title，$description',
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 32, color: context.musicFlowColors.ink),
                    SizedBox(height: context.musicFlowSpacing.sm),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: context.musicFlowTypography.title.copyWith(
                        color: context.musicFlowColors.ink,
                      ),
                    ),
                    SizedBox(height: context.musicFlowSpacing.xs),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: context.musicFlowTypography.body.copyWith(
                        color: context.musicFlowColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              SizedBox(height: context.musicFlowSpacing.lg),
              MusicFlowButton.secondary(
                label: actionLabel!,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlayerLyricsLoading extends StatelessWidget {
  const _PlayerLyricsLoading();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      label: loc.player_lyrics_loading,
      child: ExcludeSemantics(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final width in <double>[220, 280, 196, 250]) ...<Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.musicFlowColors.ink.withValues(alpha: 0.18),
                    borderRadius: context.musicFlowRadii.detail,
                  ),
                  child: SizedBox(width: width, height: 16),
                ),
                SizedBox(height: context.musicFlowSpacing.md),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Buffered playback progress with a 48dp interaction target.
class ProgressBar extends ConsumerStatefulWidget {
  const ProgressBar({super.key});

  @override
  ConsumerState<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends ConsumerState<ProgressBar>
    with SingleTickerProviderStateMixin {
  double? _dragValue;
  String? _dragSongId;
  late final AnimationController _loadingOpacityController;
  late final Animation<double> _loadingOpacity;
  bool _isLoadingPulseActive = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _loadingOpacityController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _loadingOpacity = Tween<double>(begin: 1, end: 0.52).animate(
      CurvedAnimation(
        parent: _loadingOpacityController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = context.musicFlowReduceMotion;
    if (_reduceMotion) {
      _loadingOpacityController
        ..stop()
        ..value = 0;
      _isLoadingPulseActive = false;
    }
  }

  @override
  void dispose() {
    _loadingOpacityController.dispose();
    super.dispose();
  }

  void _syncLoadingPulse(bool shouldPulse) {
    final resolved = shouldPulse && !_reduceMotion;
    if (resolved == _isLoadingPulseActive) return;
    _isLoadingPulseActive = resolved;
    if (resolved) {
      _loadingOpacityController.repeat(reverse: true);
    } else {
      _loadingOpacityController
        ..stop()
        ..value = 0;
    }
  }

  void _clearSeekSession() {
    _dragValue = null;
    _dragSongId = null;
  }

  void _cancelSeekSession() {
    if (_dragValue == null && _dragSongId == null) return;
    setState(_clearSeekSession);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    ref.listen<String?>(
      playerProvider.select((state) => state.currentSong?.id),
      (previous, next) {
        if (previous != next) _cancelSeekSession();
      },
    );
    final songAndBuffer = ref.watch(
      playerProvider.select(
        (state) => (
          songId: state.currentSong?.id,
          buffered: state.bufferedPosition,
          processing: state.processingState,
        ),
      ),
    );
    // 冻结进度：窗口不可见时进度条不再随播放推进而重建（省掉 200~500ms
    // 一次的高频重建与重绘）；可见时与真实进度完全一致。
    final effectivePosition = ref.watch(frozenPositionProvider);
    final effectiveDuration = ref.watch(effectiveDurationProvider);
    final state = (
      songId: songAndBuffer.songId,
      position: effectivePosition,
      duration: effectiveDuration,
      buffered: songAndBuffer.buffered,
      processing: songAndBuffer.processing,
    );
    final isLoading =
        state.processing == ProcessingState.loading ||
        state.processing == ProcessingState.buffering;
    _syncLoadingPulse(isLoading);

    final maxMilliseconds = state.duration.inMilliseconds > 0
        ? state.duration.inMilliseconds.toDouble()
        : 1.0;
    final activeDragValue = _dragSongId == state.songId ? _dragValue : null;
    final sliderValue =
        (activeDragValue ?? state.position.inMilliseconds.toDouble()).clamp(
          0.0,
          maxMilliseconds,
        );
    final bufferedValue = state.buffered.inMilliseconds
        .toDouble()
        .clamp(0.0, maxMilliseconds)
        .toDouble();
    final displayPosition = activeDragValue == null
        ? state.position
        : Duration(milliseconds: activeDragValue.round());
    final progressLabel =
        '${_formatDuration(displayPosition)} / ${_formatDuration(state.duration)}';
    final timeStyle = context.musicFlowTypography.metadata.copyWith(
      color: context.musicFlowColors.muted,
    );

    // 进度条与时间文本区域用 RepaintBoundary 隔离,进度高频更新不扩散整页重绘(SEC §8.2)。
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: context.musicFlowInteraction.minimumTouchTarget,
            child: AnimatedBuilder(
              animation: _loadingOpacity,
              builder: (context, child) => Opacity(
                opacity: isLoading && !_reduceMotion
                    ? _loadingOpacity.value
                    : 1,
                child: child,
              ),
              child: MusicFlowPlayerScrubber(
                key: ValueKey<String?>(state.songId),
                value: sliderValue,
                min: 0,
                max: maxMilliseconds,
                secondaryValue: bufferedValue,
                semanticStep: 10000,
                semanticLabel: loc.player_progress,
                semanticValue: progressLabel,
                semanticValueFormatter: (value) {
                  final position = Duration(milliseconds: value.round());
                  return '${_formatDuration(position)} / '
                      '${_formatDuration(state.duration)}';
                },
                activeColor: context.musicFlowColors.accent,
                secondaryColor: context.musicFlowColors.accent.withValues(
                  alpha: 0.42,
                ),
                inactiveColor: context.musicFlowColors.divider,
                thumbColor: context.musicFlowColors.ink,
                onChangeStart: state.duration <= Duration.zero
                    ? null
                    : (value) {
                        setState(() {
                          _dragSongId = state.songId;
                          _dragValue = value;
                        });
                      },
                onChanged: state.duration <= Duration.zero
                    ? null
                    : (value) {
                        if (_dragSongId != state.songId) return;
                        setState(() => _dragValue = value);
                      },
                onChangeEnd: state.duration <= Duration.zero
                    ? null
                    : (endedValue) {
                        final sessionSongId = _dragSongId;
                        final value = (_dragValue ?? endedValue)
                            .clamp(0.0, maxMilliseconds)
                            .toDouble();
                        setState(_clearSeekSession);
                        if (sessionSongId == null ||
                            sessionSongId != state.songId) {
                          return;
                        }
                        HapticFeedback.selectionClick();
                        unawaited(
                          seekEffectivePlayback(
                            ref,
                            Duration(milliseconds: value.round()),
                          ),
                        );
                      },
                onChangeCancel: state.duration <= Duration.zero
                    ? null
                    : (_) => _cancelSeekSession(),
              ),
            ),
          ),
          ExcludeSemantics(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.musicFlowSpacing.sm,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(_formatDuration(displayPosition), style: timeStyle),
                  Text(_formatDuration(state.duration), style: timeStyle),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final safe = duration.isNegative ? Duration.zero : duration;
    final minutes = safe.inMinutes;
    final seconds = safe.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

/// 主播放控件行:循环/上一首/播放暂停/下一首/队列,对齐参考截图——
/// 播放模式与队列分列两侧,主按钮居中。
/// 投屏时该控件直接控制 DLNA 设备(切歌 = 把队列相邻曲目重新投射并同步游标)。
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({super.key, this.compact = false, this.onOpenQueue});

  // The Remix play glyph has a centered advance box, but its triangular ink
  // mass sits to the left of that center. Shift it by the measured optical
  // correction so it reads centered inside the circular transport control.
  static const double _playIconOpticalCorrection = 0.09;

  final bool compact;
  final VoidCallback? onOpenQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final isPlaying = ref.watch(effectiveIsPlayingProvider);
    final modeState = ref.watch(
      playerProvider.select(
        (state) =>
            (shuffleEnabled: state.shuffleEnabled, loopMode: state.loopMode),
      ),
    );
    final cast = ref.watch(castPeerControllerProvider);
    final isCastMode = cast.activePeer != null;
    // 链路 B（局域网 DLNA 直投）投屏态，独立于链路 A 的 cast。
    final dlnaCast = ref.watch(dlnaCastProvider);
    // 投屏态:播放模式以后端 playMode 为准(order|one|all|shuffle);
    // 链路 B 投屏态:以 dlnaCast.playMode 为准(本机为遥控器);
    // 本机:以本地三态为准。
    final mode = isCastMode
        ? cast.playMode
        : (dlnaCast.isCasting
              ? dlnaCast.playMode
              : (modeState.shuffleEnabled
                    ? 'shuffle'
                    : (modeState.loopMode == LoopMode.one ? 'one' : 'all')));
    final modeIcon = switch (mode) {
      'shuffle' => AppIcons.shuffle,
      'one' => AppIcons.repeatOne,
      'order' => AppIcons.queue,
      _ => AppIcons.repeat,
    };
    final modeLabel = switch (mode) {
      'shuffle' => loc.player_mode_shuffle,
      'one' => loc.player_mode_loop_one,
      'order' => loc.player_mode_order,
      _ => loc.player_mode_list,
    };

    // 播放按钮尺寸随可用宽度自适应:5 个按钮(模式48 + 上一首48 + 播放 + 下一首
    // 48 + 队列48)在窄屏/高文字缩放下可能超出可用宽度(RenderFlex overflow,
    // 实测 320dp 时溢出 16px)。用 LayoutBuilder 感知约束,把播放按钮在
    // [48, 64] 区间内收缩,保证总宽恰好放得下;视觉上主按钮仍≥48(触控标准)。
    return LayoutBuilder(
      builder: (context, constraints) {
        const sideButton = 48.0;
        const minPlay = 48.0;
        final maxPlay = compact ? 56.0 : 64.0;
        // 可用宽度 - 4 个 48px 侧按钮 = 主播放按钮可分配宽度。
        final available = constraints.maxWidth;
        final playDimension = (available - sideButton * 4).clamp(
          minPlay,
          maxPlay,
        );
        final playIconSize = (playDimension - 24).clamp(26.0, 32.0);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                _PlayerIconButton(
                  icon: modeIcon,
                  label: modeLabel,
                  selected: mode != 'all' && mode != 'order',
                  onPressed: () {
                    // 链路 B 投屏态:指挥 DLNA 设备;链路 A 投屏态下发后端 play-mode;
                    // 本机走本地三态。
                    if (dlnaCast.isCasting) {
                      ref.read(dlnaCastProvider.notifier).cyclePlayMode();
                    } else if (isCastMode) {
                      ref
                          .read(castPeerControllerProvider.notifier)
                          .cyclePlayMode();
                    } else {
                      ref.read(playerProvider.notifier).cyclePlaybackMode();
                    }
                  },
                ),
                _PlayerIconButton(
                  icon: AppIcons.previous,
                  label: loc.player_previous,
                  onPressed: () => unawaited(previousEffectivePlayback(ref)),
                ),
                _PlayerIconButton(
                  icon: isPlaying ? AppIcons.pause : AppIcons.play,
                  label: isPlaying ? loc.player_pause : loc.widgets_play,
                  emphasized: true,
                  dimension: playDimension,
                  iconSize: playIconSize,
                  iconOffset: isPlaying
                      ? Offset.zero
                      : Offset(playIconSize * _playIconOpticalCorrection, 0),
                  onPressed: () => unawaited(toggleEffectivePlayback(ref)),
                ),
                _PlayerIconButton(
                  icon: AppIcons.next,
                  label: loc.player_next,
                  onPressed: () => unawaited(nextEffectivePlayback(ref)),
                ),
                _PlayerIconButton(
                  icon: AppIcons.queue,
                  label: loc.player_queue,
                  onPressed: onOpenQueue,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PlayerUtilityBar extends ConsumerWidget {
  const _PlayerUtilityBar({super.key, required this.currentSong});

  final Song currentSong;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final state = ref.watch(
      playerProvider.select(
        (state) => (starred: state.currentSong?.starred ?? currentSong.starred),
      ),
    );
    final cast = ref.watch(castPeerControllerProvider);
    // 链路 B（局域网 DLNA 直投）投屏态，独立于链路 A 的 cast。
    final dlnaCast = ref.watch(dlnaCastProvider);
    final sleepRemaining = ref.watch(sleepTimerProvider);
    final sleepActive = sleepRemaining != null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            // 链路 B（局域网 DLNA 直投）独立按钮：置于最左，与「切换播放器」拉开距离，
            // 避免与链路 A（后端投屏）靠得太近而混淆。
            _PlayerIconButton(
              icon: AppIcons.dlnaLocal,
              label: dlnaCast.isCasting
                  ? loc.player_dlna_local_casting(dlnaCast.currentDevice?.name ?? '')
                  : loc.player_dlna_local,
              selected: dlnaCast.isCasting,
              onPressed: () => unawaited(_openLocalDlnaCastSheet(context, ref)),
            ),
            _PlayerIconButton(
              icon: state.starred ? AppIcons.heart : AppIcons.heartOutline,
              label: state.starred ? loc.player_unfavorite : loc.player_favorite,
              selected: state.starred,
              onPressed: () {
                ref.read(playerProvider.notifier).toggleFavorite();
              },
            ),
            // 音量：弹出式音量调节弹窗，与「喜欢」「切换播放器」并排。
            const VolumeButton(),
            // 定时暂停:预设倒计时弹窗,到点后自动暂停(停止)播放。
            _PlayerIconButton(
              icon: AppIcons.timer,
              label: sleepActive
                  ? _formatSleepRemaining(sleepRemaining, loc)
                  : loc.player_sleep_timer,
              selected: sleepActive,
              onPressed: () => unawaited(_openSleepTimerSheet(context, ref)),
            ),
            // 「切换播放器」：使用 base_station(信号) 图标，与选择播放器弹窗中
            // DLNA 设备行(信号/三角) 保持一致；置于最右，与最左的 DLNA 直投拉开距离。
            _PlayerIconButton(
              icon: AppIcons.signalTower,
              label: loc.player_switch_current(currentPlayerName(cast)),
              selected: cast.isCasting,
              onPressed: () => unawaited(_openPlayerSwitcher(context, ref)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSleepTimerSheet(BuildContext context, WidgetRef ref) async {
    final sleep = ref.read(sleepTimerProvider);
    final timerSet = sleep != null;
    // 结果：null=取消；_SleepTimerOffSentinel=关闭已有定时；_SleepTimerStartChoice=开始定时。
    final selected = await showDialog<Object?>(
      context: context,
      builder: (dialogContext) => SleepTimerSheet(
        hasExisting: timerSet,
        finishSongInitial:
            sleep != null && ref.read(sleepTimerProvider.notifier).finishSong,
        // 已有定时时把当前实际剩余分钟(向上取整,至少 1 分钟)回显到自定义步进器。
        initialMinutes: sleep != null ? sleep.inMinutes.clamp(1, 180) : 0,
      ),
    );
    if (!context.mounted) return;
    if (selected is _SleepTimerStartChoice) {
      if (selected.finishSong) {
        await ref
            .read(sleepTimerProvider.notifier)
            .start(selected.duration, finishSong: true);
      } else {
        await ref.read(sleepTimerProvider.notifier).start(selected.duration);
      }
    } else if (selected is _SleepTimerOffSentinel) {
      await ref.read(sleepTimerProvider.notifier).cancel();
    }
  }

  static String _formatSleepRemaining(Duration? remaining, AppLocalizations loc) {
    if (remaining == null) return '';
    final minutes = remaining.inMinutes.ceil();
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours > 0) {
      if (mins == 0) return loc.player_sleep_timer_hours(hours);
      return '${loc.player_sleep_timer_hours(hours)} ${loc.player_sleep_timer_minutes(mins)}';
    }
    return loc.player_sleep_timer_minutes(mins);
  }

  Future<void> _openPlayerSwitcher(BuildContext context, WidgetRef ref) async {
    final loc = AppLocalizations.of(context);
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => const PlayerSwitcherSheet(),
    );
    if (!context.mounted) return;
    final cast = ref.read(castPeerControllerProvider);
    showMusicFlowToast(
      context,
      cast.activePeer != null
          ? loc.player_casting_to(currentPlayerName(cast))
          : loc.player_switched_local,
      kind: MusicFlowMessageKind.success,
    );
  }

  Future<void> _openLocalDlnaCastSheet(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final loc = AppLocalizations.of(context);
    // Windows 桌面端用「窗户」样式对话框（独立标题栏 + 等圆角），
    // 与安卓底部抽屉区分（对齐更新检测/设置页的平台样式策略）。
    if (isWindowsDesktop) {
      await showMusicFlowDesktopDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => MusicFlowDesktopDialog(
          icon: AppIcons.dlnaLocal,
          title: loc.player_dlna_local,
          subtitle: loc.player_dlna_dialog_subtitle,
          child: LocalDlnaCastSheet(),
        ),
      );
      return;
    }
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => const LocalDlnaCastSheet(),
    );
  }
}

class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.emphasized = false,
    this.dimension = 48,
    this.iconSize = 22,
    this.iconOffset = Offset.zero,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool emphasized;
  final double dimension;
  final double iconSize;
  final Offset iconOffset;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final enabled = onPressed != null;
    final foreground = emphasized
        ? MusicFlowColors.readableOn(colors.ink)
        : enabled
        ? colors.ink
        : colors.onDisabled;
    final background = emphasized
        ? colors.ink
        : selected
        ? colors.ink.withValues(alpha: 0.14)
        : Colors.transparent;

    return Tooltip(
      // 桌面端鼠标悬停显示文字注释（对齐 mini 播放器的按钮提示）；
      // 移动端长按/无障碍由 semanticLabel 承担，Tooltip 不影响触屏行为。
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: MusicFlowPressable(
        semanticLabel: label,
        selected: selected,
        onPressed: onPressed,
        enableHaptics: true,
        minimumSize: Size.square(dimension),
        borderRadius: context.musicFlowRadii.pill,
        child: SizedBox.square(
          dimension: dimension,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: context.musicFlowRadii.pill,
              border: !emphasized && selected
                  ? Border.all(color: colors.accent)
                  : null,
            ),
            child: Center(
              child: Transform.translate(
                key: emphasized
                    ? const ValueKey<String>(
                        'full_player_primary_transport_glyph',
                      )
                    : null,
                offset: iconOffset,
                child: Icon(icon, size: iconSize, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class _SleepTimerOffSentinel {
  const _SleepTimerOffSentinel();
}

/// 用户选定的定时结果：时长 + 是否「播完当前曲再关闭」。
class _SleepTimerStartChoice {
  const _SleepTimerStartChoice({required this.duration, required this.finishSong});

  final Duration duration;
  final bool finishSong;
}

/// 「定时停止播放」设置弹窗（图样式）：7 档预设 + 自定义分钟步进器
/// + 「播完整首歌曲再关闭」开关。通过 Navigator.pop 返回
/// `_SleepTimerStartChoice` / `_SleepTimerOffSentinel` / null。
class SleepTimerSheet extends StatefulWidget {
  const SleepTimerSheet({
    super.key,
    required this.hasExisting,
    this.finishSongInitial = false,
    this.initialMinutes = 0,
  });

  final bool hasExisting;
  final bool finishSongInitial;

  /// 已有定时时回显的实际剩余分钟数（widget 打开前由调用方从 provider 读取）。
  final int initialMinutes;

  @override
  State<SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<SleepTimerSheet> {
  static const _presets = <int>[5, 10, 20, 30, 40, 50, 60];
  static const _maxMinutes = 180;
  late int _customMinutes = widget.initialMinutes;
  late final TextEditingController _minutesController = TextEditingController(
    text: widget.initialMinutes > 0 ? widget.initialMinutes.toString() : '',
  );
  late bool _finishSong = widget.finishSongInitial;

  @override
  void dispose() {
    _minutesController.dispose();
    super.dispose();
  }

  /// 把内部分钟值写回输入框（+/- 按钮用），并重建。
  void _applyMinutes(int next) {
    _customMinutes = next;
    _minutesController.text = next.toString();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return AlertDialog(
      title: Text(loc.player_sleep_timer_dialog_title),
      titleTextStyle: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 预设档位：5/10/20/30/40/50/60 分钟，点一下即开始。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((mn) => _PresetChip(
              label: loc.player_sleep_timer_minutes(mn),
              onTap: () => Navigator.of(context).pop(_SleepTimerStartChoice(
                duration: Duration(minutes: mn),
                finishSong: _finishSong,
              )),
            )).toList(),
          ),
          const SizedBox(height: 16),
          // 自定义分钟步进器（0 起，+/-，分钟单位）。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _StepperButton(
                icon: Icons.remove,
                onTap: () {
                  if (_customMinutes > 0) _applyMinutes(_customMinutes - 1);
                },
              ),
              const SizedBox(width: 14),
              // 手输分钟数：数字键盘，与 +/- 步进器双向同步。
              SizedBox(
                width: 92,
                child: TextField(
                  controller: _minutesController,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    counterText: '',
                  ),
                  onChanged: (value) {
                    final n = int.tryParse(value) ?? 0;
                    _customMinutes = n.clamp(0, _maxMinutes);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text(
                loc.player_sleep_timer_minutes_unit,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 14),
              _StepperButton(
                icon: Icons.add,
                onTap: () {
                  if (_customMinutes < _maxMinutes) _applyMinutes(_customMinutes + 1);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 「播完整首歌曲再关闭」开关。
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _finishSong,
            onChanged: (v) => setState(() => _finishSong = v),
            title: Text(loc.player_sleep_timer_finish_song_title),
            subtitle: Text(
              loc.player_sleep_timer_finish_song_desc,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        if (widget.hasExisting)
          MusicFlowButton.ghost(
            label: loc.player_sleep_timer_off,
            onPressed: () => Navigator.of(context).pop(const _SleepTimerOffSentinel()),
          ),
        MusicFlowButton.ghost(
          label: loc.settings_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        MusicFlowButton.primary(
          label: loc.player_sleep_timer_start,
          onPressed: _customMinutes > 0
              ? () => Navigator.of(context).pop(_SleepTimerStartChoice(
                    duration: Duration(minutes: _customMinutes),
                    finishSong: _finishSong,
                  ))
              : null,
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MusicFlowPressable(
      borderRadius: BorderRadius.circular(12),
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton.filledTonal(
      onPressed: onTap,
      icon: Icon(icon),
      style: IconButton.styleFrom(foregroundColor: accent),
    );
  }
}
