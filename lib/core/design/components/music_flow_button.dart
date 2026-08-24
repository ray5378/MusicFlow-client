import 'package:flutter/material.dart';

import '../music_flow_context.dart';
import 'music_flow_pressable.dart';

enum MusicFlowButtonVariant { primary, secondary, ghost, destructive }

class MusicFlowButton extends StatelessWidget {
  const MusicFlowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = MusicFlowButtonVariant.primary,
    this.leadingIcon,
    this.trailingIcon,
    this.expand = false,
    this.enableHaptics = false,
    this.semanticLabel,
  });

  const MusicFlowButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.expand = false,
    this.enableHaptics = false,
    this.semanticLabel,
  }) : variant = MusicFlowButtonVariant.primary;

  const MusicFlowButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.expand = false,
    this.enableHaptics = false,
    this.semanticLabel,
  }) : variant = MusicFlowButtonVariant.secondary;

  const MusicFlowButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.expand = false,
    this.enableHaptics = false,
    this.semanticLabel,
  }) : variant = MusicFlowButtonVariant.ghost;

  const MusicFlowButton.destructive({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    this.expand = false,
    this.enableHaptics = false,
    this.semanticLabel,
  }) : variant = MusicFlowButtonVariant.destructive;

  final String label;
  final VoidCallback? onPressed;
  final MusicFlowButtonVariant variant;
  final IconData? leadingIcon;
  final IconData? trailingIcon;
  final bool expand;
  final bool enableHaptics;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final enabled = onPressed != null;
    final background = enabled
        ? switch (variant) {
            MusicFlowButtonVariant.primary => colors.accent,
            MusicFlowButtonVariant.secondary => colors.raised,
            MusicFlowButtonVariant.ghost => Colors.transparent,
            MusicFlowButtonVariant.destructive => colors.error,
          }
        : switch (variant) {
            MusicFlowButtonVariant.ghost => Colors.transparent,
            MusicFlowButtonVariant.primary ||
            MusicFlowButtonVariant.secondary ||
            MusicFlowButtonVariant.destructive => colors.raised,
          };
    final foreground = enabled
        ? switch (variant) {
            MusicFlowButtonVariant.primary => colors.onAccent,
            MusicFlowButtonVariant.secondary => colors.ink,
            MusicFlowButtonVariant.ghost => colors.accent,
            MusicFlowButtonVariant.destructive => _foregroundOn(colors.error),
          }
        : colors.onDisabled;
    final horizontalPadding = variant == MusicFlowButtonVariant.ghost
        ? context.musicFlowSpacing.sm
        : 20.0;

    return MusicFlowPressable(
      semanticLabel: semanticLabel ?? label,
      onPressed: onPressed,
      minimumSize: Size(
        expand ? double.infinity : context.musicFlowInteraction.minimumTouchTarget,
        context.musicFlowInteraction.buttonHeight,
      ),
      borderRadius: context.musicFlowRadii.control,
      enableHaptics: enableHaptics,
      child: Ink(
        decoration: BoxDecoration(
          color: background,
          borderRadius: context.musicFlowRadii.control,
          border: variant == MusicFlowButtonVariant.secondary
              ? Border.all(color: colors.controlBoundary)
              : null,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: context.musicFlowSpacing.sm,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final text = Text(
                label,
                textAlign: TextAlign.center,
                style: context.musicFlowTypography.label.copyWith(color: foreground),
              );
              final children = <Widget>[
                if (leadingIcon != null) ...<Widget>[
                  Icon(leadingIcon, size: 20, color: foreground),
                  SizedBox(width: context.musicFlowSpacing.xs),
                ],
                if (constraints.hasBoundedWidth)
                  Flexible(child: text)
                else
                  text,
                if (trailingIcon != null) ...<Widget>[
                  SizedBox(width: context.musicFlowSpacing.xs),
                  Icon(trailingIcon, size: 20, color: foreground),
                ],
              ];
              return Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: children,
              );
            },
          ),
        ),
      ),
    );
  }

  static Color _foregroundOn(Color background) {
    final whiteContrast = _contrastRatio(Colors.white, background);
    final blackContrast = _contrastRatio(Colors.black, background);
    return whiteContrast >= blackContrast ? Colors.white : Colors.black;
  }

  static double _contrastRatio(Color foreground, Color background) {
    final lighter =
        foreground.computeLuminance() >= background.computeLuminance()
        ? foreground.computeLuminance()
        : background.computeLuminance();
    final darker = foreground.computeLuminance() < background.computeLuminance()
        ? foreground.computeLuminance()
        : background.computeLuminance();
    return (lighter + 0.05) / (darker + 0.05);
  }
}
