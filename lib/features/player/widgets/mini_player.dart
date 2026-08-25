import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/peer.dart';
import '../../../data/models/song.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/lyrics_cover_provider.dart';
import '../../../providers/palette_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/cover_art_image.dart';
import '../pages/full_player_page.dart';
import 'player_hero_helpers.dart';
import 'play_queue_sheet.dart';

/// Stable bridge between the application shell and the immersive player.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  static const double height = 72;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final cast = ref.watch(castPeerControllerProvider);
    final isCasting = cast.activePeer != null;

    final currentSong = player.currentSong;

    // 投屏(切换播放器)激活时,迷你条反映后端 peer 的实时状态:
    // 曲目经队列 currentIndex 回写同步,进度/播放态取自 /peers/:id/status。
    final playerState = PlayerState(
      currentSong: currentSong,
      queue: player.queue,
      currentIndex: player.currentIndex,
      isPlaying: ref.watch(effectiveIsPlayingProvider),
      shuffleEnabled: player.shuffleEnabled,
      loopMode: player.loopMode,
      position: ref.watch(effectivePositionProvider),
      duration: ref.watch(effectiveDurationProvider),
    );
    final visuals = ref.watch(resolvedCurrentSongMediaVisualsProvider);
    final lyricLine = ref.watch(currentLyricLineProvider);
    // 播放模式(对齐主项目前端 playMode:order|one|all|shuffle)。
    // 投屏态以后端 playMode 为准;本机以本地 shuffleEnabled + loopMode 推导。
    final mode = isCasting
        ? cast.playMode
        : (player.shuffleEnabled
              ? 'shuffle'
              : (player.loopMode == LoopMode.one ? 'one' : 'all'));

    return MiniPlayerView(
      playerState: playerState,
      mediaVisuals: visuals,
      lyricLine: lyricLine,
      onOpenPlayer: () => _openFullPlayer(context),
      onTogglePlayPause: () => toggleEffectivePlayback(ref),
      onSeek: (position) => seekEffectivePlayback(ref, position),
      progressLayer: const _ProviderMiniPlayerProgress(),
      onSwitchPlayer: () => _showPlayerSwitcher(context: context, ref: ref),
      onPrevious: () => isCasting
          ? ref.read(castPeerControllerProvider.notifier).previous()
          : ref.read(playerProvider.notifier).previous(),
      onNext: () => isCasting
          ? ref.read(castPeerControllerProvider.notifier).next()
          : ref.read(playerProvider.notifier).next(),
      playMode: mode,
      onTogglePlayMode: () => isCasting
          ? ref.read(castPeerControllerProvider.notifier).cyclePlayMode()
          : ref.read(playerProvider.notifier).cyclePlaybackMode(),
      onToggleFavorite: () =>
          ref.read(playerProvider.notifier).toggleFavorite(),
      onOpenQueue: () {
        // 移动端:底部弹窗;桌面端:右侧队列面板点开/点关切换(与播放页一致)。
        if (context.musicFlowWindowClass == MusicFlowWindowClass.compact) {
          showPlayQueueSheet(context: context);
        } else {
          toggleRightQueuePanel(context: context);
        }
      },
      currentPlayerName: currentPlayerName(cast),
      isCasting: isCasting,
    );
  }

  static void _openFullPlayer(BuildContext context) {
    final duration = context.musicFlowMotion.resolve(
      context,
      context.musicFlowMotion.scene,
    );
    // 压入「根」导航器:全屏播放器需盖住整个窗口(含 Windows 自绘标题栏),
    // 否则 Play 页会落在 40px 标题栏之下,顶部残留一条标题栏色带(用户感知为
    // 「大屏顶部白边」),且下方 shell/迷你条不参与沉浸视图。
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) {
          return const FullPlayerPage();
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return child;
        },
        transitionDuration: duration,
        reverseTransitionDuration: duration,
      ),
    );
  }

  static Future<void> _showPlayerSwitcher({
    required BuildContext context,
    required WidgetRef ref,
  }) async {
    // 电脑端：播放控件上方的小弹窗（对齐主项目前端），手机端保留底部弹层。
    final isDesktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    if (isDesktop) {
      _showDesktopPlayerSwitcherPopover(context: context);
      return;
    }
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => const PlayerSwitcherSheet(),
    );
    if (context.mounted) {
      final cast = ref.read(castPeerControllerProvider);
      showMusicFlowToast(
        context,
        cast.activePeer != null
            ? '正在远控「${currentPlayerName(cast)}」'
            : '已切换为本机播放',
        kind: MusicFlowMessageKind.success,
      );
    }
  }

  /// 电脑端「切换播放器」小弹窗：以 Overlay 呈现，播放控件上方小窗，
  /// 点击弹窗外任意位置关闭；切换完成后弹出右上角 Toast 反馈。
  static void _showDesktopPlayerSwitcherPopover({
    required BuildContext context,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (entryContext) => PlayerSwitcherPopover(
        onSwitched: (message) {
          if (entry.mounted) entry.remove();
          if (message != null && context.mounted) {
            showMusicFlowToast(context, message, kind: MusicFlowMessageKind.success);
          }
        },
      ),
    );
    overlay.insert(entry);
  }
}

