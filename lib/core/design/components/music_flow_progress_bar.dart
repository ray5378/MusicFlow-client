import 'package:flutter/material.dart';

import '../music_flow_context.dart';

class MusicFlowProgressBar extends StatelessWidget {
  const MusicFlowProgressBar({
    super.key,
    required this.value,
    this.color,
    this.trackColor,
    this.height = 4,
    this.semanticLabel,
  });

  final double value;
  final Color? color;
  final Color? trackColor;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final normalized = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    final colors = context.musicFlowColors;
    final motion = context.musicFlowMotion;
    final radius = BorderRadius.circular(height / 2);
    final percent = (normalized * 100).round();

    return Semantics(
      label: semanticLabel,
      value: '$percent%',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(
            color: trackColor ?? colors.divider,
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: AnimatedFractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: normalized,
                heightFactor: 1,
                duration: motion.resolve(context, motion.state),
                curve: motion.easeOut,
                child: ColoredBox(color: color ?? colors.accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
