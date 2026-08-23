import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import '../../../core/design/echo_design.dart';
import '../../../data/models/peer.dart';
import '../../../data/models/song.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/cast_peer_provider.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/lyrics_cover_provider.dart';
import '../../../providers/palette_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/cover_art_image.dart';
import '../pages/full_player_page.dart';
import 'player_hero_helpers.dart';

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
      onToggleShuffle: () => ref.read(playerProvider.notifier).toggleShuffle(),
      onToggleRepeat: () => ref.read(playerProvider.notifier).toggleLoopMode(),
      currentPlayerName: currentPlayerName(cast),
      isCasting: isCasting,
    );
  }

  static void _openFullPlayer(BuildContext context) {
    final duration = context.echoMotion.resolve(
      context,
      context.echoMotion.scene,
    );
    Navigator.of(context).push(
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
    await showEchoBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => const PlayerSwitcherSheet(),
    );
    if (context.mounted) {
      final cast = ref.read(castPeerControllerProvider);
      showEchoMessage(
        context,
        cast.activePeer != null
            ? '正在投屏到「${currentPlayerName(cast)}」'
            : '已切换为本机播放',
        kind: EchoMessageKind.success,
      );
    }
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
    this.onToggleShuffle,
    this.onToggleRepeat,
    this.currentPlayerName = '本机',
    this.isCasting = false,
    this.lyricLine,
    this.mediaVisuals,
    this.albumColor,
    this.progressLayer,
  });

  final PlayerState playerState;
  final EchoMediaVisuals? mediaVisuals;

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
  final VoidCallback? onToggleShuffle;
  final VoidCallback? onToggleRepeat;

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

  /// 桌面端全控件：上一首 / 播放暂停 / 下一首 / 随机 / 循环 / 音量 / 投屏。
  /// 每个按钮包一层 Tooltip（悬停显示文字注释，对齐主项目前端），
  /// 随机/循环带激活态反馈（选中高亮 + 文案随状态变化）。
  List<Widget> _buildDesktopControls(BuildContext context) {
    final loopMode = _playerState.loopMode;
    final repeatActive = loopMode != LoopMode.off;
    final repeatLabel = switch (loopMode) {
      LoopMode.one => '单曲循环',
      LoopMode.all => '列表循环',
      LoopMode.off => '循环播放',
    };
    return <Widget>[
      Tooltip(message: '上一首', child: EchoIconButton(
        icon: AppIcons.previous,
        label: '上一首',
        foregroundColor: context.echoColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: widget.onPrevious,
      )),
      Tooltip(
        message: _playerState.isPlaying ? '暂停' : '播放',
        child: EchoIconButton(
          icon: _playerState.isPlaying ? AppIcons.pause : AppIcons.play,
          label: _playerState.isPlaying ? '暂停' : '播放',
          foregroundColor: context.echoColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: _togglePlayPause,
        ),
      ),
      Tooltip(message: '下一首', child: EchoIconButton(
        icon: AppIcons.next,
        label: '下一首',
        foregroundColor: context.echoColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: widget.onNext,
      )),
      Tooltip(
        message: _playerState.shuffleEnabled ? '随机播放中，点击关闭' : '随机播放',
        child: EchoIconButton(
          icon: AppIcons.shuffle,
          label: _playerState.shuffleEnabled ? '随机播放中' : '随机播放',
          selected: _playerState.shuffleEnabled,
          onPressed: widget.onToggleShuffle,
        ),
      ),
      Tooltip(
        message: repeatActive ? '$repeatLabel，点击切换' : '循环播放，点击开启',
        child: EchoIconButton(
          icon: repeatActive && loopMode == LoopMode.one
              ? AppIcons.repeatOne
              : AppIcons.repeat,
          label: repeatLabel,
          selected: repeatActive,
          onPressed: widget.onToggleRepeat,
        ),
      ),
      const _VolumeButton(),
      Tooltip(
        message: '切换播放器，当前：${widget.currentPlayerName}',
        child: EchoIconButton(
          icon: widget.isCasting ? AppIcons.signalTower : AppIcons.headphones,
          label: '切换播放器，当前：${widget.currentPlayerName}',
          foregroundColor: widget.isCasting
              ? context.echoColors.accent
              : context.echoColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: widget.onSwitchPlayer,
        ),
      ),
    ];
  }

  /// 手机端简略版：播放暂停 + 投屏控制
  List<Widget> _buildMobileControls(BuildContext context) {
    return <Widget>[
      EchoIconButton(
        icon: _playerState.isPlaying ? AppIcons.pause : AppIcons.play,
        label: _playerState.isPlaying ? '暂停' : '播放',
        foregroundColor: context.echoColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: _togglePlayPause,
      ),
      EchoIconButton(
        icon: widget.isCasting ? AppIcons.signalTower : AppIcons.headphones,
        label: '切换播放器，当前：${widget.currentPlayerName}',
        foregroundColor: widget.isCasting
            ? context.echoColors.accent
            : context.echoColors.ink,
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
        EchoMediaVisuals.fallback(
          seed: widget.albumColor ?? EchoColors.contentTintFallback,
        );

    return EchoMediaColorScope(
      visuals: visuals,
      role: EchoMediaSurfaceRole.mini,
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
                        child: EchoPlayerBackdrop(
                          visuals: visuals,
                          mode: EchoPlayerBackdropMode.mini,
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        context.echoSpacing.sm,
                        context.echoSpacing.xs,
                        context.echoSpacing.xs,
                        context.echoSpacing.xs,
                      ),
                      child: Row(
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
                            ..._buildDesktopControls(context)
                          else
                            ..._buildMobileControls(context),
                        ],
                      ),
                    ),
                    Positioned.fill(
                      child: ClipRRect(
                        key: const Key('mini-player-surface-clip'),
                        borderRadius: context.echoRadii.surface,
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
              child: EchoProgressBar(
                key: const Key('mini-player-progress'),
                value: displayedProgress,
                height: 3,
                color: context.echoColors.accent,
                trackColor: Colors.transparent,
              ),
            ),
          ),
        ),
        if (_scrubbing)
          PositionedDirectional(
            start: context.echoSpacing.sm,
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
    final lyric = lyricLine?.trim().isNotEmpty == true ? lyricLine!.trim() : null;
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
        SizedBox(width: context.echoSpacing.sm),
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
              if (lyric != null)
                _MiniPlayerLyric(text: lyric),
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
            color: context.echoColors.surface,
            shape: BoxShape.circle,
          ),
          child: Icon(
            AppIcons.music,
            size: 24,
            color: context.echoColors.muted,
          ),
        ),
        SizedBox(width: context.echoSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                '未在播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.echoTypography.title,
              ),
              if (showSubtitle)
                Text(
                  '选择一首歌曲开始播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.echoTypography.metadata.copyWith(
                    color: context.echoColors.muted,
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
          style: context.echoTypography.title,
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
            TextSpan(text: title, style: context.echoTypography.title),
            TextSpan(
              text: ' - $artist',
              style: context.echoTypography.metadata.copyWith(
                color: context.echoColors.muted,
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
        padding: EdgeInsets.only(top: context.echoSpacing.xxs),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 歌词用 body(13) 而非 metadata(11)：现状偏小，适当放大。
          style: context.echoTypography.body.copyWith(
            color: _lyricYellow,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 桌面端音量控制按钮：点击弹出滑块调节音量。
/// 对齐主项目前端 setVolume：
/// - 投屏(选中远端 peer) → POST /peers/:id/volume {volume:0-100}；
/// - 本机 → just_audio setVolume(0-1)，并持久化供下次启动恢复。
class _VolumeButton extends ConsumerStatefulWidget {
  const _VolumeButton();

  @override
  ConsumerState<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends ConsumerState<_VolumeButton> {
  OverlayEntry? _overlayEntry;

  /// 拖动中的临时音量（0.0~1.0）。拖动期间优先显示它，松手后置空。
  double? _dragValue;

  /// 投屏端节流发送时间戳：拖动时 ≤10 次/秒，避免刷爆网络。
  DateTime? _lastCastVolumeSend;

  /// 当前控制目标音量（0.0~1.0）：投屏取 peer status.volume(0-100)，
  /// 本机取 playerState.volume。peer 未回报音量时回退本机音量。
  double _effectiveVolume() {
    final cast = ref.watch(castPeerControllerProvider);
    if (cast.activePeer != null && cast.status.volume != null) {
      return (cast.status.volume! / 100).clamp(0.0, 1.0).toDouble();
    }
    return ref.watch(playerProvider.select((s) => s.volume));
  }

  /// 拖动中：按「切换播放器」所选目标**只写一路**——
  /// 本机 → setVolumeLive（just_audio 实时跟手，零 IO）；
  /// 投屏 → 节流 POST 到所选播放器（≤10 次/秒，不刷爆网络）。
  void _onSliderChanged(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    setState(() => _dragValue = clamped);
    final cast = ref.read(castPeerControllerProvider);
    if (cast.activePeer == null) {
      ref.read(playerProvider.notifier).setVolumeLive(clamped);
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
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 80,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: EchoSurface(
            level: EchoSurfaceLevel.floating,
            padding: EdgeInsets.all(context.echoSpacing.sm),
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
                    sourceVolume =
                        ref.watch(playerProvider.select((s) => s.volume));
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
                          fontWeight: FontWeight.w600,
                          color: context.echoColors.ink,
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final volume = _dragValue ?? _effectiveVolume();
    final percent = (volume * 100).round();
    return EchoIconButton(
      icon: AppIcons.speaker,
      label: '音量 $percent%',
      foregroundColor: context.echoColors.ink,
      backgroundColor: Colors.transparent,
      onPressed: _toggleOverlay,
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
      child: EchoSurface(
        level: EchoSurfaceLevel.floating,
        color: context.echoColors.ink,
        borderRadius: context.echoRadii.detail,
        padding: EdgeInsets.symmetric(
          horizontal: context.echoSpacing.xs,
          vertical: context.echoSpacing.xxs,
        ),
        child: Text(
          _formatPlayerDuration(position),
          style: context.echoTypography.metadata.copyWith(
            color: context.echoColors.canvas,
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
  ConsumerState<PlayerSwitcherSheet> createState() => _PlayerSwitcherSheetState();
}

class _PlayerSwitcherSheetState extends ConsumerState<PlayerSwitcherSheet> {
  List<PeerInfo>? _peers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final controller = ref.read(castPeerControllerProvider.notifier);
    // 先触发 DLNA 扫描（对齐主项目前端 scanDlnaDevices）
    try {
      final client = ref.read(subsonicApiClientProvider);
      await client.post('/rest/api/v1/dlna/scan');
    } catch (_) {
      // 扫描失败不阻塞，直接加载列表
    }
    final peers = await controller.loadPeers();
    if (mounted) setState(() => _peers = peers);
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(castPeerControllerProvider);
    final controller = ref.read(castPeerControllerProvider.notifier);
    final peers = _peers;
    final remotePeers = (peers ?? const <PeerInfo>[])
        .where((p) => !p.isLocal)
        .toList();

    return EchoBottomSheet(
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
              EchoActionRow(
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
                EchoActionRow(
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
                  EchoActionRow(
                    icon: switch (peer.kind) {
                      'group' => AppIcons.people,
                      'airplay' => AppIcons.signalTower,
                      _ => AppIcons.signalTower,
                    },
                    title: peer.name,
                    subtitle: <String>[
                      peer.kindLabel,
                      if (!peer.available) '离线',
                      if (peer.queueTotal > 0)
                        peer.queueLabel,
                    ].join(' · '),
                    selected: cast.activePeer?.peerId == peer.peerId,
                    onPressed: () async {
                            final navigator = Navigator.of(context);
                            final ok = await controller.switchTo(peer);
                            if (!ok && context.mounted) {
                              showEchoMessage(
                                context,
                                '切换到「${peer.name}」失败,请检查设备是否在线',
                                kind: EchoMessageKind.error,
                              );
                              return;
                            }
                            navigator.pop();
                          },
                  )
              else
                Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: context.echoSpacing.sm,
                  ),
                  child: Text(
                    _peers == null
                        ? '正在获取可用播放器…'
                        : '未发现其他播放器,可点击下方按钮重新扫描。',
                    style: context.echoTypography.body.copyWith(
                      color: context.echoColors.muted,
                    ),
                  ),
                ),
              EchoActionRow(
                icon: AppIcons.refresh,
                title: '重新扫描播放器',
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
