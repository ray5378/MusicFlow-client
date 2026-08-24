import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Shared physical metrics for touch, focus, and high-frequency media rows.
@immutable
class MusicFlowInteraction extends ThemeExtension<MusicFlowInteraction> {
  const MusicFlowInteraction({
    required this.minimumTouchTarget,
    required this.buttonHeight,
    required this.inputHeight,
    required this.songRowHeight,
    required this.expandedSongRowHeight,
    required this.iconSize,
    required this.smallIconSize,
    required this.focusRingWidth,
    required this.pressedScale,
    required this.disabledOpacity,
  });

  static const MusicFlowInteraction standard = MusicFlowInteraction(
    minimumTouchTarget: 48,
    buttonHeight: 48,
    inputHeight: 48,
    songRowHeight: 64,
    expandedSongRowHeight: 72,
    iconSize: 24,
    smallIconSize: 22,
    focusRingWidth: 2,
    // 按下缩放系数：0.94 配合高亮闪现,移动端与桌面端点击时都有清晰可感的
    // 「按压缩放」反馈(全局 MusicFlowPressable,由 AnimationController 驱动)。
    pressedScale: 0.94,
    disabledOpacity: 0.56,
  );

  final double minimumTouchTarget;
  final double buttonHeight;
  final double inputHeight;
  final double songRowHeight;
  final double expandedSongRowHeight;
  final double iconSize;
  final double smallIconSize;
  final double focusRingWidth;
  final double pressedScale;
  final double disabledOpacity;

  Size get minimumTouchSize => Size.square(minimumTouchTarget);

  @override
  MusicFlowInteraction copyWith({
    double? minimumTouchTarget,
    double? buttonHeight,
    double? inputHeight,
    double? songRowHeight,
    double? expandedSongRowHeight,
    double? iconSize,
    double? smallIconSize,
    double? focusRingWidth,
    double? pressedScale,
    double? disabledOpacity,
  }) {
    return MusicFlowInteraction(
      minimumTouchTarget: minimumTouchTarget ?? this.minimumTouchTarget,
      buttonHeight: buttonHeight ?? this.buttonHeight,
      inputHeight: inputHeight ?? this.inputHeight,
      songRowHeight: songRowHeight ?? this.songRowHeight,
      expandedSongRowHeight:
          expandedSongRowHeight ?? this.expandedSongRowHeight,
      iconSize: iconSize ?? this.iconSize,
      smallIconSize: smallIconSize ?? this.smallIconSize,
      focusRingWidth: focusRingWidth ?? this.focusRingWidth,
      pressedScale: pressedScale ?? this.pressedScale,
      disabledOpacity: disabledOpacity ?? this.disabledOpacity,
    );
  }

  @override
  MusicFlowInteraction lerp(covariant MusicFlowInteraction? other, double t) {
    if (other == null) {
      return this;
    }
    return MusicFlowInteraction(
      minimumTouchTarget: lerpDouble(
        minimumTouchTarget,
        other.minimumTouchTarget,
        t,
      )!,
      buttonHeight: lerpDouble(buttonHeight, other.buttonHeight, t)!,
      inputHeight: lerpDouble(inputHeight, other.inputHeight, t)!,
      songRowHeight: lerpDouble(songRowHeight, other.songRowHeight, t)!,
      expandedSongRowHeight: lerpDouble(
        expandedSongRowHeight,
        other.expandedSongRowHeight,
        t,
      )!,
      iconSize: lerpDouble(iconSize, other.iconSize, t)!,
      smallIconSize: lerpDouble(smallIconSize, other.smallIconSize, t)!,
      focusRingWidth: lerpDouble(focusRingWidth, other.focusRingWidth, t)!,
      pressedScale: lerpDouble(pressedScale, other.pressedScale, t)!,
      disabledOpacity: lerpDouble(disabledOpacity, other.disabledOpacity, t)!,
    );
  }
}
