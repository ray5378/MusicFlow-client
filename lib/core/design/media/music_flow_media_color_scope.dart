import 'package:flutter/material.dart';

import '../tokens/music_flow_colors.dart';
import '../tokens/music_flow_typography.dart';
import 'music_flow_media_visuals.dart';

enum MusicFlowMediaSurfaceRole { stage, mini, panel }

/// Installs artwork-derived Echo tokens for one media-led subtree.
///
/// Spacing, radii, motion, breakpoints, and interaction extensions are kept
/// from the parent theme. Only colour and typography semantics are replaced.
class MusicFlowMediaColorScope extends StatelessWidget {
  const MusicFlowMediaColorScope({
    super.key,
    required this.visuals,
    required this.role,
    required this.child,
  });

  final MusicFlowMediaVisuals visuals;
  final MusicFlowMediaSurfaceRole role;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parentTheme = Theme.of(context);
    final parentColors =
        parentTheme.extension<MusicFlowColors>() ??
        (parentTheme.brightness == Brightness.dark
            ? MusicFlowColors.dark()
            : MusicFlowColors.light());
    final parentTypography =
        parentTheme.extension<MusicFlowTypography>() ??
        MusicFlowTypography.standard(parentColors);
    final colors = _mediaColors(parentColors, visuals, role);
    final typography = _mediaTypography(parentTypography, colors);
    final extensions =
        List<ThemeExtension<dynamic>>.of(parentTheme.extensions.values)
          ..removeWhere(
            (extension) =>
                extension is MusicFlowColors || extension is MusicFlowTypography,
          );
    extensions.addAll(<ThemeExtension<dynamic>>[colors, typography]);

    return Theme(
      data: parentTheme.copyWith(extensions: extensions),
      child: child,
    );
  }
}

MusicFlowColors _mediaColors(
  MusicFlowColors parent,
  MusicFlowMediaVisuals visuals,
  MusicFlowMediaSurfaceRole role,
) {
  final (canvas, surface, raised) = switch (role) {
    MusicFlowMediaSurfaceRole.stage => (
      visuals.stageBase,
      visuals.stageBase,
      visuals.stageGlow,
    ),
    MusicFlowMediaSurfaceRole.mini => (
      visuals.miniSurface,
      visuals.miniSurface,
      visuals.panelSurface,
    ),
    MusicFlowMediaSurfaceRole.panel => (
      visuals.panelSurface,
      visuals.panelSurface,
      visuals.miniSurface,
    ),
  };
  final mediaSurfaces = <Color>[
    visuals.stageBase,
    visuals.stageGlow,
    visuals.stageBottom,
    visuals.miniSurface,
    visuals.panelSurface,
  ];
  final error = MusicFlowColors.ensureColorContrastAcross(
    parent.error,
    backgrounds: mediaSurfaces,
  );
  final warning = MusicFlowColors.ensureColorContrastAcross(
    parent.warning,
    backgrounds: mediaSurfaces,
  );
  final divider = MusicFlowColors.ensureColorContrastAcross(
    parent.divider,
    backgrounds: mediaSurfaces,
    minimumRatio: 3,
  );
  final onDisabled = MusicFlowColors.ensureColorContrastAcross(
    Color.lerp(visuals.mutedForeground, surface, 0.18)!,
    backgrounds: mediaSurfaces,
    minimumRatio: 3,
  );
  final onSurface = MusicFlowColors.readableOn(surface);
  // 文字用固定高对比前景(黑/白),不随封面主色调漂移,保证任何封面都清晰可读。
  // 歌手/辅助文字(muted)用同一前景按表面轻微融合以区分层级。
  final fixedMuted = Color.lerp(onSurface, surface, 0.22)!;
  final onAccent = MusicFlowColors.ensureColorContrast(
    MusicFlowColors.readableOn(visuals.controlAccent),
    background: visuals.controlAccent,
  );

  return parent.copyWith(
    accent: visuals.controlAccent,
    onAccent: onAccent,
    contentTint: visuals.controlAccent,
    onContentTint: onAccent,
    canvas: canvas,
    surface: surface,
    raised: raised,
    ink: onSurface,
    muted: fixedMuted,
    divider: divider,
    controlBoundary: visuals.controlAccent,
    error: error,
    onError: MusicFlowColors.readableOn(error),
    warning: warning,
    onWarning: MusicFlowColors.readableOn(warning),
    disabled: raised,
    onDisabled: onDisabled,
  );
}

MusicFlowTypography _mediaTypography(MusicFlowTypography parent, MusicFlowColors colors) {
  return parent.copyWith(
    display: parent.display.copyWith(color: colors.ink),
    headline: parent.headline.copyWith(color: colors.ink),
    title: parent.title.copyWith(color: colors.ink),
    body: parent.body.copyWith(color: colors.ink),
    label: parent.label.copyWith(color: colors.ink),
    metadata: parent.metadata.copyWith(color: colors.muted),
  );
}
