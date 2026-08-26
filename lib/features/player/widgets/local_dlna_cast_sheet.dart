import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/dlna/dlna_models.dart';
import '../../../providers/dlna_provider.dart';
import '../../../providers/player_provider.dart';

/// 链路 B：局域网 DLNA 直投面板（独立副轨道）
/// 与「选择播放器」（链路 A，cast_peer_provider）完全独立：客户端自行 SSDP 发现
/// 设备并本地推流，投屏队列来自本机当前播放队列（拷贝脱钩）。
/// 独立样式（标题/图标/文案）避免与链路 A 混淆。
class LocalDlnaCastSheet extends ConsumerStatefulWidget {
  const LocalDlnaCastSheet({super.key});

  @override
  ConsumerState<LocalDlnaCastSheet> createState() =>
      _LocalDlnaCastSheetState();
}

class _LocalDlnaCastSheetState extends ConsumerState<LocalDlnaCastSheet> {
  bool _autoScanned = false;

  @override
  void initState() {
    super.initState();
    // 打开面板即触发一次自发现
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    final devices = ref.read(dlnaDevicesProvider.notifier);
    await devices.scan();
  }

  Future<void> _startCast(DlnaDevice device) async {
    final playerState = ref.read(playerProvider);
    final tracks = playerState.queue
        .map(dlnaCastTrackFromSong)
        .toList(growable: false);
    if (tracks.isEmpty) {
      showMusicFlowMessage(context, '当前没有可投屏的播放队列', kind: MusicFlowMessageKind.warning);
      return;
    }
    final safeStart = playerState.currentIndex.clamp(0, tracks.length - 1);
    final ok = await ref.read(dlnaCastProvider.notifier).startCast(
          device,
          tracks,
          startIndex: safeStart,
        );
    if (ok) {
      showMusicFlowMessage(
        context,
        '已投屏到「${device.name}」',
        kind: MusicFlowMessageKind.success,
      );
    } else {
      showMusicFlowMessage(
        context,
        '投屏到「${device.name}」失败，请检查设备是否在线',
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  Future<void> _stopCast() async {
    await ref.read(dlnaCastProvider.notifier).stopCast();
    showMusicFlowMessage(context, '已停止局域网投屏', kind: MusicFlowMessageKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(dlnaCastProvider);
    final devicesState = ref.watch(dlnaDevicesProvider);

    return MusicFlowBottomSheet(
      title: '局域网 DLNA 直投',
      subtitle: '客户端自扫局域网设备并本地推流，与「切换播放器」（服务端投屏）相互独立。',
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (cast.isCasting) ...<Widget>[
                _buildCastingPanel(cast),
              ] else ...<Widget>[
                _buildDeviceList(cast, devicesState),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 投屏中：当前曲目 + 播放控制 + 停止投屏
  Widget _buildCastingPanel(DlnaCastState cast) {
    final track = cast.currentTrack;
    final isPlaying = cast.status.state == 'PLAYING';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MusicFlowActionRow(
          icon: AppIcons.dlnaLocalFilled,
          title: '正在投屏到「${cast.currentDevice?.name ?? ''}」',
          subtitle: track == null
              ? '队列已结束'
              : '${track.title}${track.artist == null ? '' : ' · ${track.artist}'}',
          selected: true,
          onPressed: () {},
        ),
        // 播放控制
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _castControlIcon(
              icon: AppIcons.previous,
              label: '上一首',
              enabled: cast.currentIndex > 0,
              onPressed: () => ref.read(dlnaCastProvider.notifier).previous(),
            ),
            _castControlIcon(
              icon: isPlaying ? AppIcons.pause : AppIcons.play,
              label: isPlaying ? '暂停' : '播放',
              onPressed: () => isPlaying
                  ? ref.read(dlnaCastProvider.notifier).pause()
                  : ref.read(dlnaCastProvider.notifier).resume(),
            ),
            _castControlIcon(
              icon: AppIcons.next,
              label: '下一首',
              enabled: cast.currentIndex < cast.queue.length - 1,
              onPressed: () => ref.read(dlnaCastProvider.notifier).next(),
            ),
          ],
        ),
        MusicFlowActionRow(
          icon: AppIcons.close,
          title: '停止局域网投屏',
          subtitle: '停止设备播放并释放本地投屏队列',
          onPressed: () async {
            await _stopCast();
          },
        ),
      ],
    );
  }

  Widget _castControlIcon({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool enabled = true,
  }) {
    return MusicFlowActionRow(
      icon: icon,
      title: label,
      onPressed: enabled ? onPressed : null,
    );
  }

  /// 设备自发现列表
  Widget _buildDeviceList(DlnaCastState cast, DlnaDevicesState devicesState) {
    final online = devicesState.devices
        .where((d) => d.available && !d.disabled)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MusicFlowActionRow(
          icon: AppIcons.refresh,
          title: '扫描局域网 DLNA 设备',
          trailing: devicesState.isScanning
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onPressed: devicesState.isScanning ? null : _scan,
        ),
        if (online.isNotEmpty)
          for (final device in online)
            MusicFlowActionRow(
              icon: AppIcons.dlnaLocal,
              title: device.name,
              subtitle: '本机局域网发现 · 直投',
              selected: cast.currentDevice?.id == device.id,
              onPressed: () async {
                await _startCast(device);
              },
            )
        else
          Padding(
            padding: EdgeInsets.symmetric(
              vertical: context.musicFlowSpacing.sm,
            ),
            child: Text(
              devicesState.isScanning
                  ? '正在搜索局域网内的 DLNA 设备…'
                  : '未发现可用 DLNA 设备。请确认与音箱/电视处于同一网络后再扫描。',
              style: context.musicFlowTypography.body.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ),
      ],
    );
  }
}