import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

enum MusicFlowWindowClass { compact, medium, expanded }

/// Structural breakpoints. Typography remains stable while navigation and
/// content composition change at these boundaries.
@immutable
class MusicFlowBreakpoints extends ThemeExtension<MusicFlowBreakpoints> {
  const MusicFlowBreakpoints({
    required this.medium,
    required this.expanded,
    required this.maxContentWidth,
  });

  static const MusicFlowBreakpoints standard = MusicFlowBreakpoints(
    medium: 600,
    expanded: 840,
    maxContentWidth: 1200,
  );

  final double medium;
  final double expanded;
  final double maxContentWidth;

  MusicFlowWindowClass classify(double width) {
    if (width < medium) {
      return MusicFlowWindowClass.compact;
    }
    if (width < expanded) {
      return MusicFlowWindowClass.medium;
    }
    return MusicFlowWindowClass.expanded;
  }

  @override
  MusicFlowBreakpoints copyWith({
    double? medium,
    double? expanded,
    double? maxContentWidth,
  }) {
    return MusicFlowBreakpoints(
      medium: medium ?? this.medium,
      expanded: expanded ?? this.expanded,
      maxContentWidth: maxContentWidth ?? this.maxContentWidth,
    );
  }

  @override
  MusicFlowBreakpoints lerp(covariant MusicFlowBreakpoints? other, double t) {
    if (other == null) {
      return this;
    }
    return MusicFlowBreakpoints(
      medium: lerpDouble(medium, other.medium, t)!,
      expanded: lerpDouble(expanded, other.expanded, t)!,
      maxContentWidth: lerpDouble(maxContentWidth, other.maxContentWidth, t)!,
    );
  }
}
