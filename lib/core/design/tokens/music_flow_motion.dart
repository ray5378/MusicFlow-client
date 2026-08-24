import 'package:flutter/material.dart';

/// Motion tiers for feedback, component state, and spatial scene changes.
@immutable
class MusicFlowMotion extends ThemeExtension<MusicFlowMotion> {
  const MusicFlowMotion({
    required this.feedback,
    required this.state,
    required this.scene,
    required this.easeOut,
    required this.sceneCurve,
  });

  static const MusicFlowMotion standard = MusicFlowMotion(
    feedback: Duration(milliseconds: 160),
    state: Duration(milliseconds: 220),
    scene: Duration(milliseconds: 300),
    easeOut: Cubic(0.22, 1, 0.36, 1),
    sceneCurve: Cubic(0.16, 1, 0.3, 1),
  );

  final Duration feedback;
  final Duration state;
  final Duration scene;
  final Curve easeOut;
  final Curve sceneCurve;

  /// Returns an instant transition whenever the user requests less motion.
  Duration resolve(BuildContext context, Duration duration) {
    final mediaQuery = MediaQuery.maybeOf(context);
    final platformDisabled = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    return (mediaQuery?.disableAnimations ?? platformDisabled)
        ? Duration.zero
        : duration;
  }

  @override
  MusicFlowMotion copyWith({
    Duration? feedback,
    Duration? state,
    Duration? scene,
    Curve? easeOut,
    Curve? sceneCurve,
  }) {
    return MusicFlowMotion(
      feedback: feedback ?? this.feedback,
      state: state ?? this.state,
      scene: scene ?? this.scene,
      easeOut: easeOut ?? this.easeOut,
      sceneCurve: sceneCurve ?? this.sceneCurve,
    );
  }

  @override
  MusicFlowMotion lerp(covariant MusicFlowMotion? other, double t) {
    if (other == null) {
      return this;
    }
    return MusicFlowMotion(
      feedback: _lerpDuration(feedback, other.feedback, t),
      state: _lerpDuration(state, other.state, t),
      scene: _lerpDuration(scene, other.scene, t),
      easeOut: t < 0.5 ? easeOut : other.easeOut,
      sceneCurve: t < 0.5 ? sceneCurve : other.sceneCurve,
    );
  }

  static Duration _lerpDuration(Duration a, Duration b, double t) {
    return Duration(
      microseconds:
          (a.inMicroseconds + (b.inMicroseconds - a.inMicroseconds) * t)
              .round(),
    );
  }
}
