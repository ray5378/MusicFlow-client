import 'package:flutter/material.dart';

import '../music_flow_context.dart';
import 'music_flow_pressable.dart';

class MusicFlowIconButton extends StatelessWidget {
  const MusicFlowIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.foregroundColor,
    this.backgroundColor,
    this.iconSize = 22,
    this.enableHaptics = false,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final Color? foregroundColor;
  final Color? backgroundColor;
  final double iconSize;
  final bool enableHaptics;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final enabled = onPressed != null;
    final foreground = enabled
        ? foregroundColor ?? (selected ? colors.accent : colors.ink)
        : colors.onDisabled;
    final background =
        backgroundColor ??
        (selected
            ? colors.accent.withValues(alpha: 0.14)
            : enabled
            ? Colors.transparent
            : colors.raised.withValues(alpha: 0.7));

    return MusicFlowPressable(
      semanticLabel: label,
      selected: selected,
      onPressed: onPressed,
      minimumSize: context.musicFlowInteraction.minimumTouchSize,
      borderRadius: context.musicFlowRadii.control,
      enableHaptics: enableHaptics,
      autofocus: autofocus,
      child: SizedBox.square(
        dimension: context.musicFlowInteraction.minimumTouchTarget,
        child: Ink(
          decoration: BoxDecoration(
            color: background,
            borderRadius: context.musicFlowRadii.control,
          ),
          child: Center(
            child: Icon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}
