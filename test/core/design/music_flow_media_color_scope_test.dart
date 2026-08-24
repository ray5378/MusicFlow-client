import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'media scopes map light and dark artwork into accessible local tokens',
    (tester) async {
      final visualsCases = <MusicFlowMediaVisuals>[
        MusicFlowMediaVisuals.fallback(seed: const Color(0xFFFFE36B)),
        MusicFlowMediaVisuals.fallback(seed: const Color(0xFF101D33)),
      ];

      for (final theme in <ThemeData>[AppTheme.light(), AppTheme.dark()]) {
        for (final visuals in visualsCases) {
          for (final role in MusicFlowMediaSurfaceRole.values) {
            late MusicFlowColors outerColors;
            late MusicFlowColors scopedColors;
            late MusicFlowTypography scopedTypography;
            late MusicFlowSpacing outerSpacing;
            late MusicFlowSpacing scopedSpacing;
            late MusicFlowRadii outerRadii;
            late MusicFlowRadii scopedRadii;
            late MusicFlowMotion outerMotion;
            late MusicFlowMotion scopedMotion;
            late MusicFlowInteraction outerInteraction;
            late MusicFlowInteraction scopedInteraction;
            late MusicFlowBreakpoints outerBreakpoints;
            late MusicFlowBreakpoints scopedBreakpoints;
            late Brightness scopedBrightness;

            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                darkTheme: theme,
                themeMode: theme.brightness == Brightness.dark
                    ? ThemeMode.dark
                    : ThemeMode.light,
                home: Builder(
                  builder: (outerContext) {
                    outerColors = outerContext.musicFlowColors;
                    outerSpacing = outerContext.musicFlowSpacing;
                    outerRadii = outerContext.musicFlowRadii;
                    outerMotion = outerContext.musicFlowMotion;
                    outerInteraction = outerContext.musicFlowInteraction;
                    outerBreakpoints = outerContext.musicFlowBreakpoints;
                    return MusicFlowMediaColorScope(
                      visuals: visuals,
                      role: role,
                      child: Builder(
                        builder: (innerContext) {
                          scopedColors = innerContext.musicFlowColors;
                          scopedTypography = innerContext.musicFlowTypography;
                          scopedSpacing = innerContext.musicFlowSpacing;
                          scopedRadii = innerContext.musicFlowRadii;
                          scopedMotion = innerContext.musicFlowMotion;
                          scopedInteraction = innerContext.musicFlowInteraction;
                          scopedBreakpoints = innerContext.musicFlowBreakpoints;
                          scopedBrightness = Theme.of(innerContext).brightness;
                          return const SizedBox.shrink();
                        },
                      ),
                    );
                  },
                ),
              ),
            );
            await tester.pumpAndSettle();

            final expectedSurface = switch (role) {
              MusicFlowMediaSurfaceRole.stage => visuals.stageBase,
              MusicFlowMediaSurfaceRole.mini => visuals.miniSurface,
              MusicFlowMediaSurfaceRole.panel => visuals.panelSurface,
            };
            final expectedRaised = switch (role) {
              MusicFlowMediaSurfaceRole.stage => visuals.stageGlow,
              MusicFlowMediaSurfaceRole.mini => visuals.panelSurface,
              MusicFlowMediaSurfaceRole.panel => visuals.miniSurface,
            };

            expect(scopedColors, isNot(outerColors));
            expect(scopedColors.canvas, expectedSurface);
            expect(scopedColors.surface, expectedSurface);
            expect(scopedColors.raised, expectedRaised);
            expect(scopedColors.ink, visuals.foreground);
            expect(scopedColors.muted, visuals.mutedForeground);
            expect(scopedColors.accent, visuals.controlAccent);
            expect(scopedColors.controlBoundary, visuals.controlAccent);
            expect(scopedTypography.display.color, visuals.foreground);
            expect(scopedTypography.headline.color, visuals.foreground);
            expect(scopedTypography.title.color, visuals.foreground);
            expect(scopedTypography.body.color, visuals.foreground);
            expect(scopedTypography.label.color, visuals.foreground);
            expect(scopedTypography.metadata.color, visuals.mutedForeground);
            expect(scopedSpacing, same(outerSpacing));
            expect(scopedRadii, same(outerRadii));
            expect(scopedMotion, same(outerMotion));
            expect(scopedInteraction, same(outerInteraction));
            expect(scopedBreakpoints, same(outerBreakpoints));
            expect(scopedBrightness, theme.brightness);
            _expectAccessibleScope(scopedColors, visuals);
          }
        }
      }
    },
  );
}

void _expectAccessibleScope(MusicFlowColors colors, MusicFlowMediaVisuals visuals) {
  final surfaces = <Color>{
    colors.canvas,
    colors.surface,
    colors.raised,
    visuals.stageBase,
    visuals.stageGlow,
    visuals.stageBottom,
    visuals.miniSurface,
    visuals.panelSurface,
  };
  for (final surface in surfaces) {
    for (final foreground in <Color>[
      colors.ink,
      colors.muted,
      colors.error,
      colors.warning,
    ]) {
      expect(
        MusicFlowColors.contrastRatio(foreground, surface),
        greaterThanOrEqualTo(4.5),
      );
    }
    for (final boundary in <Color>[
      colors.accent,
      colors.controlBoundary,
      colors.divider,
      colors.onDisabled,
    ]) {
      expect(
        MusicFlowColors.contrastRatio(boundary, surface),
        greaterThanOrEqualTo(3),
      );
    }
  }

  for (final (foreground, background) in <(Color, Color)>[
    (colors.onAccent, colors.accent),
    (colors.onContentTint, colors.contentTint),
    (colors.onError, colors.error),
    (colors.onWarning, colors.warning),
  ]) {
    expect(
      MusicFlowColors.contrastRatio(foreground, background),
      greaterThanOrEqualTo(4.5),
    );
  }
  expect(
    MusicFlowColors.contrastRatio(colors.onDisabled, colors.disabled),
    greaterThanOrEqualTo(3),
  );
}
