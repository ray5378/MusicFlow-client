import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../data/api_client.dart';
import '../player/player_service.dart';
import '../widgets/cover.dart';

/// 全屏播放器：黑胶 + 歌词占位 + 控制区（随机/循环/上一首/播放/下一首/队列）。
class FullPlayerPage extends StatefulWidget {
  const FullPlayerPage({super.key, required this.api, required this.player});

  final ApiClient api;
  final PlayerService player;

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _vinyl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  );

  @override
  void dispose() {
    _vinyl.dispose();
    super.dispose();
  }

  void _syncVinyl(bool playing) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (playing && !reduce) {
      if (!_vinyl.isAnimating) _vinyl.repeat();
    } else {
      _vinyl.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('正在播放')),
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.player, widget.player.dlna.status]),
        builder: (context, _) {
          final player = widget.player;
          final song = player.current;
          if (song == null) return const SizedBox.shrink();
          _syncVinyl(player.playing);
          final cs = Theme.of(context).colorScheme;
          final tt = Theme.of(context).textTheme;
          final totalMs = player.duration.inMilliseconds;

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: _vinyl,
                            builder: (context, child) => Transform.rotate(
                              angle: _vinyl.value * 2 * math.pi,
                              child: child,
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  width: 260,
                                  height: 260,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black87,
                                    boxShadow: [BoxShadow(color: cs.shadow.withValues(alpha: 0.3), blurRadius: 24)],
                                  ),
                                  padding: const EdgeInsets.all(34),
                                  child: ClipOval(
                                    child: coverOf(widget.api, song.coverArt, size: 192, radius: 96),
                                  ),
                                ),
                                Container(
                                  width: 22,
                                  height: 22,
                                  decoration:
                                      BoxDecoration(shape: BoxShape.circle, color: cs.surfaceContainerHighest),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(song.title, style: tt.headlineSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Text(
                            '${song.artist ?? ''}${player.targetName != '本机' ? ' · ${player.targetName}' : ''}',
                            style: tt.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    SliderTheme(
                      data: const SliderThemeData(trackHeight: 3, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6)),
                      child: Slider(
                        value: totalMs > 0
                            ? player.position.inMilliseconds.clamp(0, totalMs).toDouble()
                            : 0,
                        max: totalMs > 0 ? totalMs.toDouble() : 1,
                        onChanged: totalMs > 0
                            ? (v) => PlayerBarSafe.run(
                                () => player.seekTo(Duration(milliseconds: v.round())))
                            : null,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(Fmt.duration(player.position.inSeconds), style: tt.labelSmall),
                        Text(Fmt.duration(totalMs > 0 ? player.duration.inSeconds : 0), style: tt.labelSmall),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(Icons.shuffle, color: player.shuffle ? cs.primary : null),
                          tooltip: '随机播放',
                          onPressed: () => player.setShuffle(!player.shuffle),
                        ),
                        IconButton(icon: const Icon(Icons.skip_previous_rounded), onPressed: player.previous),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(minimumSize: const Size(72, 56)),
                          icon: Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32),
                          label: Text(player.playing ? '暂停' : '播放'),
                          onPressed: () async {
                            try {
                              await player.toggle();
                            } catch (_) {}
                          },
                        ),
                        const SizedBox(width: 12),
                        IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: player.next),
                        IconButton(
                          icon: Icon(Icons.repeat_one, color: player.repeatOne ? cs.primary : null),
                          tooltip: '单曲循环',
                          onPressed: () => player.setRepeatOne(!player.repeatOne),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('当前播放器：${player.targetName}', style: tt.labelSmall),
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

/// 简单的静默执行器，避免页面层到处 try-catch 噪音。
abstract final class PlayerBarSafe {
  static Future<void> run(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {}
  }
}
