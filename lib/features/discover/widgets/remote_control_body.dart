import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_slider.dart';
import 'package:musicflow_client/core/design/music_flow_context.dart';
import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/features/player/widgets/synced_lyrics_view.dart'
    show lyricLineParts, syncedLyricIndexFor;
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/home_remote_control_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

/// L0 三行主体:① 切换器 / ② Now 区 / ③ 控制条 + 进度条。
///
/// **所有操控都走 `effective_*` 门面**(effective_playback_provider /
/// effective_volume),禁止直调 playerProvider —— 直调在「用户正在控制远端
/// 音箱」时全部失效,且本机测试测不出来(见架构 §1.1)。
class RemoteControlBody extends ConsumerWidget {
  const RemoteControlBody({super.key, required this.metrics});

  final RemoteControlMetrics metrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: metrics.switcherHeight,
          child: RemoteControlPeerBar(metrics: metrics),
        ),
        SizedBox(height: metrics.gap),
        SizedBox(
          height: metrics.nowHeight,
          child: RemoteControlNowArea(metrics: metrics),
        ),
        SizedBox(height: metrics.gap),
        SizedBox(
          height: metrics.controlsHeight,
          child: RemoteControlControls(metrics: metrics),
        ),
        SizedBox(
          height: metrics.progressHeight,
          child: RemoteControlProgressRow(metrics: metrics),
        ),
      ],
    );
  }
}

/// ① 切换器:横排 chip,**横向滚动、绝不换行**(换行会撑高整块,破坏固定高度)。
///
/// 选中态口径(D1 唯一来源):`activePeer == null` = 本机选中;否则
/// `activePeer!.peerId == p.peerId`。本机由 `p.self` 识别。
/// 切换只走 `castPeer.switchTo` / `backToLocal`(C14/C15),不碰其它路径。
class RemoteControlPeerBar extends ConsumerWidget {
  const RemoteControlPeerBar({super.key, required this.metrics});

  final RemoteControlMetrics metrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final targets = ref.watch(remoteControlTargetsProvider);
    final activePeer = ref.watch(
      castPeerControllerProvider.select((s) => s.activePeer),
    );