/// Pure player surface kept public so gesture, semantics and large-text
/// behaviour can be tested without constructing the audio engine.
@visibleForTesting
class MiniPlayerView extends StatefulWidget {
  const MiniPlayerView({
    super.key,
    required this.playerState,
    required this.onOpenPlayer,
    required this.onTogglePlayPause,
    required this.onSeek,
    required this.onSwitchPlayer,
    this.onPrevious,
    this.onNext,
    this.playMode = 'all',
    this.onTogglePlayMode,
    this.onToggleFavorite,
    this.onOpenQueue,
    this.currentPlayerName = '本机',
    this.isCasting = false,
    this.lyricLine,
    this.mediaVisuals,
    this.albumColor,
    this.progressLayer,
  });

  final PlayerState playerState;
  final MusicFlowMediaVisuals? mediaVisuals;

  /// 当前播放目标名称（本机 / DLNA 设备名），对齐主项目前端的
  /// 「扬声器图标 + 当前播放器名」反馈。
  final String currentPlayerName;

  /// 是否正在投屏：为 true 时切换按钮换用信号塔图标并以强调色显示。
  final bool isCasting;

  /// 当前滚动歌词单行，非空时优先展示在副标题（对齐主项目前端行为）。
  final String? lyricLine;

  /// Compatibility seed for provider-free tests and older call sites.
  final Color? albumColor;
  final VoidCallback onOpenPlayer;
  final Future<void> Function() onTogglePlayPause;
  final Future<void> Function(Duration position) onSeek;
  final VoidCallback onSwitchPlayer;

  /// 桌面端专属回调(手机端不使用)。
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// 桌面端播放模式(对齐主项目前端 playMode:order|one|all|shuffle)。
  final String playMode;

  /// 桌面端模式切换:单一按钮循环切换模式并变换图标。
  final VoidCallback? onTogglePlayMode;

  /// 桌面端喜欢(红心)按钮:切换当前歌曲收藏状态。
  final VoidCallback? onToggleFavorite;

  /// 桌面端「当前播放列表」按钮:打开播放队列面板。
  final VoidCallback? onOpenQueue;

  final Widget? progressLayer;

  @override
  State<MiniPlayerView> createState() => _MiniPlayerViewState();
}

class _MiniPlayerViewState extends State<MiniPlayerView> {
  static const double _verticalExpandThreshold = 36;

  double _verticalDragDy = 0;

  PlayerState get _playerState => widget.playerState;

