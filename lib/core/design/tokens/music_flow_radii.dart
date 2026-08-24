import 'package:flutter/material.dart';

/// Semantic corner shapes. Consumers receive complete border radii so no
/// component needs to reinterpret raw radius numbers.
@immutable
class MusicFlowRadii extends ThemeExtension<MusicFlowRadii> {
  const MusicFlowRadii({
    required this.detail,
    required this.control,
    required this.surface,
    required this.scene,
    required this.pill,
  });

  static const MusicFlowRadii standard = MusicFlowRadii(
    detail: BorderRadius.all(Radius.circular(4)),
    control: BorderRadius.all(Radius.circular(12)),
    surface: BorderRadius.all(Radius.circular(16)),
    scene: BorderRadius.all(Radius.circular(24)),
    pill: BorderRadius.all(Radius.circular(999)),
  );

  final BorderRadius detail;
  final BorderRadius control;
  final BorderRadius surface;
  final BorderRadius scene;
  final BorderRadius pill;

  @override
  MusicFlowRadii copyWith({
    BorderRadius? detail,
    BorderRadius? control,
    BorderRadius? surface,
    BorderRadius? scene,
    BorderRadius? pill,
  }) {
    return MusicFlowRadii(
      detail: detail ?? this.detail,
      control: control ?? this.control,
      surface: surface ?? this.surface,
      scene: scene ?? this.scene,
      pill: pill ?? this.pill,
    );
  }

  @override
  MusicFlowRadii lerp(covariant MusicFlowRadii? other, double t) {
    if (other == null) {
      return this;
    }
    return MusicFlowRadii(
      detail: BorderRadius.lerp(detail, other.detail, t)!,
      control: BorderRadius.lerp(control, other.control, t)!,
      surface: BorderRadius.lerp(surface, other.surface, t)!,
      scene: BorderRadius.lerp(scene, other.scene, t)!,
      pill: BorderRadius.lerp(pill, other.pill, t)!,
    );
  }
}
