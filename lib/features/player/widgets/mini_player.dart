import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/features/player/widgets/volume_button.dart';
import 'package:musicflow_client/features/player/widgets/player_switcher.dart';

/// Stable bridge between the application shell and the immersive player.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  // 对齐箭头音乐：底部悬浮胶囊更紧凑。
  static const double height = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 按需字段逐个 select 监听：避免整棵迷你条因播放进度等高频状态
    // （约每 200~500ms 一次 position/buffering 更新）被反复重建。
    final currentSong = ref.watch(playerProvider.select((s) => s.currentSong));
    final queue = ref.watch(playerProvider.select((s) => s.queue));
    final currentIndex = ref.watch(playerProvider.select((s) => s.currentIndex));
    final shuffleEnabled = ref.watch(
      playerProvider.select((s) => s.shuffleEnabled),
    );
    final loopMode = ref.watch(playerProvider.select((s) => s.loopMode));
    final cast = ref.watch(castPeerControllerProvider);
    final isCasting = cast.activePeer != null;
    final dlnaCast = ref.watch(dlnaCastProvider);
    final dlnaCasting = dlnaCast.isCasting;

    // 投屏(切换播放器)激活时,迷你条反映后端 peer 的实时状态:
    // 曲目经队列 currentIndex 回写同步,进度/播放态取自 /peers/:id/status。
    final playerState = PlayerState(
      currentSong: currentSong,
      queue: queue,
      currentIndex: currentIndex,
      isPlaying: ref.watch(effectiveIsPlayingProvider),
      shuffleEnabled: shuffleEnabled,
      loopMode: loopMode,
      position: ref.watch(frozenPositionProvider),
      duration: ref.watch(effectiveDurationProvider),
    );
    final visuals = ref.watch(resolvedCurrentSongMediaVisualsProvider);
    final lyricLine = ref.watch(frozenLyricLineProvider);
    // 播放模式(对齐主项目前端 playMode:order|one|all|shuffle)。
    // 链路 B(DLNA 直投)投屏态:以 dlnaCast.playMode 为准;链路 A 投屏态以后端
    // playMode 为准;本机以本地 shuffleEnabled + loopMode 推导。
    final mode = dlnaCasting
        ? dlnaCast.playMode
        : (isCasting
              ? cast.playMode
              : (shuffleEnabled
                    ? 'shuffle'
                    : (loopMode == LoopMode.one ? 'one' : 'all')));

    return MiniPlayerView(
      playerState: playerState,
      mediaVisuals: visuals,
      lyricLine: lyricLine,
      onOpenPlayer: () => _openFullPlayer(context),
      onTogglePlayPause: () => toggleEffectivePlayback(ref),
      onSeek: (position) => seekEffectivePlayback(ref, position),
      progressLayer: const _ProviderMiniPlayerProgress(),
      onSwitchPlayer: () => _showPlayerSwitcher(context: context, ref: ref),
      onPrevious: () => dlnaCasting
        ? ref.read(dlnaCastProvider.notifier).previous()
        : (isCasting
              ? ref.read(castPeerControllerProvider.notifier).previous()
              : ref.read(playerProvider.notifier).previous()),
      onNext: () => dlnaCasting
          ? ref.read(dlnaCastProvider.notifier).next()
          : (isCasting
                ? ref.read(castPeerControllerProvider.notifier).next()
                : ref.read(playerProvider.notifier).next()),
      playMode: mode,
      onTogglePlayMode: () => dlnaCasting
          ? ref.read(dlnaCastProvider.notifier).cyclePlayMode()
          : (isCasting
                ? ref.read(castPeerControllerProvider.notifier).cyclePlayMode()
                : ref.read(playerProvider.notifier).cyclePlaybackMode()),
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
  }) {
    // 统一走顶层 showPlayerSwitcher，避免两份平台分支逻辑漂移。
    return showPlayerSwitcher(context: context, ref: ref);
  }
}

/// 桌面端（Windows/macOS/Linux）：用播放控件上方的小弹窗代替安卓底部弹层。
bool _isDesktopShell(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.windows ||
  TargetPlatform.macOS ||
  TargetPlatform.linux => true,
  _ => false,
};

/// 打开「切换播放器」弹窗（平台自适应：桌面小弹窗 / 移动端底部弹层）。
///
/// 供迷你播放条按钮与 Windows 桌面歌词浮窗的「切换播放器」按钮共用——
/// 后者经 tray 字符串通道回传 `switch_player`，由 MainScaffold 调用本函数。
Future<void> showPlayerSwitcher({
  required BuildContext context,
  required WidgetRef ref,
}) {
  final loc = AppLocalizations.of(context);
  if (_isDesktopShell(context)) {
    showPlayerSwitcherPopover(context: context);
    return Future<void>.value();
  }
  return showMusicFlowBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => const PlayerSwitcherSheet(),
  ).then((_) {
    if (context.mounted) {
      final cast = ref.read(castPeerControllerProvider);
      showMusicFlowToast(
        context,
        cast.activePeer != null
            ? loc.player_remote_control(currentPlayerName(cast))
            : loc.player_switched_local,
        kind: MusicFlowMessageKind.success,
      );
    }
  });
}

