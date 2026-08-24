import 'package:flutter/material.dart';

import '../music_flow_context.dart';

enum MusicFlowSurfaceLevel { canvas, surface, raised, floating, modal }

/// A semantic Echo surface. Ordinary content remains flat; shadows are reserved
/// for floating and modal layers.
class MusicFlowSurface extends StatelessWidget {
  const MusicFlowSurface({
    super.key,
    required this.child,
    this.level = MusicFlowSurfaceLevel.surface,
    this.color,
    this.padding,
    this.margin,
    this.borderRadius,
    this.borderColor,
    this.clipBehavior = Clip.none,
  });

  const MusicFlowSurface.canvas({
    super.key,
    required this.child,
    this.color,
    this.padding,
    this.margin,
    this.borderRadius = BorderRadius.zero,
    this.borderColor,
    this.clipBehavior = Clip.none,
  }) : level = MusicFlowSurfaceLevel.canvas;

  final Widget child;
  final MusicFlowSurfaceLevel level;
  final Color? color;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadiusGeometry? borderRadius;
  final Color? borderColor;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final radii = context.musicFlowRadii;
    final resolvedColor =
        color ??
        switch (level) {
          MusicFlowSurfaceLevel.canvas => colors.canvas,
          MusicFlowSurfaceLevel.surface => colors.surface,
          MusicFlowSurfaceLevel.raised => colors.raised,
          MusicFlowSurfaceLevel.floating => colors.surface,
          MusicFlowSurfaceLevel.modal => colors.surface,
        };
    final resolvedRadius =
        borderRadius ??
        switch (level) {
          MusicFlowSurfaceLevel.canvas => BorderRadius.zero,
          MusicFlowSurfaceLevel.surface => radii.surface,
          MusicFlowSurfaceLevel.raised => radii.control,
          MusicFlowSurfaceLevel.floating => radii.surface,
          MusicFlowSurfaceLevel.modal => radii.scene,
        };
    final shadows = switch (level) {
      MusicFlowSurfaceLevel.floating => <BoxShadow>[
        BoxShadow(
          color: const Color(0xFF04080C).withValues(alpha: 0.18),
          offset: const Offset(0, 8),
          blurRadius: 24,
        ),
      ],
      MusicFlowSurfaceLevel.modal => <BoxShadow>[
        BoxShadow(
          color: const Color(0xFF04080C).withValues(alpha: 0.28),
          offset: const Offset(0, 18),
          blurRadius: 48,
        ),
      ],
      MusicFlowSurfaceLevel.canvas ||
      MusicFlowSurfaceLevel.surface ||
      MusicFlowSurfaceLevel.raised => const <BoxShadow>[],
    };

    return Container(
      margin: margin,
      padding: padding,
      clipBehavior: clipBehavior,
      decoration: BoxDecoration(
        color: resolvedColor,
        borderRadius: resolvedRadius,
        border: borderColor == null ? null : Border.all(color: borderColor!),
        boxShadow: shadows,
      ),
      child: child,
    );
  }
}
