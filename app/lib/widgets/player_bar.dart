import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../player/player_service.dart';
import 'cover.dart';

/// 底部播放条：
/// - 窄屏（<840）：迷你条 = 封面 + 标题/歌手两行 + 上一首/播放/下一首 + 切换播放器
/// - 宽屏（≥840）：封面信息 | 随机/上一首/**播放**/下一首/循环 | 进度 | 收藏/音量/队列/切换播放器
/// 「切换播放器」为本项目特色功能：本机 ↔ DLNA 设备，带三重反馈。
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.api, required this.player});

  final ApiClient api;
  final PlayerService player;

  static const height = 72.0;

  void _openSwitcher(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _PlayerSwitcherSheet(api: api, player: player),
    ).then((_) {
      if (context.mounted) {
        final casting = player.isCasting;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(casting ? '正在投屏到「${player.targetName}」' : '已切换为本机播放'),
        ));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final song = player.current;
        if (song == null) return const SizedBox.shrink();
        final wide = MediaQuery.sizeOf(context).width >= 840;
        final cs = Theme.of(context).colorScheme;
        final tt = Theme.of(context).textTheme;

        Widget info = Row(
          children: [
            Cover(url: api.coverUrl(song.coverArt, size: 120), size: 48, radius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(song.title, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    song.artist ?? song.album ?? '',
                    style: tt.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        );

        if (!wide) {
          return Material(
            color: cs.surface,
            elevation: 8,
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: height,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(child: GestureDetector(onTap: () => _openFull(context), child: info)),
                    _iconBtn(player.previous, Icons.skip_previous_rounded),
                    _playBtn(cs),
                    _iconBtn(player.next, Icons.skip_next_rounded),
                    IconButton(
                      tooltip: '当前：${player.targetName}，点击切换播放器',
                      icon: Icon(
                        Icons.speaker_group_outlined,
                        color: player.isCasting ? cs.primary : cs.onSurfaceVariant,
                      ),
                      onPressed: () => _openSwitcher(context),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          );
        }

        // ---- 桌面宽条 ----
        return Material(
          color: cs.surface,
          elevation: 8,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    SizedBox(width: 240, child: GestureDetector(onTap: () => _openFull(context), child: info)),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: player.shuffle ? '随机：开' : '随机：关',
                                icon: Icon(Icons.shuffle, size: 20, color: player.shuffle ? cs.primary : cs.onSurfaceVariant),
                                onPressed: () => player.setShuffle(!player.shuffle),
                              ),
                              _iconBtn(player.previous, Icons.skip_previous_rounded),
                              _playBtn(cs, size: 52),
                              _iconBtn(player.next, Icons.skip_next_rounded),
                              IconButton(
                                tooltip: player.repeatOne ? '单曲循环' : '顺序播放',
                                icon: Icon(player.repeatOne ? Icons.repeat_one_on : Icons.repeat, size: 20, color: player.repeatOne ? cs.primary : cs.onSurfaceVariant),
                                onPressed: () => player.setRepeatOne(!player.repeatOne),
                              ),
                            ],
                          ),
                          const _MiniProgress(),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            icon: Icon(song.starred ? Icons.favorite : Icons.favorite_border, size: 20),
                            onPressed: () async {
                              await api.setStar(songId: song.id, star: !song.starred);
                            },
                          ),
                          IconButton(
                            icon: Icon(Icons.speaker_group_outlined, size: 20, color: player.isCasting ? cs.primary : null),
                            tooltip: '当前：${player.targetName}，点击切换播放器',
                            onPressed: () => _openSwitcher(context),
                          ),
                          const _DesktopVolume(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _openFull(BuildContext context) {
    Navigator.of(context).pushNamed('/player');
  }

  Widget _iconBtn(Future<void> Function() fn, IconData icon) =>
      IconButton(icon: Icon(icon), onPressed: () => unawaitedFn(fn));

  static Future<void> unawaitedFn(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {}
  }

  Widget _playBtn(ColorScheme cs, {double size = 44}) => IconButton.filled(
        style: IconButton.styleFrom(backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
        iconSize: size * 0.55,
        icon: Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        onPressed: () => unawaitedFn(player.toggle),
      );
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context) {
    final player = context.findAncestorWidgetOfExactType<PlayerBar>()!.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final total = player.duration.inMilliseconds.toDouble();
        return SizedBox(
          height: 24,
          width: 320,
          child: SliderTheme(
            data: const SliderThemeData(trackHeight: 3, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5)),
            child: Slider(
              value: total > 0 ? player.position.inMilliseconds.clamp(0, total).toDouble() : 0,
              max: total > 0 ? total : 1,
              onChanged: total > 0
                  ? (v) => PlayerBar.unawaitedFn(() => player.seekTo(Duration(milliseconds: v.round())))
                  : null,
            ),
          ),
        );
      },
    );
  }
}