/// 桌面端「切换播放器」小弹窗：以 Overlay 呈现，播放控件上方小窗，
/// 点击弹窗外任意位置关闭；切换完成后弹出右上角 Toast 反馈。
void showPlayerSwitcherPopover({required BuildContext context}) {
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
    // 默认值必须是 const,无法依赖 AppLocalizations;真实调用方(MiniPlayer)总会显式传入。
    this.currentPlayerName = '',
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
    final loc = AppLocalizations.of(context);
    final isFav = _playerState.currentSong?.starred ?? false;
    return <Widget>[
      Tooltip(
        message: loc.player_previous,
        child: MusicFlowIconButton(
          icon: AppIcons.previous,
          label: loc.player_previous,
          iconSize: 20,
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onPrevious,
        ),
      ),
      Tooltip(
        message: _playerState.isPlaying ? loc.player_pause : loc.widgets_play,
        child: MusicFlowIconButton(
          icon: _playerState.isPlaying ? AppIcons.pause : AppIcons.play,
          label: _playerState.isPlaying ? loc.player_pause : loc.widgets_play,
          iconSize: 20,
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: _togglePlayPause,
        ),
      ),
      Tooltip(
        message: loc.player_next,
        child: MusicFlowIconButton(
          icon: AppIcons.next,
          label: loc.player_next,
          iconSize: 20,
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onNext,
        ),
      ),
      _PlayModeButton(
        mode: widget.playMode,
        iconSize: 20,
        onPressed: widget.onTogglePlayMode,
      ),
      Tooltip(
        message: isFav ? loc.player_unfavorite : loc.player_favorite,
        child: MusicFlowIconButton(
          icon: isFav ? AppIcons.heart : AppIcons.heartOutline,
          label: isFav ? loc.player_unfavorite : loc.player_favorite,
          iconSize: 20,
          selected: isFav,
          onPressed: widget.onToggleFavorite,
        ),
      ),
      Tooltip(
        message: loc.player_playlist_label,
        child: MusicFlowIconButton(
          icon: AppIcons.queue,
          label: loc.player_playlist_label,
          iconSize: 20,
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onOpenQueue,
        ),
      ),
      const VolumeButton(),
      Tooltip(
        message: loc.player_switch_current(widget.currentPlayerName),
        child: MusicFlowIconButton(
          icon: AppIcons.signalTower,
          label: loc.player_switch_current(widget.currentPlayerName),
          iconSize: 20,
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
    final loc = AppLocalizations.of(context);
    return <Widget>[
      MusicFlowIconButton(
        icon: _playerState.isPlaying ? AppIcons.pause : AppIcons.play,
        label: _playerState.isPlaying ? loc.player_pause : loc.widgets_play,
        iconSize: 20,
        foregroundColor: context.musicFlowColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: _togglePlayPause,
      ),
      MusicFlowIconButton(
        icon: AppIcons.signalTower,
        label: loc.player_switch_current(widget.currentPlayerName),
        iconSize: 20,
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
    // 歌词高亮与大屏歌词页同取色：暖黄对迷你条底色做 4.5:1 自适应，
    // 随封面配色自动变化，不再写死黄色。
    final lyricAccent = MusicFlowMediaVisuals.lyricAccentFor(
      visuals,
      backgrounds: <Color>[visuals.miniSurface],
    );
    // 封面外圈进度环：进度与进度层同源（_playerState 的 position/duration
    // 由外层用 effective provider 填充）；环色与大屏歌词取色一致 ——
    // 暖黄对迷你条底色做 4.5:1 自适应（同 lyricAccent）。
    final coverRingProgress = _playerState.duration.inMilliseconds > 0
        ? (_playerState.position.inMilliseconds /
              _playerState.duration.inMilliseconds)
        : 0.0;
    final coverRingColor = lyricAccent;

    return MusicFlowMediaColorScope(
      visuals: visuals,
      role: MusicFlowMediaSurfaceRole.mini,
      child: Builder(
        builder: (context) {
          final loc = AppLocalizations.of(context);
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          final showSubtitle = textScale <= 1.4;
          final semanticState = _playerState.isPlaying ? loc.player_playing_state : loc.player_paused_state;
          final songTitle = song?.title ?? loc.player_not_playing;
          final semanticSubtitle = song?.artist?.trim().isNotEmpty == true
              ? '，${song!.artist!.trim()}'
              : '';

          return Semantics(
            container: true,
            explicitChildNodes: true,
            label: loc.player_mini_semantic(songTitle, semanticSubtitle),
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
                        context.musicFlowSpacing.xxs,
                        context.musicFlowSpacing.xs,
                        context.musicFlowSpacing.xxs,
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
                                    lyricAccent: lyricAccent,
                                    coverRingProgress: coverRingProgress,
                                    coverRingColor: coverRingColor,
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
                        // 与 backdrop 一致：四边圆弧的悬浮胶囊。
                        borderRadius: context.musicFlowRadii.scene,
                        child:
                            widget.progressLayer ??
                            _MiniPlayerProgressSurface(
                              // 与全屏页同款守卫：songId 变化时 State 重建，
                              // 拖动中的旧比例不会套到新歌时长上。
                              key: ValueKey<String?>(
                                _playerState.currentSong?.id,
                              ),
                              songId: _playerState.currentSong?.id,
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
    // 冻结进度：窗口不可见时拖拽手势层的 position 不再高频重建。
    // songId 用 select 只在切歌时重建（对齐全屏页的拖动守卫）。
    final position = ref.watch(frozenPositionProvider);
    final duration = ref.watch(effectiveDurationProvider);
    final songId = ref.watch(
      playerProvider.select((state) => state.currentSong?.id),
    );
    return _MiniPlayerProgressSurface(
      key: ValueKey<String?>(songId),
      songId: songId,
      position: position,
      duration: duration,
      onSeek: (target) => seekEffectivePlayback(ref, target),
    );
  }
}

class _MiniPlayerProgressSurface extends StatefulWidget {
  const _MiniPlayerProgressSurface({
    super.key,
    required this.songId,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final String? songId;
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
  // 拖动会话开始时锁定的歌曲 id：切歌后旧拖动会话立即作废，
  // 防止把旧歌的比例换算到新歌 duration 上（对齐全屏页 _dragSongId）。
  String? _scrubSongId;

  void _handleProgressDragStart(DragStartDetails details) {
    if (widget.duration <= Duration.zero) return;
    setState(() {
      _scrubbing = true;
      _scrubSongId = widget.songId;
      _scrubProgress = _progressFromDx(details.localPosition.dx);
    });
  }

  void _handleProgressDragUpdate(DragUpdateDetails details) {
    if (!_scrubbing || widget.duration <= Duration.zero) return;
    if (_scrubSongId != widget.songId) {
      _handleProgressDragCancel();
      return;
    }
    setState(() {
      _scrubProgress = _progressFromDx(details.localPosition.dx);
    });
  }

  void _handleProgressDragEnd(DragEndDetails details) {
    final progress = _scrubProgress;
    final durationMs = widget.duration.inMilliseconds;
    // 只有拖动会话锁定的歌曲与当前歌曲一致时才 seek。
    final sameSong = _scrubSongId != null && _scrubSongId == widget.songId;
    if (_scrubbing && progress != null && durationMs > 0 && sameSong) {
      HapticFeedback.selectionClick();
      unawaited(
        widget.onSeek(Duration(milliseconds: (durationMs * progress).round())),
      );
    }
    setState(() {
      _scrubbing = false;
      _scrubProgress = null;
      _scrubSongId = null;
    });
  }

  void _handleProgressDragCancel() {
    if (!_scrubbing) return;
    setState(() {
      _scrubbing = false;
      _scrubProgress = null;
      _scrubSongId = null;
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
    final loc = AppLocalizations.of(context);
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
                label: loc.player_progress,
                value: progressValue,
                increasedValue: loc.player_seek_forward,
                decreasedValue: loc.player_seek_backward,
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
        // 底部横向进度条已移除：进度改为封面外圈进度环（见
        // _MiniPlayerProgressRing），这里只保留拖拽手势层与气泡。
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
    required this.lyricAccent,
    required this.coverRingProgress,
    required this.coverRingColor,
  });

  final Song? song;
  final bool useHero;
  final bool showSubtitle;
  final String? lyricLine;

  /// 歌词高亮色：与大屏歌词页同源自适应暖黄。
  final Color lyricAccent;

  /// 封面外圈进度环：0~1 播放进度（浅底黑环、深底白环）。
  final double coverRingProgress;
  final Color coverRingColor;

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
    final coverInner = _MiniPlayerCover(song: song);
    // Hero 只包封面本体，进度环作为外层包装不参与飞行过渡。
    final coverHero = useHero
        ? Hero(
            tag: playerCoverHeroTag,
            createRectTween: playerCoverRectTween,
            child: coverInner,
          )
        : coverInner;
    // RepaintBoundary:进度环 200~500ms 重绘隔离在 46px 环内,不连带
    // 封面/歌名/歌词/背景等整条迷你条重绘(智能按需渲染 §GPU 门控)。
    final cover = RepaintBoundary(
      child: _MiniPlayerProgressRing(
        progress: coverRingProgress,
        color: coverRingColor,
        child: coverHero,
      ),
    );
    final title = _MiniPlayerTitle(
      song: song,
      showArtist: showSubtitle,
      artistText: showSubtitle ? artistLine : '',
    );

    return Row(
      children: <Widget>[
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
              // 当前歌词行：暖黄高亮，取色与大屏歌词页一致（随封面自适应）。
              // RepaintBoundary:歌词行切换的重绘只影响本行文本区域。
              if (lyric != null)
                RepaintBoundary(
                  child: _MiniPlayerLyric(text: lyric, color: lyricAccent),
                ),
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
    final loc = AppLocalizations.of(context);
    return Row(
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: context.musicFlowColors.surface,
            shape: BoxShape.circle,
          ),
          child: Icon(
            AppIcons.music,
            size: 22,
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
                loc.player_not_playing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.musicFlowTypography.title,
              ),
              if (showSubtitle)
                Text(
                  loc.player_choose_song_prompt,
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
    final loc = AppLocalizations.of(context);
    return SizedBox.square(
      dimension: 44,
      child: ClipOval(
        child: CoverArtImage(
          coverArtId: song.artworkReference,
          size: 44,
          requestSize: 320,
          fit: BoxFit.cover,
          semanticLabel: loc.song_cover_semantic(song.title),
        ),
      ),
    );
  }
}

/// 封面外圈播放进度环：替代底部横向进度条（对齐箭头音乐）。
///
/// 环色由底色明暗决定：浅底黑环、深底白环（与 [MusicFlowColors.readableOn]
/// 同规则），保证任意封面上都清晰可见。
class _MiniPlayerProgressRing extends StatelessWidget {
  const _MiniPlayerProgressRing({
    required this.progress,
    required this.color,
    required this.child,
  });

  final double progress;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // 高度核算（避免圆环被播放条裁剪）：
    //   播放条 = MiniPlayer.height(56)；内容区 = 56 - 上下 padding(4+4) = 48；
    //   环取 46（封面 44 + 两侧各 1），在 48 内容区内居中，上下各留 1px 余量，
    //   任何 1px 级的布局误差都不会触发 ClipRect(48) 裁剪。
    const double ringDimension = 46;
    const double coverDimension = 44;
    final normalized = progress.clamp(0.0, 1.0).toDouble();
    return SizedBox.square(
      dimension: ringDimension,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          SizedBox.square(
            dimension: ringDimension,
            child: Semantics(
              label: loc.player_progress_percent((normalized * 100).round()),
              child: ExcludeSemantics(
                child: CircularProgressIndicator(
                  value: normalized,
                  strokeWidth: 2,
                  // 底色用同色低透明度做轨道，让环在任意底色上都可辨认。
                  backgroundColor: color.withValues(alpha: 0.18),
                  color: color,
                ),
              ),
            ),
          ),
          SizedBox.square(
            dimension: coverDimension,
            child: child,
          ),
        ],
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

/// 迷你播放器当前歌词行：暖黄高亮，取色与大屏歌词页同源（随封面自适应）。
class _MiniPlayerLyric extends StatelessWidget {
  const _MiniPlayerLyric({required this.text, required this.color});

  final String text;
  final Color color;

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
            color: color,
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
  const _PlayModeButton({
    required this.mode,
    required this.onPressed,
    // 与 MusicFlowIconButton.iconSize 默认值保持一致(非空)。
    this.iconSize = 22,
  });

  final String mode;

  /// null 时按钮禁用(未提供回调)。
  final VoidCallback? onPressed;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final modeIcon = switch (mode) {
      'shuffle' => AppIcons.shuffle,
      'one' => AppIcons.repeatOne,
      'order' => AppIcons.orderPlayback,
      _ => AppIcons.repeat,
    };
    final modeLabel = switch (mode) {
      'shuffle' => loc.player_mode_shuffle,
      'one' => loc.player_mode_loop_one,
      'order' => loc.player_mode_order,
      _ => loc.player_mode_list,
    };
    // 仅 随机/单曲 为「非常规顺序」态,高亮提示(对齐主项目前端 type=primary)。
    final selected = mode != 'all' && mode != 'order';
    return Tooltip(
      message: modeLabel,
      child: MusicFlowIconButton(
        icon: modeIcon,
        label: modeLabel,
        iconSize: iconSize,
        selected: selected,
        onPressed: onPressed,
      ),
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
