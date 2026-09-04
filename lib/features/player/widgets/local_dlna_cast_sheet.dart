import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/dlna/cast_http.dart';
import '../../../core/dlna/dlna_models.dart';
import '../../../providers/dlna_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../widgets/windows_title_bar.dart' show isWindowsDesktop;
import '../../../l10n/generated/app_localizations.dart';

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
    final loc = AppLocalizations.of(context);
    // 兜底防线：面板渲染时已拦截「无可用 http 地址」，这里再挡一次，
    // 防止打开面板后地址被改动（编辑媒体库/线路切换）导致越界投流。
    if (ref.read(dlnaCastHttpBaseProvider) == null) {
      showMusicFlowMessage(
        context,
        kDlnaCastHttpRequiredHint(loc),
        kind: MusicFlowMessageKind.warning,
      );
      return;
    }
    final playerState = ref.read(playerProvider);
    final tracks = playerState.queue
        .map(dlnaCastTrackFromSong)
        .toList(growable: false);
    if (tracks.isEmpty) {
      showMusicFlowMessage(context, loc.dlna_no_queue_to_cast, kind: MusicFlowMessageKind.warning);
      return;
    }
    final safeStart = playerState.currentIndex.clamp(0, tracks.length - 1);
    final ok = await ref.read(dlnaCastProvider.notifier).startCast(
          device,
          tracks,
          startIndex: safeStart,
        );
    if (!mounted) return;
    if (ok) {
      showMusicFlowMessage(
        context,
        loc.dlna_cast_success(device.name),
        kind: MusicFlowMessageKind.success,
      );
    } else {
      showMusicFlowMessage(
        context,
        loc.dlna_cast_failed(device.name),
        kind: MusicFlowMessageKind.error,
      );
    }
  }

  Future<void> _stopCast() async {
    final loc = AppLocalizations.of(context);
    await ref.read(dlnaCastProvider.notifier).stopCast();
    if (!mounted) return;
    showMusicFlowMessage(context, loc.dlna_cast_stopped, kind: MusicFlowMessageKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cast = ref.watch(dlnaCastProvider);
    final devicesState = ref.watch(dlnaDevicesProvider);

    // Windows 桌面端由外层 MusicFlowDesktopDialog 提供标题栏/圆角/滚动，
    // 此处只渲染面板内容；其余平台保持安卓底部抽屉自带头部。
    if (isWindowsDesktop) {
      return _buildContent(context, cast, devicesState);
    }

    return MusicFlowBottomSheet(
      title: loc.player_dlna_local,
      subtitle: loc.player_dlna_dialog_subtitle,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: _buildContent(context, cast, devicesState),
        ),
      ),
    );
  }

  /// 面板主体：投屏态/设备列表 + 后台续播提示（与容器解耦，供
  /// 安卓底部抽屉与 Windows 桌面对话框共用）。
  Widget _buildContent(
    BuildContext context,
    DlnaCastState cast,
    DlnaDevicesState devicesState,
  ) {
    // 打开面板即检测：媒体库没有可用 http 地址（DLNA 设备基本不支持 https）
    // 时不出设备列表、禁止发起投流，只展示提示（ray 需求）。
    // 已在投屏则保持投屏面板（停止投屏仍可用，不必打断既有会话）。
    final castHttpBase = ref.watch(dlnaCastHttpBaseProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (cast.isCasting) ...<Widget>[
          _buildCastingPanel(cast),
        ] else if (castHttpBase == null) ...<Widget>[
          _buildHttpRequiredHint(),
        ] else ...<Widget>[
          _buildDeviceList(cast, devicesState),
        ],
        _buildBackgroundHint(),
      ],
    );
  }

  /// 无可用 http 地址时的提示（替代设备列表，禁止发起投流）。
  Widget _buildHttpRequiredHint() {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final typography = context.musicFlowTypography;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(AppIcons.warning, size: 16, color: colors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              kDlnaCastHttpRequiredHint(loc),
              style: typography.body.copyWith(color: colors.ink),
            ),
          ),
        ],
      ),
    );
  }

  /// 投屏中：当前曲目 + 播放控制 + 停止投屏
  Widget _buildCastingPanel(DlnaCastState cast) {
    final loc = AppLocalizations.of(context);
    final track = cast.currentTrack;
    final isPlaying = cast.status.state == 'PLAYING';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MusicFlowActionRow(
          icon: AppIcons.dlnaLocalFilled,
          title: loc.player_casting_to(cast.currentDevice?.name ?? ''),
          subtitle: track == null
              ? loc.dlna_queue_ended
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
              label: loc.player_previous,
              enabled: cast.currentIndex > 0,
              onPressed: () => ref.read(dlnaCastProvider.notifier).previous(),
            ),
            const SizedBox(width: 8),
            _castControlIcon(
              icon: isPlaying ? AppIcons.pause : AppIcons.play,
              label: isPlaying ? loc.player_pause : loc.widgets_play,
              onPressed: () => isPlaying
                  ? ref.read(dlnaCastProvider.notifier).pause()
                  : ref.read(dlnaCastProvider.notifier).resume(),
            ),
            const SizedBox(width: 8),
            _castControlIcon(
              icon: AppIcons.next,
              label: loc.player_next,
              enabled: cast.currentIndex < cast.queue.length - 1,
              onPressed: () => ref.read(dlnaCastProvider.notifier).next(),
            ),
          ],
        ),
        MusicFlowActionRow(
          icon: AppIcons.close,
          title: loc.dlna_stop,
          subtitle: loc.dlna_stop_subtitle,
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
    final colors = context.musicFlowColors;
    // 紧凑圆形控制键：MusicFlowActionRow 是满宽行，不能横向并排（否则无限宽）。
    return MusicFlowPressable(
      minimumSize: const Size.square(48),
      borderRadius: BorderRadius.circular(24),
      semanticLabel: label,
      onPressed: enabled ? onPressed : null,
      child: SizedBox.square(
        dimension: 48,
        child: Center(
          child: Icon(
            icon,
            size: 22,
            color: enabled ? colors.ink : colors.muted,
          ),
        ),
      ),
    );
  }

  /// 设备自发现列表
  Widget _buildDeviceList(DlnaCastState cast, DlnaDevicesState devicesState) {
    final loc = AppLocalizations.of(context);
    final online = devicesState.devices
        .where((d) => d.available && !d.disabled)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MusicFlowActionRow(
          icon: AppIcons.refresh,
          title: loc.dlna_scan_devices,
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
              subtitle: loc.dlna_device_subtitle,
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
                  ? loc.dlna_searching
                  : loc.dlna_no_device,
              style: context.musicFlowTypography.body.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ),
      ],
    );
  }

  /// 后台续播提示：引导用户放开系统冻结，保证曲末能自动切下一首。
  /// 主要面向安卓（含鸿蒙4）：国产 ROM / 鸿蒙默认会深度冻结后台音频进程，
  /// 仅靠前台服务+闹钟可能仍被压制，最有效的做法是在系统层把本应用放开。
  Widget _buildBackgroundHint() {
    final loc = AppLocalizations.of(context);
    final colors = context.musicFlowColors;
    final typography = context.musicFlowTypography;
    return Padding(
      padding: EdgeInsets.only(
        top: context.musicFlowSpacing.md,
        bottom: context.musicFlowSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(AppIcons.info, size: 16, color: colors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              loc.dlna_background_hint,
              style: typography.body.copyWith(color: colors.muted),
            ),
          ),
        ],
      ),
    );
  }
}