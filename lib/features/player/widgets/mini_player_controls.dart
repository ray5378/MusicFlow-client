import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/player/widgets/volume_button.dart';

/// 迷你播放条控件区构建器：桌面端全控件 / 响应式渐隐 / 手机端简略版。
///
/// 从 `mini_player.dart` 的 `_MiniPlayerViewState` 控件构建方法抽出
/// （v5.8.4 大页面拆分子组件，行为零变更）：以显式参数取代对 view state
/// 的引用，逻辑逐行搬运。产出的是 `List<Widget>`（由调用方 spread 进其
/// 外层 Row），保持与原实现完全一致的布局语义。
class MiniPlayerControls {
  const MiniPlayerControls({
    required this.isPlaying,
    required this.isFavorite,
    required this.currentPlayerName,
    required this.isCasting,
    required this.playMode,
    required this.onTogglePlayPause,
    this.onPrevious,
    this.onNext,
    this.onTogglePlayMode,
    this.onToggleFavorite,
    this.onSwitchPlayer,
    this.onOpenQueue,
  });

  final bool isPlaying;

  /// 当前歌曲收藏态（喜欢按钮高亮）。
  final bool isFavorite;
  final String currentPlayerName;
  final bool isCasting;

  /// 桌面端播放模式(对齐主项目前端 playMode:order|one|all|shuffle)。
  final String playMode;

  final VoidCallback onTogglePlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onTogglePlayMode;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onSwitchPlayer;
  final VoidCallback? onOpenQueue;

  /// 按平台与窗口宽度产出控件列表：桌面端走响应式渐隐，手机端简略版。
  ///
  /// [isDesktop] 由调用方按 `Theme.of(context).platform` 推导（与抽取前
  /// `_MiniPlayerViewState._isDesktop` 同规则）；[windowWidth] 取自行外层
  /// LayoutBuilder 的 `constraints.maxWidth`。
  List<Widget> buildControls(
    BuildContext context, {
    required bool isDesktop,
    required double windowWidth,
  }) {
    if (!isDesktop) {
      return _buildMobileControls(context);
    }
    return _buildResponsiveDesktopControls(
      context,
      windowWidth: windowWidth,
    );
  }

  /// 桌面端全控件：上一首 / 播放暂停 / 下一首 / 播放模式 / 喜欢 / 队列 /
  /// 音量 / 流转播放。每个按钮包一层 Tooltip（悬停显示文字注释，
  /// 对齐主项目前端），播放模式为单一按钮,点击循环切换模式并变换图标。
  List<Widget> _buildDesktopControls(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return <Widget>[
      Tooltip(
        message: loc.player_previous,
        child: MusicFlowIconButton(
          icon: AppIcons.previous,
          label: loc.player_previous,
          iconSize: 20,
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: onPrevious,
        ),
      ),
      Tooltip(
        message: isPlaying ? loc.player_pause : loc.widgets_play,
        child: MusicFlowIconButton(
          icon: isPlaying ? AppIcons.pause : AppIcons.play,
          label: isPlaying ? loc.player_pause : loc.widgets_play,
          iconSize: 20,
          foregroundColor: context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: onTogglePlayPause,
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
          onPressed: onNext,
        ),
      ),
      _PlayModeButton(
        mode: playMode,
        iconSize: 20,
        onPressed: onTogglePlayMode,
      ),
      Tooltip(
        message: isFavorite ? loc.player_unfavorite : loc.player_favorite,
        child: MusicFlowIconButton(
          icon: isFavorite ? AppIcons.heart : AppIcons.heartOutline,
          label: isFavorite ? loc.player_unfavorite : loc.player_favorite,
          iconSize: 20,
          selected: isFavorite,
          // 底色**永远透明**，选中只靠前景色(accent)表达：
          // MusicFlowIconButton 在 selected 时会带一块 accent 14% 的底色块，
          // 而同排的上一首/下一首/播放/投屏都是「无底色纯图标」—— 于是这两个
          // 按钮一旦选中就"和周边不一样"（多出一块背景）。这里统一掉。
          backgroundColor: Colors.transparent,
          onPressed: onToggleFavorite,
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
          onPressed: onOpenQueue,
        ),
      ),
      const VolumeButton(),
      Tooltip(
        message: loc.player_transfer_playback_current(currentPlayerName),
        child: MusicFlowIconButton(
          icon: AppIcons.transferInfinity,
          label: loc.player_transfer_playback_current(currentPlayerName),
          iconSize: 20,
          foregroundColor: isCasting
              ? context.musicFlowColors.accent
              : context.musicFlowColors.ink,
          backgroundColor: Colors.transparent,
          onPressed: onSwitchPlayer,
        ),
      ),
    ];
  }

  /// 响应式桌面端控件：随窗口宽度「渐隐」非核心按钮。
  /// 保留最关键的 上一首/播放暂停/下一首(列表前三个)，其余
  /// (播放模式/红心/队列/音量/流转播放)在窗口变窄时从右往左
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
        icon: isPlaying ? AppIcons.pause : AppIcons.play,
        label: isPlaying ? loc.player_pause : loc.widgets_play,
        iconSize: 20,
        foregroundColor: context.musicFlowColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: onTogglePlayPause,
      ),
      MusicFlowIconButton(
        icon: AppIcons.transferInfinity,
        label: loc.player_transfer_playback_current(currentPlayerName),
        foregroundColor: isCasting
            ? context.musicFlowColors.accent
            : context.musicFlowColors.ink,
        backgroundColor: Colors.transparent,
        onPressed: onSwitchPlayer,
      ),
    ];
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
    // 用**白名单**而不是 `mode != 'all' && mode != 'order'`：后者碰到任何意外值
    // (空串 / 投屏态服务端返回的其它字符串 / 未来新增模式)都会判成 true ⇒ 按钮
    // 永远高亮。白名单只在真的处于 one/shuffle 时高亮。
    final selected = mode == 'one' || mode == 'shuffle';
    return Tooltip(
      message: modeLabel,
      child: MusicFlowIconButton(
        icon: modeIcon,
        label: modeLabel,
        iconSize: iconSize,
        selected: selected,
        // 同喜欢按钮:底色永远透明,one/shuffle 的"高亮"只由前景色 accent 表达,
        // 外观与同排其它图标按钮保持一致。
        backgroundColor: Colors.transparent,
        onPressed: onPressed,
      ),
    );
  }
}