  /// 桌面端(Windows/macOS/Linux):显示全控件。
  bool get _isDesktop {
    switch (Theme.of(context).platform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  @override
  void didUpdateWidget(covariant MiniPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  void _togglePlayPause() {
    HapticFeedback.selectionClick();
    unawaited(widget.onTogglePlayPause());
  }

  /// 桌面端全控件：上一首 / 播放暂停 / 下一首 / 播放模式 / 音量 / 投屏。
  /// 每个按钮包一层 Tooltip（悬停显示文字注释，对齐主项目前端），
  /// 播放模式为单一按钮,点击循环切换模式并变换图标(对齐主项目前端 cyclePlayMode)。
  List<Widget> _buildDesktopControls(BuildContext context) {
    final isFav = _playerState.currentSong?.starred ?? false;
    return <Widget>[
      Tooltip(
        message: '上一首',
        child: MusicFlowIconButton(
          icon: AppIcons.previous,
          label: '上一首',
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onPrevious,
        ),
      ),
      Tooltip(
        message: _playerState.isPlaying ? '暂停' : '播放',
        child: MusicFlowIconButton(
          icon: _playerState.isPlaying ? AppIcons.pause : AppIcons.play,
          label: _playerState.isPlaying ? '暂停' : '播放',
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: _togglePlayPause,
        ),
      ),
      Tooltip(
        message: '下一首',
        child: MusicFlowIconButton(
          icon: AppIcons.next,
          label: '下一首',
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onNext,
        ),
      ),
      _PlayModeButton(
        mode: widget.playMode,
        onPressed: widget.onTogglePlayMode,
      ),
      Tooltip(
        message: isFav ? '取消红心' : '红心',
        child: MusicFlowIconButton(
          icon: isFav ? AppIcons.heart : AppIcons.heartOutline,
          label: isFav ? '取消红心' : '红心',
          selected: isFav,
          onPressed: widget.onToggleFavorite,
        ),
      ),
      Tooltip(
        message: '当前播放列表',
        child: MusicFlowIconButton(
          icon: AppIcons.queue,
          label: '当前播放列表',
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onOpenQueue,
        ),
      ),
      const VolumeButton(),
      Tooltip(
        message: '切换播放器，当前：${widget.currentPlayerName}',
        child: MusicFlowIconButton(
          icon: AppIcons.dlna,
          label: '切换播放器，当前：${widget.currentPlayerName}',
          foregroundColor: widget.isCasting
              ? context.musicFlowColors.accent
              : context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onSwitchPlayer,
        ),
      ),
    ];
  }

  /// 响应式桌面端控件：随窗口宽度「渐隐」非核心按钮。
  /// 保留最关键的 上一首/播放暂停/下一首(列表前三个)，其余
  /// (播放模式/红心/队列/音量/切换播放器)在窗口变窄时从右往左
  /// 依次淡出；最边缘的一个按钮按剩余空间比例降低透明度，形成
  /// 平滑淡入淡出而非突兀截断。同时避免迷你条溢出。
  List<Widget> _buildResponsiveDesktopControls(
    BuildContext context, {
    required double windowWidth,
  }) {
    const double trackMinWidth = 180;
    const double buttonStep = 48;
    final allControls = _buildDesktopControls(context);
    if (allControls.isEmpty) return allControls;

    // 可变空间不足以容纳任何按钮时，仅保留播放核心按钮。
    final budget = windowWidth - trackMinWidth;
    if (budget <= buttonStep) {
      return <Widget>[
        if (allControls.isNotEmpty) allControls.first,
      ];
    }

    final fullCount = allControls.length;
    final shownCount = (budget / buttonStep)
        .floor()
        .clamp(1, fullCount);
    final result = <Widget>[];
    for (var i = 0; i < shownCount; i++) {
      double opacity = 1.0;
      // 最后一个勉强放下的按钮按剩余空间比例淡化，形成渐隐过渡。
      if (i == shownCount - 1 && shownCount < fullCount) {
        final consumed = buttonStep * (shownCount - 1);
        final leftover = (budget - consumed).clamp(0.0, buttonStep);
        opacity = (leftover / buttonStep).clamp(0.15, 1.0);
      }
      result.add(
        AnimatedOpacity(
          key: ValueKey('mini-control-$i'),
          opacity: opacity,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: allControls[i],
        ),
      );
    }
    return result;
  }

  /// 手机端简略版：播放暂停 + 投屏控制
  List<Widget> _buildMobileControls(BuildContext context) {
    return <Widget>[
      MusicFlowIconButton(
        icon: _playerState.isPlaying ? AppIcons.pause : AppIcons.play,
        label: _playerState.isPlaying ? '暂停' : '播放',
        foregroundColor: context.musicFlowColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: _togglePlayPause,
      ),
      MusicFlowIconButton(
        icon: AppIcons.dlna,
        label: '切换播放器，当前：${widget.currentPlayerName}',
        foregroundColor: widget.isCasting
            ? context.musicFlowColors.accent
            : context.musicFlowColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: widget.onSwitchPlayer,
      ),
    ];
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    _verticalDragDy = 0;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    _verticalDragDy += details.primaryDelta ?? 0;
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldExpand =
        velocity < -600 || _verticalDragDy <= -_verticalExpandThreshold;
    _verticalDragDy = 0;
    if (!shouldExpand) return;
    HapticFeedback.selectionClick();
    widget.onOpenPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = _playerState.currentSong;
    final song = currentSong;
    final visuals =
        widget.mediaVisuals ??
        MusicFlowMediaVisuals.fallback(
          seed: widget.albumColor ?? MusicFlowColors.contentTintFallback,
        );

    return MusicFlowMediaColorScope(
      visuals: visuals,
      role: MusicFlowMediaSurfaceRole.mini,
      child: Builder(
        builder: (context) {
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          final showSubtitle = textScale <= 1.4;
          final semanticState = _playerState.isPlaying ? '正在播放' : '已暂停';
          final songTitle = song?.title ?? '未在播放';
          final semanticSubtitle = song?.artist?.trim().isNotEmpty == true
              ? '，${song!.artist!.trim()}'
              : '';

          return Semantics(
            container: true,
            explicitChildNodes: true,
            label: '迷你播放器，$songTitle$semanticSubtitle',
            value: semanticState,
            onTap: widget.onOpenPlayer,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onVerticalDragStart: _handleVerticalDragStart,
              onVerticalDragUpdate: _handleVerticalDragUpdate,
              onVerticalDragEnd: _handleVerticalDragEnd,
              child: SizedBox(
                key: const Key('mini-player-surface'),
                height: MiniPlayer.height,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: Hero(
                        tag: playerBackgroundHeroTag,
                        flightShuttleBuilder:
                            playerBackgroundFlightShuttleBuilder,
                        child: MusicFlowPlayerBackdrop(
                          visuals: visuals,
                          mode: MusicFlowPlayerBackdropMode.mini,
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        context.musicFlowSpacing.sm,
                        context.musicFlowSpacing.xs,
                        context.musicFlowSpacing.xs,
                        context.musicFlowSpacing.xs,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) => Row(
                          children: <Widget>[
                            Expanded(
                              child: GestureDetector(
                                key: const Key('mini-player-track'),
                                behavior: HitTestBehavior.opaque,
                                onTap: widget.onOpenPlayer,
                                onDoubleTap: _togglePlayPause,
                                child: ClipRect(
                                  child: _MiniPlayerTrack(
                                    song: song,
                                    useHero: true,
                                    showSubtitle: showSubtitle,
                                    lyricLine: widget.lyricLine,
                                  ),
                                ),
                              ),
                            ),
                            // 桌面端(Windows/macOS/Linux)全控件:上一首/播放暂停/下一首/随机/循环/投屏
                            // 手机端简略版:播放暂停 + 投屏控制
                            if (_isDesktop)
                              ..._buildResponsiveDesktopControls(
                                context,
                                windowWidth: constraints.maxWidth,
                              )
                            else
                              ..._buildMobileControls(context),
                          ],
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: ClipRRect(
                        key: const Key('mini-player-surface-clip'),
                        borderRadius: context.musicFlowRadii.surface,
                        child:
                            widget.progressLayer ??
                            _MiniPlayerProgressSurface(
                              position: _playerState.position,
                              duration: _playerState.duration,
                              onSeek: widget.onSeek,
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
}

class _ProviderMiniPlayerProgress extends ConsumerWidget {
  const _ProviderMiniPlayerProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(effectivePositionProvider);
    final duration = ref.watch(effectiveDurationProvider);
    return _MiniPlayerProgressSurface(
      position: position,
      duration: duration,
      onSeek: (target) => seekEffectivePlayback(ref, target),
    );
  }
}

class _MiniPlayerProgressSurface extends StatefulWidget {
  const _MiniPlayerProgressSurface({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration target) onSeek;

  @override
  State<_MiniPlayerProgressSurface> createState() =>
      _MiniPlayerProgressSurfaceState();
}

class _MiniPlayerProgressSurfaceState
    extends State<_MiniPlayerProgressSurface> {
  double _scrubViewportWidth = 1;
  double? _scrubProgress;
  bool _scrubbing = false;

  void _handleProgressDragStart(DragStartDetails details) {
    if (widget.duration <= Duration.zero) return;
    setState(() {
      _scrubbing = true;
      _scrubProgress = _progressFromDx(details.localPosition.dx);
    });
  }

  void _handleProgressDragUpdate(DragUpdateDetails details) {
    if (!_scrubbing || widget.duration <= Duration.zero) return;
    setState(() {
      _scrubProgress = _progressFromDx(details.localPosition.dx);
    });
  }

  void _handleProgressDragEnd(DragEndDetails details) {
    final progress = _scrubProgress;
    final durationMs = widget.duration.inMilliseconds;
    if (_scrubbing && progress != null && durationMs > 0) {
      HapticFeedback.selectionClick();
      unawaited(
        widget.onSeek(Duration(milliseconds: (durationMs * progress).round())),
      );
    }
    setState(() {
      _scrubbing = false;
      _scrubProgress = null;
    });
  }

  void _handleProgressDragCancel() {
    if (!_scrubbing) return;
    setState(() {
      _scrubbing = false;
      _scrubProgress = null;
    });
  }

  double _progressFromDx(double dx) {
    return (dx / _scrubViewportWidth).clamp(0.0, 1.0);
  }

  void _seekRelative(Duration delta) {
    if (widget.duration <= Duration.zero) return;
    final targetMs = (widget.position + delta).inMilliseconds
        .clamp(0, widget.duration.inMilliseconds)
        .toInt();
    HapticFeedback.selectionClick();
    unawaited(widget.onSeek(Duration(milliseconds: targetMs)));
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.duration.inMilliseconds > 0
        ? widget.position.inMilliseconds / widget.duration.inMilliseconds
        : 0.0;
    final displayedProgress = (_scrubProgress ?? progress).clamp(0.0, 1.0);
    final displayedPosition = _scrubProgress == null
        ? widget.position
        : Duration(
            milliseconds: (widget.duration.inMilliseconds * displayedProgress)
                .round(),
          );
    final progressValue = _formatPlayerProgress(
      displayedPosition,
      widget.duration,
    );

    return Stack(
      children: <Widget>[
        PositionedDirectional(
          start: 0,
          end: 196,
          bottom: 0,
          height: 20,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _scrubViewportWidth = constraints.maxWidth;
              return Semantics(
                label: '播放进度',
                value: progressValue,
                increasedValue: '快进 10 秒',
                decreasedValue: '后退 10 秒',
                onIncrease: () => _seekRelative(const Duration(seconds: 10)),
                onDecrease: () => _seekRelative(const Duration(seconds: -10)),
                child: GestureDetector(
                  key: const Key('mini-player-scrubber'),
                  behavior: HitTestBehavior.translucent,
                  excludeFromSemantics: true,
                  onHorizontalDragStart: _handleProgressDragStart,
                  onHorizontalDragUpdate: _handleProgressDragUpdate,
                  onHorizontalDragEnd: _handleProgressDragEnd,
                  onHorizontalDragCancel: _handleProgressDragCancel,
                ),
              );
            },
          ),
        ),
        PositionedDirectional(
          start: 0,
          end: 0,
          bottom: 0,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: MusicFlowProgressBar(
                key: const Key('mini-player-progress'),
                value: displayedProgress,
                height: 3,
                color: context.musicFlowColors.accent,
                trackColor: Colors.transparent,
              ),
            ),
          ),
        ),
        if (_scrubbing)
          PositionedDirectional(
            start: context.musicFlowSpacing.sm,
            end: 196,
            bottom: 18,
            child: _MiniPlayerScrubBubble(
              progress: displayedProgress,
              duration: widget.duration,
            ),
          ),
      ],
    );
  }
}

String _formatPlayerProgress(Duration position, Duration duration) {
  return '${_formatPlayerDuration(position)} / ${_formatPlayerDuration(duration)}';
}

String _formatPlayerDuration(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  final minutes = safe.inMinutes;
  final seconds = safe.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _MiniPlayerTrack extends StatelessWidget {
  const _MiniPlayerTrack({
    required this.song,
    required this.useHero,
    required this.showSubtitle,
    this.lyricLine,
  });

  final Song? song;
  final bool useHero;
  final bool showSubtitle;
  final String? lyricLine;

  @override
  Widget build(BuildContext context) {
    final song = this.song;
    // 未播放时展示占位轨迹(对齐主项目前端「未在播放 / 选择一首歌曲开始播放」),
    // 迷你条保持常驻显示,不随播放状态隐藏。
    if (song == null) {
      return _MiniPlayerEmptyTrack(showSubtitle: showSubtitle);
    }
    final artist = song.artist?.trim() ?? '';
    final album = song.album?.trim() ?? '';
    // 歌名 - 歌手 同一行（无歌手回退专辑名），歌词另起一行。
    final artistLine = artist.isNotEmpty ? artist : album;
    final lyric = lyricLine?.trim().isNotEmpty == true
        ? lyricLine!.trim()
        : null;
    final cover = _MiniPlayerCover(song: song);
    final title = _MiniPlayerTitle(
      song: song,
      showArtist: showSubtitle,
      artistText: showSubtitle ? artistLine : '',
    );

    return Row(
      children: <Widget>[
        if (useHero)
          Hero(
            tag: playerCoverHeroTag,
            createRectTween: playerCoverRectTween,
            child: cover,
          )
        else
          cover,
        SizedBox(width: context.musicFlowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (useHero)
                Hero(
                  tag: playerTitleHeroTag,
                  createRectTween: playerLinearRectTween,
                  flightShuttleBuilder: playerTextFlightShuttleBuilder,
                  child: title,
                )
              else
                title,
              // 当前歌词行：黄色高亮显示（对齐主项目前端歌词配色）。
              if (lyric != null) _MiniPlayerLyric(text: lyric),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniPlayerEmptyTrack extends StatelessWidget {
  const _MiniPlayerEmptyTrack({required this.showSubtitle});

  final bool showSubtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: context.musicFlowColors.surface,
            shape: BoxShape.circle,
          ),
          child: Icon(
            AppIcons.music,
            size: 24,
            color: context.musicFlowColors.muted,
          ),
        ),
        SizedBox(width: context.musicFlowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                '未在播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.musicFlowTypography.title,
              ),
              if (showSubtitle)
                Text(
                  '选择一首歌曲开始播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.musicFlowTypography.metadata.copyWith(
                    color: context.musicFlowColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniPlayerCover extends StatelessWidget {
  const _MiniPlayerCover({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: ClipOval(
        child: CoverArtImage(
          coverArtId: song.artworkReference,
          size: 48,
          requestSize: 320,
          fit: BoxFit.cover,
          semanticLabel: '${song.title} 封面',
        ),
      ),
    );
  }
}

class _MiniPlayerTitle extends StatelessWidget {
  const _MiniPlayerTitle({
    required this.song,
    this.showArtist = false,
    this.artistText = '',
  });

  final Song song;
  final bool showArtist;
  final String artistText;

  @override
  Widget build(BuildContext context) {
    final title = song.title.trim();
    final artist = artistText.trim();
    if (!showArtist || artist.isEmpty) {
      return Material(
        type: MaterialType.transparency,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.musicFlowTypography.title,
        ),
      );
    }
    // 歌名 - 歌手 同一行：歌名大、歌手小（muted），超宽时省略号截断，
    // 歌名在前优先保留。
    return Material(
      type: MaterialType.transparency,
      child: Text.rich(
        TextSpan(
          children: <TextSpan>[
            TextSpan(text: title, style: context.musicFlowTypography.title),
            TextSpan(
              text: ' - $artist',
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 迷你播放器当前歌词行：黄色显示（对齐主项目前端歌词配色）。
class _MiniPlayerLyric extends StatelessWidget {
  const _MiniPlayerLyric({required this.text});

  final String text;

  static const Color _lyricYellow = Color(0xFFFFD700);

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(top: context.musicFlowSpacing.xxs),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 歌词用 body(13) 而非 metadata(11)：现状偏小，适当放大。
          style: context.musicFlowTypography.body.copyWith(
            color: _lyricYellow,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 桌面端播放模式切换按钮(单一按钮,对齐主项目前端 cyclePlayMode):
/// 点击循环切换 order→one→all→shuffle,图标与文案随模式变换。
class _PlayModeButton extends StatelessWidget {
  const _PlayModeButton({required this.mode, required this.onPressed});

  final String mode;

  /// null 时按钮禁用(未提供回调)。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
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
    // 仅 随机/单曲 为「非常规顺序」态,高亮提示(对齐主项目前端 type=primary)。
    final selected = mode != 'all' && mode != 'order';
    return Tooltip(
      message: modeLabel,
      child: MusicFlowIconButton(
        icon: modeIcon,
        label: modeLabel,
        selected: selected,
        onPressed: onPressed,
      ),
    );
  }
}

/// 桌面端音量控制按钮：点击弹出滑块调节音量。
/// 对齐主项目前端 setVolume：
/// - 投屏(选中远端 peer) → POST /peers/:id/volume {volume:0-100}；
/// - 本机 → just_audio setVolume(0-1)，并持久化供下次启动恢复。
class VolumeButton extends ConsumerStatefulWidget {
  const VolumeButton({super.key, this.anchorTop = false});

  /// true 时音量弹窗贴近屏幕顶部(适用于全屏播放器右上角的音量按钮)；
  /// false 时贴近底部(迷你播放条使用)。
  final bool anchorTop;

  @override
  ConsumerState<VolumeButton> createState() => VolumeButtonState();
}

class VolumeButtonState extends ConsumerState<VolumeButton> {
  OverlayEntry? _overlayEntry;

  /// 拖动中的临时音量（0.0~1.0）。拖动期间优先显示它，松手后置空。
  double? _dragValue;

  /// 投屏端节流发送时间戳：拖动时 ≤10 次/秒，避免刷爆网络。
  DateTime? _lastCastVolumeSend;

  /// 本机端节流：拖动时避免每次 onChanged 都走 media_kit FFI（全局锁串行，
  /// 高频调用会堆积造成 UI 假死）。仅保留最新值，≤13 次/秒。
  DateTime? _lastLocalVolumeSend;
  double? _pendingLocalVolume;
  Timer? _localVolumeThrottleTimer;

  /// 当前控制目标音量（0.0~1.0）：投屏取 peer status.volume(0-100)，
  /// 本机取 playerState.volume。peer 未回报音量时回退本机音量。
  double _effectiveVolume() {
    final cast = ref.watch(castPeerControllerProvider);
    if (cast.activePeer != null && cast.status.volume != null) {
      return (cast.status.volume! / 100).clamp(0.0, 1.0).toDouble();
    }
    return ref.watch(playerProvider.select((s) => s.volume));
  }

  /// 本机音量实时跟手：节流合并，避免刷爆 media_kit FFI。
  void _sendLocalVolumeLive(double v) {
    _pendingLocalVolume = v;
    final now = DateTime.now();
    if (_lastLocalVolumeSend != null &&
        now.difference(_lastLocalVolumeSend!).inMilliseconds < 80) {
      // 距上次发送不足 80ms：记录最新值，由定时器统一发送。
      _localVolumeThrottleTimer ??= Timer(const Duration(milliseconds: 80), () {
        _localVolumeThrottleTimer = null;
        final pending = _pendingLocalVolume;
        if (pending != null) {
          _lastLocalVolumeSend = DateTime.now();
          ref.read(playerProvider.notifier).setVolumeLive(pending);
        }
      });
      return;
    }
    _lastLocalVolumeSend = now;
    ref.read(playerProvider.notifier).setVolumeLive(v);
  }

  /// 拖动中：按「切换播放器」所选目标**只写一路**——
  /// 本机 → setVolumeLive（节流，just_audio 实时跟手）；
  /// 投屏 → 节流 POST 到所选播放器（≤10 次/秒，不刷爆网络）。
  void _onSliderChanged(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    setState(() => _dragValue = clamped);
    final cast = ref.read(castPeerControllerProvider);
    if (cast.activePeer == null) {
      _sendLocalVolumeLive(clamped);
      return;
    }
    // 投屏：只写所选播放器，节流发送保持跟手。
    final now = DateTime.now();
    if (_lastCastVolumeSend == null ||
        now.difference(_lastCastVolumeSend!).inMilliseconds >= 100) {
      _lastCastVolumeSend = now;
      unawaited(
        ref
            .read(castPeerControllerProvider.notifier)
            .setVolume((clamped * 100).round()),
      );
    }
  }

  /// 松手：按所选播放器提交（本机落盘 / 投屏发最终值）。
  void _onSliderCommit(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    setState(() => _dragValue = null);
    _lastCastVolumeSend = null;
    _localVolumeThrottleTimer?.cancel();
    _localVolumeThrottleTimer = null;
    _pendingLocalVolume = null;
    final cast = ref.read(castPeerControllerProvider);
    if (cast.activePeer != null) {
      unawaited(
        ref
            .read(castPeerControllerProvider.notifier)
            .setVolume((clamped * 100).round()),
      );
    } else {
      unawaited(ref.read(playerProvider.notifier).setVolume(clamped));
    }
  }

  void _toggleOverlay() {
    if (_overlayEntry != null) {
      _removeOverlay();
      return;
    }
    // 弹出面板挂在根 Overlay 上,位于播放器 MusicFlowMediaColorScope 之外,
    // 直接使用根主题色会造成音量条与播放控件底色脱节。这里在打开时
    // 捕获本控件所在子树的**媒体自适应配色**(mini / stage 各自已按底色适配),
    // 让弹出的音量面板也用同一套配色渲染(见 _overlayTheme 与 Slider 配色)。
    final mediaColors = context.musicFlowColors;
    _overlayEntry = OverlayEntry(
      builder: (context) => _OverlayHost(
        mediaColors: mediaColors,
        child: Stack(
          children: <Widget>[
            // 点击弹窗外部任意位置自动关闭。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _removeOverlay,
              ),
            ),
            Positioned(
              bottom: widget.anchorTop ? null : 80,
              top: widget.anchorTop ? 16 : null,
              right: 16,
              child: GestureDetector(
                // 抢占命中：点击弹窗内部不触发外部关闭。
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Material(
                  color: Colors.transparent,
                  child: MusicFlowSurface(
                    level: MusicFlowSurfaceLevel.floating,
                    padding: EdgeInsets.all(context.musicFlowSpacing.sm),
                    child: SizedBox(
                      width: 64,
                      height: 184,
                      // overlay 内仍需响应外部音量变化（设备端/其它端修改）。
                      child: Consumer(
                        builder: (context, ref, _) {
                          final cast = ref.watch(castPeerControllerProvider);
                          final double sourceVolume;
                          if (cast.activePeer != null &&
                              cast.status.volume != null) {
                            sourceVolume = (cast.status.volume! / 100)
                                .clamp(0.0, 1.0)
                                .toDouble();
                          } else {
                            sourceVolume = ref.watch(
                              playerProvider.select((s) => s.volume),
                            );
                          }
                          // 拖动中显示拖动值，否则显示真实值。
                          final volume = _dragValue ?? sourceVolume;
                          final percent = (volume * 100).round();
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 实时显示当前音量数值（拖动时随状态刷新）。
                              Text(
                                '$percent%',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: context.musicFlowColors.ink,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: 40,
                                height: 140,
                                child: RotatedBox(
                                  quarterTurns: -1,
                                  child: Slider(
                                    value: volume,
                                    // 音量条配色跟随播放控件底色:
                                    // 已激活段用控件强调色,未激活段用弱化前景,
                                    // 与播放控件的按钮/文字色一致。
                                    activeColor: mediaColors.accent,
                                    inactiveColor: mediaColors.muted
                                        .withValues(alpha: 0.38),
                                    onChanged: _onSliderChanged,
                                    onChangeEnd: _onSliderCommit,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    _localVolumeThrottleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final volume = _dragValue ?? _effectiveVolume();
    final percent = (volume * 100).round();
    // 对齐主项目前端音量按钮:音量>0 显示扬声器+声波,=0 显示静音;
    // 弹窗展开时高亮(对应前端 vol-active)。
    final icon = volume > 0 ? AppIcons.volumeHigh : AppIcons.volumeMute;
    return Tooltip(
      message: '音量 $percent%',
      child: MusicFlowIconButton(
        icon: icon,
        label: '音量 $percent%',
        selected: _overlayEntry != null,
        foregroundColor: context.musicFlowColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: _toggleOverlay,
      ),
    );
  }
}

/// 音量弹窗宿主：Overlay 位于播放器 MusicFlowMediaColorScope 之外，这里把
/// 打开时捕获的媒体自适应配色重新装回本子树，使面板背景、文字与
/// 音量条全部沿用「播放控件底色」渲染。
class _OverlayHost extends StatelessWidget {
  const _OverlayHost({
    required this.mediaColors,
    required this.child,
  });

  final MusicFlowColors mediaColors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final extensions = List<ThemeExtension<dynamic>>.of(base.extensions.values)
      ..removeWhere((extension) => extension is MusicFlowColors)
      ..add(mediaColors);
    return Theme(
      data: base.copyWith(extensions: extensions),
      child: child,
    );
  }
}

class _MiniPlayerScrubBubble extends StatelessWidget {
  const _MiniPlayerScrubBubble({
    required this.progress,
    required this.duration,
  });

  final double progress;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final position = Duration(
      milliseconds: (duration.inMilliseconds * progress).round(),
    );

    return Align(
      alignment: Alignment((progress * 2 - 1).clamp(-1.0, 1.0), 0),
      child: MusicFlowSurface(
        level: MusicFlowSurfaceLevel.floating,
        color: context.musicFlowColors.ink,
        borderRadius: context.musicFlowRadii.detail,
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowSpacing.xs,
          vertical: context.musicFlowSpacing.xxs,
        ),
        child: Text(
          _formatPlayerDuration(position),
          style: context.musicFlowTypography.metadata.copyWith(
            color: context.musicFlowColors.canvas,
          ),
        ),
      ),
    );
  }
}

/// 「切换播放器」底部弹层 —— 对齐主项目前端「选择播放器」。
/// 数据源为主项目后端 GET /rest/api/v1/peers(本机 + DLNA/AirPlay/群组);
/// 选中远端 peer = 纯 UI 控制目标切换(对齐前端 switchPeer):不推队列/不投屏,
/// 此后点歌/专辑/歌单由后端在设备播放,客户端是后端的远程遥控器。
class PlayerSwitcherSheet extends ConsumerStatefulWidget {
  const PlayerSwitcherSheet({super.key});

  @override
  ConsumerState<PlayerSwitcherSheet> createState() =>
      _PlayerSwitcherSheetState();
}

class _PlayerSwitcherSheetState extends ConsumerState<PlayerSwitcherSheet> {
  List<PeerInfo>? _peers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  /// 直接加载后端 /peers 列表即可：后端本身持续自动扫描设备并维护
  /// available 状态，客户端不再额外触发 dlna/scan（避免每次切播放器都扫描）。
  Future<void> _reload() async {
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = await controller.loadPeers();
    if (mounted) setState(() => _peers = peers);
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(castPeerControllerProvider);
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = _peers;
    // 只展示后端回报为可用（available）的远端设备，离线设备不显示。
    final remotePeers = (peers ?? const <PeerInfo>[])
        .where((p) => !p.isLocal && p.available)
        .toList();

    return MusicFlowBottomSheet(
      title: '选择播放器',
      subtitle: '切换播放器仅改变当前控制目标,不会停止其他播放器。',
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              MusicFlowActionRow(
                icon: AppIcons.headphones,
                title: '本机播放',
                subtitle: cast.activePeer != null
                    ? (cast.offline ? '设备离线,已暂停轮询' : '当前正在投屏')
                    : '使用此设备扬声器',
                selected: cast.activePeer == null,
                onPressed: () async {
                  // 回本机=仅切换控制目标(远端继续播,对齐前端 switchPeer);
                  // 用户主动选「本机播放」,快照当时在播则续播本机。
                  await controller.backToLocal(resumeLocal: true);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              if (cast.activePeer != null)
                MusicFlowActionRow(
                  icon: AppIcons.close,
                  title: '停止投屏',
                  subtitle: '停止「${cast.activePeer!.name}」播放并清除控制',
                  onPressed: () async {
                    await controller.stopCasting();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              if (remotePeers.isNotEmpty)
                for (final peer in remotePeers)
                  MusicFlowActionRow(
                    icon: switch (peer.kind) {
                      'group' => AppIcons.people,
                      'airplay' => AppIcons.signalTower,
                      _ => AppIcons.signalTower,
                    },
                    title: peer.name,
                    subtitle: <String>[
                      peer.kindLabel,
                      if (peer.queueTotal > 0) peer.queueLabel,
                    ].join(' · '),
                    selected: cast.activePeer?.peerId == peer.peerId,
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      final ok = await controller.switchTo(peer);
                      if (!ok && context.mounted) {
                        showMusicFlowMessage(
                          context,
                          '切换到「${peer.name}」失败,请检查设备是否在线',
                          kind: MusicFlowMessageKind.error,
                        );
                        return;
                      }
                      navigator.pop();
                    },
                  )
              else
                Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: context.musicFlowSpacing.sm,
                  ),
                  child: Text(
                    _peers == null ? '正在获取可用播放器…' : '未发现其他可用播放器。',
                    style: context.musicFlowTypography.body.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
                ),
              MusicFlowActionRow(
                icon: AppIcons.refresh,
                title: '刷新播放器列表',
                trailing: cast.loadingPeers
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onPressed: cast.loadingPeers ? null : () => _reload(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 电脑端「切换播放器」小弹窗：播放控件上方弹出、点击外部自动关闭。
/// 数据源直接取后端 /peers 列表（后端自行扫描维护可用状态，客户端不触发
/// 扫描）；只展示 available 的远端设备，离线设备不显示。
/// 切换完成或关闭后通过 [onSwitched] 回调通知调用方弹出右上角 Toast。
class PlayerSwitcherPopover extends ConsumerStatefulWidget {
  const PlayerSwitcherPopover({super.key, required this.onSwitched});

  /// 切换完成（或用户主动关闭）时回调，参数为要展示的 Toast 文案。
  final ValueChanged<String?> onSwitched;

  @override
  ConsumerState<PlayerSwitcherPopover> createState() =>
      _PlayerSwitcherPopoverState();
}

class _PlayerSwitcherPopoverState extends ConsumerState<PlayerSwitcherPopover> {
  List<PeerInfo>? _peers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = await controller.loadPeers();
    if (mounted) setState(() => _peers = peers);
  }

  void _close({String? toast}) {
    widget.onSwitched(toast);
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(castPeerControllerProvider);
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = _peers;
    final remotePeers = (peers ?? const <PeerInfo>[])
        .where((p) => !p.isLocal && p.available)
        .toList();
    final isDesktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

    return Stack(
      children: <Widget>[
        // 点击弹窗外任意位置自动关闭。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _close(),
          ),
        ),
        Positioned(
          // 播放控件(MiniPlayer)上方的小弹窗。
          bottom: isDesktop ? MiniPlayer.height + 24 : 80,
          right: 16,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              constraints: const BoxConstraints(maxHeight: 380),
              child: MusicFlowSurface(
                level: MusicFlowSurfaceLevel.floating,
                borderRadius: context.musicFlowRadii.scene,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.musicFlowSpacing.sm,
                        context.musicFlowSpacing.xs,
                        context.musicFlowSpacing.xs,
                        context.musicFlowSpacing.xxs,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '选择播放器',
                              style: context.musicFlowTypography.headline,
                            ),
                          ),
                          MusicFlowIconButton(
                            icon: AppIcons.close,
                            label: '关闭',
                            onPressed: () => _close(),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          context.musicFlowSpacing.xs,
                          0,
                          context.musicFlowSpacing.xs,
                          context.musicFlowSpacing.xs,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            MusicFlowActionRow(
                              icon: AppIcons.headphones,
                              title: '本机播放',
                              subtitle: cast.activePeer != null
                                  ? (cast.offline ? '设备离线,已暂停轮询' : '当前正在投屏')
                                  : '使用此设备扬声器',
                              selected: cast.activePeer == null,
                              onPressed: () async {
                                await controller.backToLocal(resumeLocal: true);
                                _close(toast: '已切换为本机播放');
                              },
                            ),
                            if (cast.activePeer != null)
                              MusicFlowActionRow(
                                icon: AppIcons.close,
                                title: '停止投屏',
                                subtitle: '停止「${cast.activePeer!.name}」播放并清除控制',
                                onPressed: () async {
                                  await controller.stopCasting();
                                  _close(toast: '已停止投屏');
                                },
                              ),
                            if (remotePeers.isNotEmpty)
                              for (final peer in remotePeers)
                                MusicFlowActionRow(
                                  icon: switch (peer.kind) {
                                    'group' => AppIcons.people,
                                    _ => AppIcons.signalTower,
                                  },
                                  title: peer.name,
                                  subtitle: <String>[
                                    peer.kindLabel,
                                    if (peer.queueTotal > 0) peer.queueLabel,
                                  ].join(' · '),
                                  selected:
                                      cast.activePeer?.peerId == peer.peerId,
                                  onPressed: () async {
                                    final ok = await controller.switchTo(peer);
                                    if (!ok) {
                                      if (context.mounted) {
                                        showMusicFlowMessage(
                                          context,
                                          '切换到「${peer.name}」失败,请检查设备是否在线',
                                          kind: MusicFlowMessageKind.error,
                                        );
                                      }
                                      return;
                                    }
                                    _close(toast: '正在远控「${peer.name}」');
                                  },
                                )
                            else
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  vertical: context.musicFlowSpacing.sm,
                                ),
                                child: Text(
                                  _peers == null ? '正在获取可用播放器…' : '未发现其他可用播放器。',
                                  style: context.musicFlowTypography.body.copyWith(
                                    color: context.musicFlowColors.muted,
                                  ),
                                ),
                              ),
                            MusicFlowActionRow(
                              icon: AppIcons.refresh,
                              title: '刷新播放器列表',
                              trailing: cast.loadingPeers
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : null,
                              onPressed: cast.loadingPeers
                                  ? null
                                  : () => _reload(),
                            ),
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
    );
  }
}
