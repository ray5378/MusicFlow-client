import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/design/echo_design.dart';
import '../../../core/network/connectivity_monitor.dart';
import '../../../data/models/audio_quality.dart';
import '../../../data/models/song.dart';
import '../../../providers/audio_quality_provider.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/lyrics_cover_provider.dart';
import '../../../providers/palette_provider.dart';
import '../../../providers/player_provider.dart';
import '../widgets/mini_player.dart' show PlayerSwitcherSheet, VolumeButton;
import '../widgets/play_queue_sheet.dart';
import '../widgets/player_hero_helpers.dart';
import '../widgets/player_scrubber.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/synced_lyrics_view.dart';
import '../widgets/vinyl_record_cover.dart';
import '../../../widgets/windows_title_bar.dart';

/// Echo's immersive now-playing scene.
class FullPlayerPage extends ConsumerStatefulWidget {
  const FullPlayerPage({super.key});

  @override
  ConsumerState<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends ConsumerState<FullPlayerPage>
    with TickerProviderStateMixin {
  bool _showLyrics = false;
  bool _isClosingRoute = false;

  late final AnimationController _lyricsController;
  late final Animation<double> _lyricsProgress;
  Animation<double> _routeForegroundOpacity =
      const AlwaysStoppedAnimation<double>(1);
  CurvedAnimation? _routeForegroundCurvedAnimation;

  @override
  void initState() {
    super.initState();
    _lyricsController = AnimationController(
      vsync: this,
      duration: EchoMotion.standard.state,
      value: _showLyrics ? 1 : 0,
    );
    _lyricsProgress = CurvedAnimation(
      parent: _lyricsController,
      curve: EchoMotion.standard.sceneCurve,
      reverseCurve: EchoMotion.standard.easeOut,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = context.echoMotion;
    final stateDuration = motion.resolve(context, motion.state);
    _lyricsController.duration = stateDuration;

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

    if (context.echoReduceMotion) {
      _lyricsController.value = _showLyrics ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _routeForegroundCurvedAnimation?.dispose();
    _lyricsController.dispose();
    super.dispose();
  }

  Future<void> _closeToMini() async {
    if (_isClosingRoute || !mounted) return;
    _isClosingRoute = true;
    final navigator = Navigator.of(context);

    try {
      final motion = context.echoMotion;
      final settleDuration = motion.resolve(context, motion.feedback);
      if (_showLyrics || _lyricsController.value > 0) {
        setState(() => _showLyrics = false);
        if (settleDuration == Duration.zero) {
          _lyricsController.value = 0;
        } else {
          await _lyricsController.animateBack(
            0,
            duration: settleDuration,
            curve: motion.easeOut,
          );
        }
        if (!mounted) return;
        await WidgetsBinding.instance.endOfFrame;
      }

      if (!mounted) return;
      navigator.pop();
    } catch (_) {
      _isClosingRoute = false;
    }
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
    EchoMessageKind kind = EchoMessageKind.info,
  }) {
    if (!mounted) return;
    showEchoMessage(context, message, kind: kind);
  }

  void _showSongActions(Song song) {
    final mediaVisuals = ref.read(resolvedCurrentSongMediaVisualsProvider);
    unawaited(
      showSongOptionsSheet(
        context: context,
        song: song,
        mediaVisuals: mediaVisuals,
      ),
    );
  }

  void _toggleLyrics() {
    final next = !_showLyrics;
    setState(() => _showLyrics = next);
    if (context.echoReduceMotion) {
      _lyricsController.value = next ? 1 : 0;
    } else if (next) {
      _lyricsController.forward();
    } else {
      _lyricsController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = ref.watch(
      playerProvider.select((state) => state.currentSong),
    );

    if (currentSong == null) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: context.echoColors.canvas,
          body: SafeArea(
            child: Column(
              children: <Widget>[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: EdgeInsets.all(context.echoSpacing.xs),
                    child: EchoIconButton(
                      icon: AppIcons.chevronDown,
                      label: '关闭播放器',
                      onPressed: _closeToMini,
                    ),
                  ),
                ),
                const Expanded(
                  child: EchoEmptyState(
                    title: '暂无播放内容',
                    description: '从音乐流、搜索或资料库选择一首歌曲开始播放。',
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

    return EchoMediaColorScope(
      visuals: visuals,
      role: EchoMediaSurfaceRole.stage,
      child: Builder(
        builder: (context) {
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: overlayStyle,
            child: PopScope<void>(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) async {
                if (!didPop) await _closeToMini();
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
                        child: EchoPlayerBackdrop(
                          visuals: visuals,
                          mode: EchoPlayerBackdropMode.stage,
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
                            final isTouchLike =
                                switch (Theme.of(context).platform) {
                                  TargetPlatform.android ||
                                  TargetPlatform.iOS => true,
                                  _ => false,
                                };
                            final wideAvailable =
                                constraints.maxWidth >
                                        constraints.maxHeight ||
                                    constraints.maxWidth >=
                                        context.echoBreakpoints.expanded;
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
    return Column(
      key: const ValueKey<String>('full_player_portrait_layout'),
      children: <Widget>[
        _PlayerTopBar(
          song: song,
          onClose: _closeToMini,
          onOpenActions: () => _showSongActions(song),
        ),
        Expanded(child: _buildMiddleContent(song, subtitle: subtitle)),
        _buildControlPanel(song),
      ],
    );
  }

  Widget _buildWidePlayerLayout(Song song, {required String subtitle}) {
    final spacing = context.echoSpacing;
    final horizontalPadding = context.echoWindowClass == EchoWindowClass.compact
        ? spacing.md
        : context.echoPageHorizontalPadding;

    return GestureDetector(
      onTap: _closeToMini,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: <Widget>[
          // 主内容:整体垂直居中,不产生上沿白边。
          Center(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: context.echoBreakpoints.maxContentWidth * 1.2,
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
                  final rightPaneWidth =
                      (availableWidth * 0.44).clamp(320.0, 540.0).toDouble();
                  final leftPaneWidth = availableWidth - rightPaneWidth;

                  // crossAxisAlignment.stretch 让左右两栏都有界高,
                  // 内部用 Expanded 分摊,杜绝无界高度导致控件溢出隐藏。
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // 左栏:封面(上) + 信息/控件(下)
                      SizedBox(
                        width: leftPaneWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(
                              flex: 5,
                              child: _buildWideArtworkPane(song),
                            ),
                            SizedBox(height: spacing.md),
                            Expanded(
                              flex: 3,
                              child: _buildWideControlPane(
                                song,
                                subtitle: subtitle,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: leftRightGap),
                      // 右栏:常驻歌词,顶部对齐
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: columnGap),
                          child: const Align(
                            alignment: Alignment.topCenter,
                            child: _PlayerLyricsPane(),
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

  /// 大屏左栏下半部分:歌曲信息(吸收剩余空间) + 播放控件(始终占位显示)。
  Widget _buildWideControlPane(Song song, {required String subtitle}) {
    final spacing = context.echoSpacing;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 信息区:Expanded 吸收多余高度,滚动兜底,绝不让控件溢出。
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: _buildWideDetailsPane(song, subtitle: subtitle),
            ),
          ),
        ),
        SizedBox(height: spacing.sm),
        // 播放控件:独立占位,始终可见。
        _buildControlPanel(song, compact: true, showLyricsToggle: false),
      ],
    );
  }

  Widget _buildWideArtworkPane(Song song) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = context.echoSpacing;
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

        return Center(
          child: _buildCoverHero(
            song,
            coverSize,
            opacity: 1.0,
          ),
        );
      },
    );
  }

  Widget _buildWideDetailsPane(Song song, {required String subtitle}) {
    final titleStyle = context.echoTypography.headline.copyWith(
      color: context.echoColors.ink,
    );
    final subtitleStyle = context.echoTypography.body.copyWith(
      color: context.echoColors.muted,
    );

    return Center(
      child: Column(
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
      ),
    );
  }

  Widget _buildMiddleContent(Song song, {required String subtitle}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = context.echoSpacing;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final horizontalPadding =
            context.echoWindowClass == EchoWindowClass.compact
            ? spacing.lg
            : spacing.xl;
        final titleReserve =
            (24 * textScale * 1.18 * 2) +
            (subtitle.isEmpty ? 0 : 15 * textScale * 1.45 * 2) +
            spacing.xxl;
        final maxCoverByWidth = (constraints.maxWidth - horizontalPadding * 2)
            .clamp(0.0, 400.0);
        final maxCoverByHeight = (constraints.maxHeight - titleReserve).clamp(
          0.0,
          400.0,
        );
        final coverSize = maxCoverByWidth < maxCoverByHeight
            ? maxCoverByWidth
            : maxCoverByHeight;
        final availableTopSpace =
            (constraints.maxHeight - coverSize - titleReserve) / 2;
        final coverTopSpace = availableTopSpace.clamp(spacing.xs, spacing.xl);
        final expandedTitleStyle = context.echoTypography.headline.copyWith(
          color: context.echoColors.ink,
        );
        final compactTitleStyle = context.echoTypography.title.copyWith(
          color: context.echoColors.ink,
        );
        final expandedSubtitleStyle = context.echoTypography.body.copyWith(
          color: context.echoColors.muted,
        );
        final compactSubtitleStyle = context.echoTypography.metadata.copyWith(
          color: context.echoColors.muted,
        );

        return AnimatedBuilder(
          animation: _lyricsProgress,
          builder: (context, child) {
            final progress = _lyricsProgress.value;
            final currentCoverSize = coverSize * (1 - progress);
            final topSpace = coverTopSpace * (1 - progress);
            final coverGap = spacing.lg + (spacing.xs - spacing.lg) * progress;
            final titleStyle = TextStyle.lerp(
              expandedTitleStyle,
              compactTitleStyle,
              progress,
            )!;
            final subtitleStyle = TextStyle.lerp(
              expandedSubtitleStyle,
              compactSubtitleStyle,
              progress,
            )!;
            final shouldBuildLyrics = _showLyrics || progress > 0.001;
            final identity = _buildSongIdentity(
              song: song,
              subtitle: subtitle,
              titleStyle: titleStyle,
              subtitleStyle: subtitleStyle,
            );

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: Column(
                children: <Widget>[
                  SizedBox(height: topSpace),
                  if (currentCoverSize > 0.5)
                    _buildCoverHero(
                      song,
                      currentCoverSize,
                      opacity: 1 - progress,
                    ),
                  SizedBox(height: coverGap),
                  if (shouldBuildLyrics) ...<Widget>[
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: (constraints.maxHeight * 0.32)
                            .clamp(72.0, 180.0)
                            .toDouble(),
                      ),
                      child: identity,
                    ),
                    SizedBox(height: spacing.xxs),
                    Expanded(
                      child: ClipRect(
                        child: Align(
                          alignment: Alignment.topCenter,
                          heightFactor: progress,
                          child: const _PlayerLyricsPane(),
                        ),
                      ),
                    ),
                  ] else
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: identity,
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
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
          SizedBox(height: context.echoSpacing.xxs),
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

  Widget _buildControlPanel(Song song, {bool compact = false, bool showLyricsToggle = true}) {
    final spacing = context.echoSpacing;
    final content = Column(
      key: const ValueKey<String>('full_player_control_panel'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const ProgressBar(),
        SizedBox(height: compact ? spacing.xxs : spacing.sm),
        PlaybackControls(
          key: const ValueKey<String>('full_player_transport_controls'),
          compact: compact,
        ),
        SizedBox(height: compact ? spacing.xxs : spacing.xs),
        _PlayerUtilityBar(
          key: const ValueKey<String>('full_player_utility_bar'),
          currentSong: song,
          showLyrics: _showLyrics,
          onToggleLyrics: _toggleLyrics,
          showLyricsToggle: showLyricsToggle,
          onOpenQueue: () {
            // 移动端:打开底部弹窗(可下滑/叉号关闭);桌面端:右侧面板点开/点关切换。
            if (context.echoWindowClass == EchoWindowClass.compact) {
              unawaited(showPlayQueueSheet(context: context));
            } else {
              toggleRightQueuePanel(context: context);
            }
          },
        ),
        SizedBox(height: spacing.xxs),
      ],
    );

    if (compact) return content;

    final horizontalPadding = context.echoWindowClass == EchoWindowClass.compact
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

  String _formatSamplingRate(int rate) {
    final khz = rate / 1000;
    return khz == khz.truncateToDouble()
        ? '${khz.toInt()}kHz'
        : '${khz.toStringAsFixed(1)}kHz';
  }

  String _buildAudioSpecText(Song? song) {
    final bitDepth = song?.bitDepth;
    final samplingRate = song?.samplingRate;
    if (bitDepth != null && samplingRate != null && samplingRate > 0) {
      return '${bitDepth}bit/${_formatSamplingRate(samplingRate)}';
    }
    if (bitDepth != null) return '${bitDepth}bit';
    if (samplingRate != null && samplingRate > 0) {
      return _formatSamplingRate(samplingRate);
    }
    return '';
  }

  String _normalizeQualityPartForCompare(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final bitrateMatch = RegExp(
      r'(\d{2,4})\s*(k|kbps|kbit/s|kb/s)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (bitrateMatch != null) return '${bitrateMatch.group(1)}k';
    return trimmed.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }

  void _appendUniqueQualityPart(List<String> parts, String part) {
    final candidate = part.trim();
    if (candidate.isEmpty) return;
    final normalized = _normalizeQualityPartForCompare(candidate);
    if (parts.any(
      (existing) => _normalizeQualityPartForCompare(existing) == normalized,
    )) {
      return;
    }
    parts.add(candidate);
  }

  Widget _buildQualityIndicator() {
    return Consumer(
      builder: (context, ref, child) {
        final playerState = ref.watch(
          playerProvider.select(
            (state) => (
              currentSong: state.currentSong,
              currentBitRateKbps: state.currentBitRateKbps,
              currentQuality: state.currentQuality,
              playbackSource: state.playbackSource,
            ),
          ),
        );
        final song = playerState.currentSong;
        final rawBitRate = playerState.currentBitRateKbps > 0
            ? playerState.currentBitRateKbps
            : ((song?.bitRate ?? 0) >= 10000
                  ? ((song?.bitRate ?? 0) ~/ 1000)
                  : (song?.bitRate ?? 0));
        final bitRateText = rawBitRate > 0 ? '${rawBitRate}Kbps' : '未知码率';
        final audioSpecText = _buildAudioSpecText(song);
        final parts = <String>[];
        const icon = AppIcons.headphones;

        // 详情面板行数据：拖动 Popup 面板，不再把码率内联进标签切换。
        final source = playerState.playbackSource ?? PlaybackSource.stream;
        final qualityLabel =
            song?.isPreview == true
                ? (song?.previewQualityLabel?.trim().isNotEmpty == true
                      ? song!.previewQualityLabel!.trim()
                      : '未知音质')
                : switch (playerState.currentQuality ??
                      ref.watch(effectiveQualityProvider)) {
                    AudioQualityLevel.original => '原始无损',
                    AudioQualityLevel.high => '高品质',
                    AudioQualityLevel.standard => '标准',
                    AudioQualityLevel.dataSaver => '流量节省',
                    null => '未知音质',
                  };
        final sourceLabel =
            song?.isPreview == true
                ? '试听'
                : switch (source) {
                    PlaybackSource.downloaded => '本地已下载',
                    PlaybackSource.cached => '本地缓存',
                    PlaybackSource.stream => switch (ref
                        .watch(currentNetworkTypeProvider)
                        .valueOrNull) {
                        NetworkType.wifi => 'Wi-Fi',
                        NetworkType.mobile => '移动数据',
                        NetworkType.none => '无网络',
                        null => '未知网络',
                      },
                  };
        parts.add(sourceLabel);
        _appendUniqueQualityPart(parts, qualityLabel);
        if (audioSpecText.isNotEmpty) {
          _appendUniqueQualityPart(parts, audioSpecText);
        }
        final text = parts.join(' · ');

        return EchoPressable(
          key: const ValueKey<String>('full_player_quality_metadata'),
          semanticLabel: '$text，点击查看播放详情',
          onPressed: () => _showQualityDetailSheet(
            context: context,
            title: song?.title ?? '播放详情',
            subtitle: song?.artist,
            isPreview: song?.isPreview == true,
            sourceLabel: sourceLabel,
            qualityLabel: qualityLabel,
            bitRateText: bitRateText,
            audioSpecText: audioSpecText,
          ),
          minimumSize: Size(
            context.echoInteraction.minimumTouchTarget,
            context.echoInteraction.minimumTouchTarget,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.echoSpacing.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 16, color: context.echoColors.ink),
                SizedBox(width: context.echoSpacing.xs),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: context.echoTypography.metadata.copyWith(
                      color: context.echoColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 点击音质/码率信息时弹出的详情面板：把来源、音质、码率、采样规格等
  /// 详情收进一个面板展示，替代原先「把码率内联进标签」的点击切换。
  Future<void> _showQualityDetailSheet({
    required BuildContext context,
    required String title,
    required String? subtitle,
    required bool isPreview,
    required String sourceLabel,
    required String qualityLabel,
    required String bitRateText,
    required String audioSpecText,
  }) async {
    await showEchoBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: isPreview ? '试听详情' : '播放详情',
        subtitle: subtitle,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _QualityDetailRow(label: '曲目', value: title),
            _QualityDetailRow(label: '播放来源', value: sourceLabel),
            _QualityDetailRow(label: '音质等级', value: qualityLabel),
            _QualityDetailRow(label: '码率', value: bitRateText),
            if (audioSpecText.isNotEmpty)
              _QualityDetailRow(label: '采样规格', value: audioSpecText),
          ],
        ),
      ),
    );
  }
}

/// 播放详情面板里的一行「标签 — 值」只读数据项。
class _QualityDetailRow extends StatelessWidget {
  const _QualityDetailRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.echoSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: context.echoTypography.metadata.copyWith(
                color: context.echoColors.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: context.echoTypography.body.copyWith(
                color: context.echoColors.ink,
              ),
            ),
          ),
        ],
      ),
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
  const _PlayerTopBar({
    required this.song,
    required this.onClose,
    required this.onOpenActions,
  });

  final Song song;
  final VoidCallback onClose;
  final VoidCallback onOpenActions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.echoSpacing.xs),
      child: SizedBox(
        height: 56,
        child: Row(
          children: <Widget>[
            _PlayerIconButton(
              icon: AppIcons.chevronDown,
              label: '收起播放器',
              onPressed: onClose,
            ),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  '正在播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: context.echoTypography.label.copyWith(
                    color: context.echoColors.ink,
                  ),
                ),
              ),
            ),
            _PlayerIconButton(
              icon: AppIcons.more,
              label: '${song.title} 操作',
              onPressed: onOpenActions,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerLyricsPane extends ConsumerWidget {
  const _PlayerLyricsPane({
    this.activeColor,
  });

  final Color? activeColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(currentLyricsProvider);
    // 高亮颜色跟随当前主题强调色；未显式指定时不再使用硬编码黄色。
    final lyricActiveColor = activeColor ?? context.echoColors.accent;
    return lyricsAsync.when(
      data: (lyrics) {
        if (lyrics == null || lyrics.isEmpty) {
          return const _PlayerLyricsMessage(
            icon: AppIcons.lyrics,
            title: '暂无歌词',
            description: '当前曲目没有可用的歌词内容。',
          );
        }
        final bestLyrics = lyrics.getBest();
        if (bestLyrics == null) {
          return const _PlayerLyricsMessage(
            icon: AppIcons.lyrics,
            title: '暂无歌词',
            description: '当前曲目没有可用的歌词内容。',
          );
        }
        return SyncedLyricsView(
          lyrics: bestLyrics,
          activePrimaryColor: lyricActiveColor,
          activeSecondaryColor: lyricActiveColor,
          inactivePrimaryColor: context.echoColors.muted,
          inactiveSecondaryColor: context.echoColors.muted,
        );
      },
      loading: () => const _PlayerLyricsLoading(),
      error: (error, stackTrace) => _PlayerLyricsMessage(
        icon: AppIcons.error,
        title: '歌词加载失败',
        description: '播放不受影响，可以立即重试。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(currentLyricsProvider),
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
        padding: EdgeInsets.all(context.echoSpacing.lg),
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
                    Icon(icon, size: 32, color: context.echoColors.ink),
                    SizedBox(height: context.echoSpacing.sm),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: context.echoTypography.title.copyWith(
                        color: context.echoColors.ink,
                      ),
                    ),
                    SizedBox(height: context.echoSpacing.xs),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: context.echoTypography.body.copyWith(
                        color: context.echoColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              SizedBox(height: context.echoSpacing.lg),
              EchoButton.secondary(label: actionLabel!, onPressed: onAction),
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
    return Semantics(
      liveRegion: true,
      label: '歌词加载中',
      child: ExcludeSemantics(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final width in <double>[220, 280, 196, 250]) ...<Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.echoColors.ink.withValues(alpha: 0.18),
                    borderRadius: context.echoRadii.detail,
                  ),
                  child: SizedBox(width: width, height: 16),
                ),
                SizedBox(height: context.echoSpacing.md),
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
    _reduceMotion = context.echoReduceMotion;
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
    final effectivePosition = ref.watch(effectivePositionProvider);
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
    final timeStyle = context.echoTypography.metadata.copyWith(
      color: context.echoColors.muted,
    );

    // 进度条与时间文本区域用 RepaintBoundary 隔离,进度高频更新不扩散整页重绘(SEC §8.2)。
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: context.echoInteraction.minimumTouchTarget,
            child: AnimatedBuilder(
              animation: _loadingOpacity,
              builder: (context, child) => Opacity(
                opacity: isLoading && !_reduceMotion
                    ? _loadingOpacity.value
                    : 1,
                child: child,
              ),
              child: EchoPlayerScrubber(
                key: ValueKey<String?>(state.songId),
                value: sliderValue,
                min: 0,
                max: maxMilliseconds,
                secondaryValue: bufferedValue,
                semanticStep: 10000,
                semanticLabel: '播放进度',
                semanticValue: progressLabel,
                semanticValueFormatter: (value) {
                  final position = Duration(milliseconds: value.round());
                  return '${_formatDuration(position)} / '
                      '${_formatDuration(state.duration)}';
                },
                activeColor: context.echoColors.accent,
                secondaryColor: context.echoColors.accent.withValues(
                  alpha: 0.42,
                ),
                inactiveColor: context.echoColors.divider,
                thumbColor: context.echoColors.ink,
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
              padding: EdgeInsets.symmetric(horizontal: context.echoSpacing.sm),
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

/// 主播放控件:上一首/播放暂停/下一首,对齐主项目前端播放条的中央控制区。
/// 投屏时该控件直接控制 DLNA 设备(切歌 = 把队列相邻曲目重新投射并同步游标)。
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({super.key, this.compact = false});

  // The Remix play glyph has a centered advance box, but its triangular ink
  // mass sits to the left of that center. Shift it by the measured optical
  // correction so it reads centered inside the circular transport control.
  static const double _playIconOpticalCorrection = 0.09;

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(effectiveIsPlayingProvider);

    final playDimension = compact ? 56.0 : 64.0;
    final playIconSize = compact ? 30.0 : 32.0;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _PlayerIconButton(
              icon: AppIcons.previous,
              label: '上一首',
              onPressed: () => unawaited(previousEffectivePlayback(ref)),
            ),
            _PlayerIconButton(
              icon: isPlaying ? AppIcons.pause : AppIcons.play,
              label: isPlaying ? '暂停' : '播放',
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
              label: '下一首',
              onPressed: () => unawaited(nextEffectivePlayback(ref)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerUtilityBar extends ConsumerWidget {
  const _PlayerUtilityBar({
    super.key,
    required this.currentSong,
    required this.showLyrics,
    required this.onToggleLyrics,
    required this.onOpenQueue,
    this.showLyricsToggle = true,
  });

  final Song currentSong;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenQueue;
  final bool showLyricsToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      playerProvider.select(
        (state) => (
          shuffleEnabled: state.shuffleEnabled,
          loopMode: state.loopMode,
          starred: state.currentSong?.starred ?? currentSong.starred,
        ),
      ),
    );
    final cast = ref.watch(castPeerControllerProvider);
    final isCastMode = cast.activePeer != null;
    // 投屏态:播放模式以后端 playMode 为准(order|one|all|shuffle);
    // 本机:以本地三态为准。
    final mode = isCastMode
        ? cast.playMode
        : (state.shuffleEnabled
              ? 'shuffle'
              : (state.loopMode == LoopMode.one ? 'one' : 'all'));
    final modeIcon = switch (mode) {
      'shuffle' => AppIcons.shuffle,
      'one' => AppIcons.repeatOne,
      'order' => AppIcons.queue,
      _ => AppIcons.repeat,
    };
    final modeLabel = switch (mode) {
      'shuffle' => '随机播放，点击切换到顺序播放',
      'one' => '单曲循环，点击切换到列表循环',
      'order' => '顺序播放，点击切换到单曲循环',
      _ => '列表循环，点击切换到随机播放',
    };

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            _PlayerIconButton(
              icon: modeIcon,
              label: modeLabel,
              selected: mode != 'all' && mode != 'order',
              onPressed: () {
                // 投屏态下发后端 play-mode;本机走本地三态。
                if (isCastMode) {
                  ref.read(castPeerControllerProvider.notifier).cyclePlayMode();
                } else {
                  ref.read(playerProvider.notifier).cyclePlaybackMode();
                }
              },
            ),
            if (showLyricsToggle)
              _PlayerIconButton(
                icon: showLyrics ? AppIcons.lyricsFilled : AppIcons.lyrics,
                label: showLyrics ? '显示封面' : '显示歌词',
                selected: showLyrics,
                onPressed: onToggleLyrics,
              ),
            _PlayerIconButton(
              icon: AppIcons.queue,
              label: '播放队列',
              onPressed: onOpenQueue,
            ),
            _PlayerIconButton(
              icon: state.starred ? AppIcons.heart : AppIcons.heartOutline,
              label: state.starred ? '取消红心' : '红心',
              selected: state.starred,
              onPressed: () {
                ref.read(playerProvider.notifier).toggleFavorite();
              },
            ),
            // 音量：弹出式音量调节弹窗，与「喜欢」「切换播放器」并排。
            const VolumeButton(),
            _PlayerIconButton(
              icon: AppIcons.speaker,
              label: '切换播放器，当前：${currentPlayerName(cast)}',
              selected: cast.isCasting,
              onPressed: () => unawaited(_openPlayerSwitcher(context, ref)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPlayerSwitcher(BuildContext context, WidgetRef ref) async {
    await showEchoBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => const PlayerSwitcherSheet(),
    );
    if (!context.mounted) return;
    final cast = ref.read(castPeerControllerProvider);
    showEchoToast(
      context,
      cast.activePeer != null
          ? '正在投屏到「${currentPlayerName(cast)}」'
          : '已切换为本机播放',
      kind: EchoMessageKind.success,
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
    final colors = context.echoColors;
    final enabled = onPressed != null;
    final foreground = emphasized
        ? EchoColors.readableOn(colors.ink)
        : enabled
        ? colors.ink
        : colors.onDisabled;
    final background = emphasized
        ? colors.ink
        : selected
        ? colors.ink.withValues(alpha: 0.14)
        : Colors.transparent;

    return EchoPressable(
      semanticLabel: label,
      selected: selected,
      onPressed: onPressed,
      enableHaptics: true,
      minimumSize: Size.square(dimension),
      borderRadius: context.echoRadii.pill,
      child: SizedBox.square(
        dimension: dimension,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: context.echoRadii.pill,
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
    );
  }
}