class _DesktopVolume extends StatefulWidget {
  const _DesktopVolume();
  @override
  State<_DesktopVolume> createState() => _DesktopVolumeState();
}

class _DesktopVolumeState extends State<_DesktopVolume> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final player = context.findAncestorWidgetOfExactType<PlayerBar>()!.player;
    return ListenableBuilder(
      listenable: Listenable.merge([player, player.dlna.status]),
      builder: (context, _) {
        final casting = player.isCasting;
        final vol = casting ? (player.dlna.status.value.volume ?? 100) : 100;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(casting ? Icons.volume_up : Icons.volume_up_outlined, size: 20),
              tooltip: casting ? '设备音量 $vol%' : '音量（投屏后可调设备音量）',
              onPressed: () => setState(() => _open = !_open),
            ),
            if (_open && casting)
              SizedBox(
                width: 110,
                child: Slider(
                  value: vol.toDouble(),
                  max: 100,
                  label: '$vol%',
                  divisions: 20,
                  onChanged: (v) => PlayerBar.unawaitedFn(() => player.dlna.setVolume(v.round())),
                ),
              )
            else if (_open)
              const SizedBox(
                width: 110,
                child: Text('投屏后可调', style: TextStyle(fontSize: 11)),
              ),
          ],
        );
      },
    );
  }
}

/// 切换播放器面板：本机 + DLNA 设备列表，✓ 标记当前目标，支持重新扫描。
class _PlayerSwitcherSheet extends StatefulWidget {
  const _PlayerSwitcherSheet({required this.api, required this.player});

  final ApiClient api;
  final PlayerService player;

  @override
  State<_PlayerSwitcherSheet> createState() => _PlayerSwitcherSheetState();
}

class _PlayerSwitcherSheetState extends State<_PlayerSwitcherSheet> {
  bool scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    setState(() => scanning = true);
    await widget.player.dlna.scan();
    if (mounted) setState(() => scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([player, player.dlna.devices]),
        builder: (context, _) {
          final devices = player.dlna.devices.value;
          return Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(child: Text('选择播放器', style: Theme.of(context).textTheme.headlineSmall)),
                      IconButton(
                        onPressed: scanning ? null : _scan,
                        icon: scanning
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.smartphone),
                  title: const Text('本机'),
                  subtitle: const Text('使用此设备扬声器'),
                  trailing: !player.isCasting ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary) : null,
                  onTap: () async {
                    await player.useLocalDevice();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                for (final d in devices)
                  ListTile(
                    leading: const Icon(Icons.speaker),
                    title: Text(d.name),
                    subtitle: const Text('DLNA'),
                    trailing: player.isCasting && player.targetDevice?.id == d.id
                        ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: player.current == null
                        ? null
                        : () async {
                            final ok = await player.castTo(d);
                            if (!ok && context.mounted) {
                              Navigator.of(context).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('投屏「${d.name}」失败，请重试')),
                              );
                              return;
                            }
                            if (context.mounted) Navigator.of(context).pop();
                          },
                  ),
                if (!scanning && devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('未发现其他播放器，点击右上角重新扫描。', textAlign: TextAlign.center),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text('切换播放器仅改变控制目标，不会停止其他播放器。',
                      style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
