import 'package:flutter/material.dart';

import 'package:musicflow_client/core/design/music_flow_context.dart';
import 'package:musicflow_client/core/design/tokens/music_flow_breakpoints.dart';

/// 首页「播放控制」整体块的**平台尺寸常量**。
///
/// 为什么集中在一处:散落在各 widget 里就没法保证「骨架 / 空态 / 告警 /
/// 面板开合」各态高度一致了(R14:任何状态都不改变块高)。所有 widget 一律
/// 经 [remoteControlMetricsFor] 取尺寸,**不得**在别处写裸数字 280 / 360。
@immutable
class RemoteControlMetrics {
  const RemoteControlMetrics({
    required this.totalHeight,
    required this.switcherHeight,
    required this.nowHeight,
    required this.controlsHeight,
    required this.progressHeight,
    required this.lyricLineCount,
    required this.lyricLineHeight,
    required this.coverSize,
    required this.controlIconSize,
    required this.titleRowHeight,
    required this.titleGap,
    required this.padding,
    required this.gap,
  });

  /// Android / compact / medium(Q5 / U-5:采纳 U-1 后 Android 维持 280)。
  static const RemoteControlMetrics standard = RemoteControlMetrics(
    totalHeight: 280,
    switcherHeight: 40,
    nowHeight: 104, // 曲名 22 + gap 2 + 歌词 4×20
    controlsHeight: 56,
    progressHeight: 28,
    lyricLineCount: 4,
    lyricLineHeight: 20,
    coverSize: 92,
    controlIconSize: 24,
    titleRowHeight: 22,
    titleGap: 2,
    padding: EdgeInsets.symmetric(vertical: 16),
    gap: 10,
  );

  /// Windows / expanded(Q3,宽 ≥ 840)。单列加高,不做半栏、不做歌词与队列并排。
  static const RemoteControlMetrics expanded = RemoteControlMetrics(
    totalHeight: 360,
    switcherHeight: 48,
    nowHeight: 196, // 曲名 28 + gap 8 + 歌词 8×20
    controlsHeight: 64,
    progressHeight: 30,
    lyricLineCount: 8,
    lyricLineHeight: 20,
    coverSize: 160,
    controlIconSize: 30,
    titleRowHeight: 28,
    titleGap: 8,
    padding: EdgeInsets.symmetric(vertical: 8),
    gap: 3,
  );

  final double totalHeight;
  final double switcherHeight;
  final double nowHeight;
  final double controlsHeight;
  final double progressHeight;
  final int lyricLineCount;
  final double lyricLineHeight;
  final double coverSize;
  final double controlIconSize;

  /// Now 区内:曲名行高与「曲名 ⇄ 歌词视口」间隔。
  /// 不变量:nowHeight == titleRowHeight + titleGap + lyricViewportHeight。
  final double titleRowHeight;
  final double titleGap;
  final EdgeInsets padding;
  final double gap;

  /// 歌词视口高度(Now 区内部滚动区)。
  double get lyricViewportHeight => lyricLineCount * lyricLineHeight;

  /// 三行主体 + 进度条的总高(不含块内边距)。
  double get bodyHeight =>
      switcherHeight + gap + nowHeight + gap + controlsHeight + progressHeight;

  /// Now 区不变量:曲名行 + 间隔 + 歌词视口 == nowHeight(±0.5)。
  bool get isNowConsistent =>
      (titleRowHeight + titleGap + lyricViewportHeight - nowHeight).abs() <
      0.5;

  /// 不变量:四段高度 + 间隔 + 内边距 == totalHeight(±0.5 容差)。
  /// 单测锁死 —— 任何调错都会让「固定高度」变成「布局溢出/留白」。
  bool get isConsistent =>
      (padding.vertical + bodyHeight - totalHeight).abs() < 0.5;
}

/// 断点:仅 expanded(宽 ≥ 840)走放大态,compact / medium 同 Android 尺寸。
RemoteControlMetrics remoteControlMetricsFor(BuildContext context) =>
    context.musicFlowWindowClass == MusicFlowWindowClass.expanded
        ? RemoteControlMetrics.expanded
        : RemoteControlMetrics.standard;