    final chips = <Widget>[];
    for (final peer in targets) {
      final isSelf = peer.self;
      final selected = isSelf
          ? activePeer == null
          : activePeer?.peerId == peer.peerId;
      chips.add(_PeerChip(
        peer: peer,
        selected: selected,
        label: isSelf ? loc.peer_self : peer.name,
        onTap: () => _switchTarget(ref, peer),
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // physics: 防止横向滚动把首页的纵向滚动带跑(嵌套滚动不外泄)。
      physics: const ClampingScrollPhysics(),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < chips.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );
  }

  Future<void> _switchTarget(WidgetRef ref, PeerInfo peer) async {
    if (peer.self) {
      await ref.read(castPeerControllerProvider.notifier).backToLocal();
      return;
    }
    await ref.read(castPeerControllerProvider.notifier).switchTo(peer);
  }
}

class _PeerChip extends StatelessWidget {
  const _PeerChip({
    required this.peer,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final PeerInfo peer;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            // 选中态:accent 10% 薄染 + accent 图标(对齐 PeerCastRow 口径)。
            color: selected ? colors.accent.withValues(alpha: 0.10) : null,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? colors.accent : scheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                AppIcons.speaker,
                size: 16,
                color: selected ? colors.accent : colors.muted,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1,
                  color: selected ? colors.ink : colors.muted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ② Now 区:封面 + 曲名/艺术家 + 紧凑歌词视口。
///
/// 曲目信息读 `playerProvider.currentSong`(D4:投屏态下
/// `cast_peer_provider.syncQueueForCast()` 已把后端权威队列镜像进
/// playerProvider,本机与远端共用这一个来源)。
class RemoteControlNowArea extends ConsumerWidget {
  const RemoteControlNowArea({super.key, required this.metrics});

  final RemoteControlMetrics metrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    final colors = context.musicFlowColors;

    final titleRow = SizedBox(
      height: metrics.titleRowHeight,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              song?.title ?? loc.home_remote_not_playing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: metrics.titleRowHeight * 0.62,
                height: 1,
                fontWeight: FontWeight.w600,
                color: colors.ink,
              ),
            ),
          ),
          if (song?.artist != null && song!.artist!.isNotEmpty) ...<Widget>[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                song.artist!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: metrics.titleRowHeight * 0.5,
                  height: 1,
                  color: colors.muted,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CoverArtImage(
          coverArtId: song?.artworkReference,
          size: metrics.coverSize,
          // R23:无障碍 —— 封面语义标签跟曲名走。
          semanticLabel: song?.title ?? loc.home_remote_not_playing,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              titleRow,
              SizedBox(height: metrics.titleGap),
              Expanded(
                child: RemoteControlLyricsViewport(metrics: metrics),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 紧凑歌词视口:**不复用** `SyncedLyricsSurface`(自带上下 48dp padding,
/// 在 104dp 区里几乎看不到字),只复用它的两个 public 纯函数
/// `syncedLyricIndexFor` / `lyricLineParts`。滚动对齐 = 当前行固定第 2 槽。
class RemoteControlLyricsViewport extends ConsumerStatefulWidget {
  const RemoteControlLyricsViewport({super.key, required this.metrics});

  final RemoteControlMetrics metrics;

  @override
  ConsumerState<RemoteControlLyricsViewport> createState() =>
      _RemoteControlLyricsViewportState();
}

class _RemoteControlLyricsViewportState
    extends ConsumerState<RemoteControlLyricsViewport> {
  final ScrollController _controller = ScrollController();
  int _lastIndex = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 把「当前行固定第 2 槽」落到滚动偏移上(index==0 时已在首行,无需滚动)。
  void _alignTo(int index, int lineCount) {
    if (index == _lastIndex) return;
    _lastIndex = index;
    if (!_controller.hasClients) return;
    final target = ((index - 1) * widget.metrics.lyricLineHeight)
        .clamp(0.0, _controller.position.maxScrollExtent);
    // jumpTo 而非 animateTo:首页块内不需要动画,且动画会与下一拍插值打架。
    _controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final lyricsAsync = ref.watch(currentLyricsProvider);
    final position = ref.watch(effectivePositionProvider);
    final best = lyricsAsync.valueOrNull?.getBest();

    if (best == null || best.lines.isEmpty) {
      // 无歌词:占满视口,不改变块高(Q4)。
      return Center(
        child: Text(
          loc.home_remote_no_lyrics,
          style: TextStyle(fontSize: 13, color: colors.muted),
        ),
      );
    }

    final index = syncedLyricIndexFor(best, position);
    // 帧后对齐:build 期间动 ScrollController 会报「setState during build」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _alignTo(index, best.lines.length);
    });

    return ListView.builder(
      controller: _controller,
      // 首页块内的内部滚动不外泄带动整页滚动。
      physics: const ClampingScrollPhysics(),
      itemExtent: widget.metrics.lyricLineHeight,
      padding: EdgeInsets.zero,
      itemCount: best.lines.length,
      itemBuilder: (context, i) {
        final parts = lyricLineParts(best.lines[i].value);
        final current = i == index;
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(
            parts.$1,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1,
              color: current ? colors.ink : colors.muted,
              fontWeight: current ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        );
      },
    );
  }
}

/// ③ 控制条:7 键(队列 / 模式 / 上曲 / 播放暂停 / 下曲 / 收藏 / 音量)。
/// 「未在播放」时除 播放 / 切端 / 音量 外置灰不可用。
class RemoteControlControls extends ConsumerWidget {
  const RemoteControlControls({super.key, required this.metrics});

  final RemoteControlMetrics metrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final hasSong = ref.watch(playerProvider.select((s) => s.currentSong != null));
    final isPlaying = ref.watch(effectiveIsPlayingProvider);
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    final panel = ref.watch(remoteControlPanelProvider);
    final mode = _effectiveMode(ref);

    IconData modeIcon = switch (mode) {
      'shuffle' => AppIcons.shuffle,
      'one' => AppIcons.repeatOne,
      'order' => AppIcons.orderPlayback,
      _ => AppIcons.repeat,
    };

    final iconSize = metrics.controlIconSize;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        MusicFlowIconButton(
          icon: AppIcons.queue,
          label: loc.home_remote_queue,
          iconSize: iconSize,
          selected: panel == RemoteControlPanelKind.queue,
          onPressed: () => _togglePanel(ref, RemoteControlPanelKind.queue),
        ),
        MusicFlowIconButton(
          icon: modeIcon,
          label: loc.player_mode_list,
          iconSize: iconSize,
          selected: mode == 'one' || mode == 'shuffle',
          onPressed: hasSong ? () => cycleEffectivePlayMode(ref) : null,
        ),
        MusicFlowIconButton(
          icon: AppIcons.previous,
          label: loc.player_previous,
          iconSize: iconSize,
          onPressed: hasSong ? () => previousEffectivePlayback(ref) : null,
        ),
        MusicFlowIconButton(
          icon: isPlaying ? AppIcons.pause : AppIcons.play,
          label: isPlaying ? loc.player_pause : loc.widgets_play,
          iconSize: iconSize * 1.15,
          onPressed: () => toggleEffectivePlayback(ref),
        ),
        MusicFlowIconButton(
          icon: AppIcons.next,
          label: loc.player_next,
          iconSize: iconSize,
          onPressed: hasSong ? () => nextEffectivePlayback(ref) : null,
        ),
        MusicFlowIconButton(
          icon: song?.starred == true ? AppIcons.heart : AppIcons.heartOutline,
          label: loc.player_favorite,
          iconSize: iconSize,
          selected: song?.starred == true,
          onPressed: song == null
              ? null
              : () => ref.read(playerProvider.notifier).toggleFavorite(),
        ),
        MusicFlowIconButton(
          icon: AppIcons.volumeHigh,
          label: loc.home_remote_volume,
          iconSize: iconSize,
          selected: panel == RemoteControlPanelKind.volume,
          onPressed: () => _togglePanel(ref, RemoteControlPanelKind.volume),
        ),
      ],
    );
  }

  void _togglePanel(WidgetRef ref, RemoteControlPanelKind kind) {
    final notifier = ref.read(remoteControlPanelProvider.notifier);
    notifier.state =
        notifier.state == kind ? RemoteControlPanelKind.none : kind;
  }

  /// 播放模式字符串(D10,与全屏播放页同一口径):
  /// 直投 > 投屏 peer > 本机;本机取 playbackMode.name。
  String _effectiveMode(WidgetRef ref) {
    final dlna = ref.watch(
      dlnaCastProvider.select((s) => (casting: s.isCasting, mode: s.playMode)),
    );
    if (dlna.casting) return dlna.mode;
    final cast = ref.watch(
      castPeerControllerProvider.select(
        (s) => (active: s.activePeer != null, mode: s.playMode),
      ),
    );
    if (cast.active) return cast.mode;
    return ref.watch(
      playerProvider.select((s) => s.playbackMode.name),
    );
  }
}

/// 进度行:时间 + 可拖进度 + 总时长。拖动用本地值,松手才 seek(C4)。
class RemoteControlProgressRow extends ConsumerStatefulWidget {
  const RemoteControlProgressRow({super.key, required this.metrics});

