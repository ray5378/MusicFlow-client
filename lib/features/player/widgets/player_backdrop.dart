import 'package:flutter/material.dart';

import '../../../core/design/media/music_flow_media_visuals.dart';
import '../../../core/design/tokens/music_flow_colors.dart';

/// The two spatial states used by the shared player background Hero.
enum MusicFlowPlayerBackdropMode { mini, stage }

/// Artwork-derived background shared by MiniPlayer and the full player.
///
/// Both modes use a three-stop gradient so the Hero shuttle can interpolate
/// one stable material instead of cross-fading unrelated widgets.
class MusicFlowPlayerBackdrop extends StatelessWidget {
  const MusicFlowPlayerBackdrop({
    super.key,
    required this.visuals,
    required this.mode,
  });

  final MusicFlowMediaVisuals visuals;
  final MusicFlowPlayerBackdropMode mode;

  BoxDecoration get decoration =>
      _PlayerBackdropSpec(visuals: visuals, mode: mode).decoration;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(decoration: decoration, child: const SizedBox.expand());
  }
}

/// Interpolates the MiniPlayer background into the player stage on the route's
/// single Hero timeline.
///
/// The departing backdrop owns the palette for the duration of the flight.
/// This prevents an asynchronous palette refresh from changing foreground
/// polarity halfway through a shared-element transition. The destination can
/// adopt a newer palette atomically after the Hero lands.
Widget playerBackgroundFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromHero = fromHeroContext.widget as Hero;
  final toHero = toHeroContext.widget as Hero;
  final fromChild = fromHero.child;
  final toChild = toHero.child;

  if (_reduceMotion(flightContext)) return toChild;

  final fromBackdrop = fromChild is MusicFlowPlayerBackdrop ? fromChild : null;
  final toBackdrop = toChild is MusicFlowPlayerBackdrop ? toChild : null;
  if (fromBackdrop == null || toBackdrop == null) return toChild;

  final flightVisuals = fromBackdrop.visuals;
  final fromSpec = _PlayerBackdropSpec(
    visuals: flightVisuals,
    mode: fromBackdrop.mode,
  );
  final toSpec = _PlayerBackdropSpec(
    visuals: flightVisuals,
    mode: toBackdrop.mode,
  );

  return AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final progress = flightDirection == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      return RepaintBoundary(
        child: DecoratedBox(
          key: const ValueKey<String>('player-background-flight'),
          decoration: _PlayerBackdropSpec.lerp(
            fromSpec,
            toSpec,
            progress.clamp(0.0, 1.0),
          ),
          child: const SizedBox.expand(),
        ),
      );
    },
  );
}

bool _reduceMotion(BuildContext context) {
  final mediaQuery = MediaQuery.maybeOf(context);
  return mediaQuery?.disableAnimations ??
      WidgetsBinding
          .instance
          .platformDispatcher
          .accessibilityFeatures
          .disableAnimations;
}

class _PlayerBackdropSpec {
  const _PlayerBackdropSpec({required this.visuals, required this.mode});

  final MusicFlowMediaVisuals visuals;
  final MusicFlowPlayerBackdropMode mode;

  static const BorderRadius _miniRadius = BorderRadius.all(Radius.circular(16));
  static const List<double> _gradientStops = <double>[0, 0.48, 1];

  List<Color> get colors => switch (mode) {
    MusicFlowPlayerBackdropMode.mini => <Color>[
      visuals.miniSurface,
      visuals.miniSurface,
      visuals.miniSurface,
    ],
    MusicFlowPlayerBackdropMode.stage => <Color>[
      visuals.stageGlow,
      visuals.stageBase,
      visuals.stageBottom,
    ],
  };

  BorderRadius get borderRadius => switch (mode) {
    MusicFlowPlayerBackdropMode.mini => _miniRadius,
    MusicFlowPlayerBackdropMode.stage => BorderRadius.zero,
  };

  BoxBorder? get border => switch (mode) {
    MusicFlowPlayerBackdropMode.mini => Border.all(color: visuals.controlAccent),
    MusicFlowPlayerBackdropMode.stage => null,
  };

  BoxDecoration get decoration => BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[
        for (final color in colors)
          _ensureBackdropContrast(
            color,
            foreground: visuals.foreground,
            control: visuals.controlAccent,
          ),
      ],
      stops: _gradientStops,
    ),
    borderRadius: borderRadius,
    border: border,
    boxShadow: const <BoxShadow>[],
  );

  static BoxDecoration lerp(
    _PlayerBackdropSpec from,
    _PlayerBackdropSpec to,
    double progress,
  ) {
    final foreground = from.visuals.foreground;
    final control = from.visuals.controlAccent;
    final fromColors = from.colors;
    final toColors = to.colors;
    final colors = <Color>[
      for (var index = 0; index < 3; index += 1)
        _ensureBackdropContrast(
          Color.lerp(fromColors[index], toColors[index], progress)!,
          foreground: foreground,
          control: control,
        ),
    ];

    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: colors,
        stops: _gradientStops,
      ),
      borderRadius: BorderRadius.lerp(
        from.borderRadius,
        to.borderRadius,
        progress,
      ),
      border: BoxBorder.lerp(from.border, to.border, progress),
      boxShadow: const <BoxShadow>[],
    );
  }
}

/// 纯函数结果缓存:同一 (candidate, foreground, control) 三元组只计算一次。
/// 避免在 build 路径反复执行 22 次二分 × 2 目标的对比度搜索(SEC §8.1)。
/// 容量封顶,防止 palette 变化导致无限增长。
final Map<int, Color> _backdropContrastCache = <int, Color>{};
const int _backdropContrastCacheLimit = 96;

Color _ensureBackdropContrast(
  Color candidate, {
  required Color foreground,
  required Color control,
}) {
  final key = Object.hash(
    candidate.toARGB32(),
    foreground.toARGB32(),
    control.toARGB32(),
  );
  final cached = _backdropContrastCache[key];
  if (cached != null) return cached;

  final result = _ensureBackdropContrastUncached(
    candidate,
    foreground: foreground,
    control: control,
  );
  if (_backdropContrastCache.length >= _backdropContrastCacheLimit) {
    _backdropContrastCache.clear();
  }
  _backdropContrastCache[key] = result;
  return result;
}

Color _ensureBackdropContrastUncached(
  Color candidate, {
  required Color foreground,
  required Color control,
}) {
  final opaque = candidate.withValues(alpha: 1);

  bool passes(Color background) {
    return MusicFlowColors.contrastRatio(foreground, background) >= 4.5 &&
        MusicFlowColors.contrastRatio(control, background) >= 3;
  }

  if (passes(opaque)) return opaque;

  Color? closest;
  var closestAmount = double.infinity;
  for (final target in const <Color>[Colors.black, Colors.white]) {
    if (!passes(target)) continue;

    var failing = 0.0;
    var passing = 1.0;
    for (var iteration = 0; iteration < 22; iteration += 1) {
      final midpoint = (failing + passing) / 2;
      final value = Color.lerp(opaque, target, midpoint)!;
      if (passes(value)) {
        passing = midpoint;
      } else {
        failing = midpoint;
      }
    }

    if (passing < closestAmount) {
      closestAmount = passing;
      closest = Color.lerp(opaque, target, passing)!.withValues(alpha: 1);
    }
  }

  if (closest != null) return closest;

  // MusicFlowMediaVisuals normally makes this branch unreachable. Keep a
  // deterministic text-safe fallback for malformed test or integration data.
  return MusicFlowColors.ensureForegroundContrast(
    opaque,
    foreground: foreground,
    minimumRatio: 4.5,
  );
}
