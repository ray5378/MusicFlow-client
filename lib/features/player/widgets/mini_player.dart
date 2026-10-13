import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';

import 'package:musicflow_client/features/player/widgets/mini_player_controls.dart';
import 'package:musicflow_client/features/player/widgets/mini_player_progress_surface.dart';
import 'package:musicflow_client/features/player/widgets/mini_player_track.dart';

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
    final playbackMode = ref.watch(
      playerProvider.select((s) => s.playbackMode),
    );
    final cast = ref.watch(castPeerControllerProvider);
    final isCasting = cast.activePeer != null;
    final dlnaCast = ref.watch(dlnaCastProvider);
    final dlnaCasting = dlnaCast.isCasting;

    // 投屏(流转播放)激活时,迷你条反映后端 peer 的实时状态:
    // 曲目经队列 currentIndex 回写同步,进度/播放态取自 /peers/:id/status。
    final playerState = PlayerState(
      currentSong: currentSong,
      queue: queue,
      currentIndex: currentIndex,
      isPlaying: ref.watch(effectiveIsPlayingProvider),
      shuffleEnabled: playbackMode == PlaybackMode.shuffle,
      loopMode: playbackMode == PlaybackMode.one ? LoopMode.one : LoopMode.off,
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
              : playbackMode.name); // 本机:四态权威值(order/all/one/shuffle)

    return MiniPlayerView(
      playerState: playerState,
      mediaVisuals: visuals,
      lyricLine: lyricLine,
      onOpenPlayer: () => _openFullPlayer(context),
      onTogglePlayPause: () => toggleEffectivePlayback(ref),
      onSeek: (position) => seekEffectivePlayback(ref, position),
      progressLayer: const ProviderMiniPlayerProgress(),
      onSwitchPlayer: () => showPlayerSwitcher(
        context: context,
        ref: ref,
        onTransfer: (from, to) async {
          final controller = ref.read(castPeerControllerProvider.notifier);
          final loc = AppLocalizations.of(context);
          final ok = await controller.transferQueue(from, to);
          if (context.mounted) {
            ref.invalidate(peerNowPlayingProvider(from.peerId));
            ref.invalidate(peerNowPlayingProvider(to.peerId));
            showMusicFlowMessage(
              context,
              ok
                  ? loc.player_handoff_push_success(to.name)
                  : loc.player_handoff_failed,
              kind: ok
                  ? MusicFlowMessageKind.success
                  : MusicFlowMessageKind.error,
            );
          }
          return ok;
        },
      ),
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
}

/// 打开「流转播放」**专用页面**。
///
/// 入口收敛（2026-09-16）：MINI 条最右侧「流转播放」按钮 = 进页面；
/// 原桌面遮盖小弹窗（PlayerSwitcherPopover）与移动端底部弹层均已移除，
/// 封面长按旧入口也已移除。桌面歌词浮窗的设备列表走原生层独立通道
/// （statusLyricsController.requestSwitchList），与本函数无关。
Future<void> showPlayerSwitcher({
  required BuildContext context,
  required WidgetRef ref,
  required Future<bool> Function(PeerInfo from, PeerInfo to) onTransfer,
}) {
  return PlayerTransferPage.open(context, onTransfer: onTransfer);
}

/// Pure player surface kept public so gesture, semantics and large-text
/// behaviour can be tested without constructing the audio engine.
@visibleForTesting
class MiniPlayerView extends ConsumerStatefulWidget {
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
  ConsumerState<MiniPlayerView> createState() => _MiniPlayerViewState();
}

class _MiniPlayerViewState extends ConsumerState<MiniPlayerView> {
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

  /// 控件区：桌面端响应式渐隐 / 手机端简略版。
  /// v5.8.4 拆分为 [MiniPlayerControls] 构建器（显式参数取代对 view state
  /// 的引用，逻辑逐行搬运，行为零变更）。
  List<Widget> _buildControls(
    BuildContext context, {
    required double windowWidth,
  }) {
    return MiniPlayerControls(
      isPlaying: _playerState.isPlaying,
      isFavorite: _playerState.currentSong?.starred ?? false,
      currentPlayerName: widget.currentPlayerName,
      isCasting: widget.isCasting,
      playMode: widget.playMode,
      onTogglePlayPause: _togglePlayPause,
      onPrevious: widget.onPrevious,
      onNext: widget.onNext,
      onTogglePlayMode: widget.onTogglePlayMode,
      onToggleFavorite: widget.onToggleFavorite,
      onSwitchPlayer: widget.onSwitchPlayer,
      onOpenQueue: widget.onOpenQueue,
    ).buildControls(context, isDesktop: _isDesktop, windowWidth: windowWidth);
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
                                  child: MiniPlayerTrack(
                                    song: song,
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
                            ..._buildControls(
                              context,
                              windowWidth: constraints.maxWidth,
                            ),
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
                            MiniPlayerProgressSurface(
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

/// 「流转播放」底部弹层 —— 对齐主项目前端「流转播放」。
/// 数据源为主项目后端 GET /rest/api/v1/peers(本机 + DLNA/AirPlay/群组);
/// 选中远端 peer = 纯 UI 控制目标切换(对齐前端 switchPeer):不推队列/不投屏,
/// 此后点歌/专辑/歌单由后端在设备播放,客户端是后端的远程遥控器。
