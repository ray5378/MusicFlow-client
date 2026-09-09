import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/effective_volume.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';


/// 桌面端音量控制按钮：点击弹出滑块调节音量。
/// 链路路由与显示统一走 effective_volume.dart(与桌面歌词浮窗共用):
/// - 投屏(选中远端 peer) → POST /peers/:id/volume {volume:0-100}；
/// - DLNA 直投 → SOAP SetVolume；
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

  /// 拖动实时下发节流器:投屏链路 ≤10 次/秒防刷爆网络,静默后尾部补发;
  /// 本机走 setVolumeLive(live 路径,实时跟手、不逐次落盘)。
  late final ThrottledVolumeSender _sender = ThrottledVolumeSender(
    onSend: (v) => setEffectiveVolume(ref, v, live: true),
  );

  /// 音量浮层内实时音量（0.0~1.0）：驱动滑杆滑块与百分比文本即时刷新，
  /// 不依赖 provider 重建（浮层位于根 Overlay，父 setState 不会重建它）。
  final ValueNotifier<double> _overlayVolume = ValueNotifier<double>(0.0);

  /// 拖动手感触感节流：音量跨越 ≥4% 才给一次 selectionClick，避免每帧震。
  double _lastVolumeHaptic = -1;

  /// 竖向滑杆拖动/点击：即时刷新浮层，再按当前目标路由（节流下发）。
  void _onVerticalChanged(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    _overlayVolume.value = clamped;
    if ((clamped - _lastVolumeHaptic).abs() >= 0.04) {
      _lastVolumeHaptic = clamped;
      HapticFeedback.selectionClick();
    }
    _onSliderChanged(clamped);
  }

  /// 竖向滑杆松手/点击抬起：刷新浮层并提交最终音量。
  void _onVerticalCommit(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    _overlayVolume.value = clamped;
    HapticFeedback.selectionClick();
    _onSliderCommit(clamped);
  }

  /// 拖动中：节流实时下发(链路路由统一走 setEffectiveVolume)。
  void _onSliderChanged(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    setState(() => _dragValue = clamped);
    _sender.send(clamped);
  }

  /// 松手：复位节流并提交最终值(本机落盘 / 投屏发最终值,均不经节流)。
  void _onSliderCommit(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    setState(() => _dragValue = null);
    _sender.reset();
    unawaited(setEffectiveVolume(ref, clamped));
  }

  /// 步进键：以当前有效音量为基准，每次 ±3%，立即命中当前播放目标。
  void _stepVolume(int dir) {
    if (dir == 0) return;
    final double base = _dragValue ?? ref.read(effectiveVolumeProvider);
    final next = (base + 0.03 * dir).clamp(0.0, 1.0).toDouble();
    _onVerticalChanged(next);
    _onVerticalCommit(next);
  }

  void _toggleOverlay() {
    final loc = AppLocalizations.of(context);
    if (_overlayEntry != null) {
      _removeOverlay();
      return;
    }
    _overlayVolume.value = ref.read(effectiveVolumeProvider);
    _lastVolumeHaptic = -1;
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
              bottom: widget.anchorTop ? null : 96,
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
                      width: 134,
                      height: 372,
                      // overlay 内仍需响应外部音量变化（设备端/其它端修改）。
                      child: Consumer(
                        builder: (context, ref, _) {
                          // 有效音量统一取 effectiveVolumeProvider:
                          // 投屏取设备/peer 回报值,未回报回退本机。
                          final double sourceVolume = ref.watch(
                            effectiveVolumeProvider,
                          );
                          // 拖动中显示拖动值，否则显示真实值。
                          final volume = _dragValue ?? sourceVolume;
                          // 音量浮层内即时值：驱动滑块与百分比实时刷新。
                          _overlayVolume.value = volume;
                          return ValueListenableBuilder<double>(
                            valueListenable: _overlayVolume,
                            builder: (context, live, _) {
                              final percent = (live * 100).round();
                              // 当前播放媒体:音量浮层顶部展示封面/标题/艺人,
                              // 让调音量时一眼看到正在控制的是哪首歌。
                              final currentSong = ref.watch(
                                playerProvider.select((s) => s.currentSong),
                              );
                              return Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (currentSong != null) ...[
                                    _VolumeMediaInfo(song: currentSong),
                                    const SizedBox(height: 10),
                                  ],
                                  // 实时显示当前音量数值（拖动时即时刷新，字号更大便于触屏查看）。
                                  Text(
                                    '$percent%',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                      color: context.musicFlowColors.ink,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _VolumeStepButton(
                                    icon: AppIcons.add,
                                    label: loc.player_volume_inc,
                                    onTap: () => _stepVolume(1),
                                  ),
                                  const SizedBox(height: 6),
                                  // 滑杆吃掉剩余高度(而非固定 150)：面板更紧凑/宽松时
                                  // 都由滑杆伸缩吸收,避免 RenderFlex 溢出。
                                  Expanded(
                                    child: Center(
                                      child: SizedBox(
                                        width: 56,
                                        child: _VerticalVolumeSlider(
                                          key: const Key(
                                            'volume-vertical-slider',
                                          ),
                                          value: live,
                                          // 音量条配色跟随播放控件底色:
                                          // 已激活段用控件强调色,未激活段用弱化前景,
                                          // 与播放控件的按钮/文字色一致。
                                          activeColor: mediaColors.accent,
                                          inactiveColor: mediaColors.muted
                                              .withValues(alpha: 0.38),
                                          onChanged: _onVerticalChanged,
                                          onChangeEnd: _onVerticalCommit,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  _VolumeStepButton(
                                    icon: AppIcons.removeCircle,
                                    label: loc.player_volume_dec,
                                    onTap: () => _stepVolume(-1),
                                  ),
                                ],
                              );
                            },
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
    _overlayVolume.dispose();
    _sender.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final double volume = _dragValue ?? ref.watch(effectiveVolumeProvider);
    final percent = (volume * 100).round();
    // 对齐主项目前端音量按钮:音量>0 显示扬声器+声波,=0 显示静音;
    // 弹窗展开时高亮(对应前端 vol-active)。
    final icon = volume > 0 ? AppIcons.volumeHigh : AppIcons.volumeMute;
    return Tooltip(
      message: loc.player_volume_percent(percent),
      child: MusicFlowIconButton(
        icon: icon,
        label: loc.player_volume_percent(percent),
        selected: _overlayEntry != null,
        foregroundColor: context.musicFlowColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: _toggleOverlay,
      ),
    );
  }
}

/// 竖向音量滑杆：轨道加粗、拇指加大，命中区覆盖整条高度——
/// 按住任意高度纵向拖动即改音量，点按任意位置直接跳转。上=大声，下=小声。
/// 值由外部 [value] 驱动（浮层通过 ValueListenable 实时刷新），本组件纯受控。
class _VerticalVolumeSlider extends StatelessWidget {
  const _VerticalVolumeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.activeColor,
    required this.inactiveColor,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final Color activeColor;
  final Color inactiveColor;

  // 横条样式拇指：比轨道宽、高度小，两端圆角（对齐参考图中的实心浅色横杠）。
  static const double _thumbWidth = 36;
  static const double _thumbHeight = 8;
  static const double _trackWidth = 10;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final travel = (height - _thumbHeight)
            .clamp(0.0, double.infinity)
            .toDouble();
        final progress = value.clamp(0.0, 1.0).toDouble();
        // 上=大声：拇指中心距顶部 = travel * progress。
        final thumbTop = height - _thumbHeight / 2 - travel * progress;
        final fillHeight = height - (thumbTop + _thumbHeight / 2);

        // 拖动中最后应用的值：松手/抬起时提交它，而不是读取可能落后一帧的
        // [value] 属性——指针释放时的即时位置必须被准确落盘。
        var lastApplied = progress;

        void apply(double dy) {
          // 顶部(Y=0)=100%，底部(Y=height)=0%。
          final next =
              (1 - ((dy - _thumbHeight / 2) / travel)).clamp(0.0, 1.0).toDouble();
          lastApplied = next;
          onChanged(next);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => apply(d.localPosition.dy),
          onTapUp: (_) => onChangeEnd(lastApplied),
          onVerticalDragUpdate: (d) => apply(d.localPosition.dy),
          onVerticalDragEnd: (_) => onChangeEnd(lastApplied),
          child: Center(
            child: SizedBox(
              width: _trackWidth,
              height: height,
              child: Stack(
                children: <Widget>[
                  // 未激活整轨。
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: inactiveColor,
                        borderRadius: BorderRadius.circular(_trackWidth / 2),
                      ),
                    ),
                  ),
                  // 已激活段（自底部起，达拇指中心）。
                  if (fillHeight > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: fillHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: activeColor,
                          borderRadius: BorderRadius.circular(_trackWidth / 2),
                        ),
                      ),
                    ),
                  // 拇指：实心横向圆角短条，与已激活段同色（参考图样式）。
                  Positioned(
                    top: thumbTop,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: activeColor,
                          borderRadius: BorderRadius.circular(_thumbHeight / 2),
                        ),
                        child: const SizedBox(
                          width: _thumbWidth,
                          height: _thumbHeight,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 音量浮层顶部的「当前播放媒体」信息:小封面 + 标题 + 艺人(单行省略),
/// 让调音量时一眼看到正在控制的是哪首歌。
class _VolumeMediaInfo extends StatelessWidget {
  const _VolumeMediaInfo({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final artist = song.artist?.trim() ?? '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CoverArtImage(
            coverArtId: song.coverArt,
            size: 44,
            requestSize: 120,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.musicFlowColors.ink,
                ),
              ),
              if (artist.isNotEmpty)
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
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

/// 音量步进键（＋/－）：圆形轻触目标，每次调用 [onTap] 步进音量。
class _VolumeStepButton extends StatelessWidget {
  const _VolumeStepButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return Tooltip(
      message: label,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        containedInkWell: true,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.controlBoundary.withValues(alpha: 0.28),
          ),
          child: Icon(icon, size: 18, color: colors.ink),
        ),
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