  final RemoteControlMetrics metrics;

  @override
  ConsumerState<RemoteControlProgressRow> createState() =>
      _RemoteControlProgressRowState();
}

class _RemoteControlProgressRowState
    extends ConsumerState<RemoteControlProgressRow> {
  double? _dragValueMs;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final position = ref.watch(effectivePositionProvider);
    final duration = ref.watch(effectiveDurationProvider);
    final maxMs = duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
    final valueMs = _dragValueMs ?? position.inMilliseconds.clamp(0, maxMs).toDouble();

    return Row(
      children: <Widget>[
        SizedBox(
          width: 38,
          child: Text(
            _fmt(_dragValueMs != null
                ? Duration(milliseconds: _dragValueMs!.round())
                : position),
            style: TextStyle(fontSize: 11, color: colors.muted),
          ),
        ),
        Expanded(
          child: MusicFlowSlider(
            value: valueMs,
            min: 0,
            max: maxMs,
            semanticLabel: loc.home_remote_seek,
            onChanged: (v) => setState(() => _dragValueMs = v),
            onChangeEnd: (v) {
              setState(() => _dragValueMs = null);
              seekEffectivePlayback(ref, Duration(milliseconds: v.round()));
            },
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            _fmt(duration),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11, color: colors.muted),
          ),
        ),
      ],
    );
  }
}
