import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MusicFlow semantic tokens', () {
    test('light and dark palettes keep stable chrome', () {
      final light = MusicFlowColors.light();
      final dark = MusicFlowColors.dark();

      expect(light.canvas, MusicFlowColors.dayCanvas);
      expect(light.surface, MusicFlowColors.daySurface);
      expect(dark.canvas, MusicFlowColors.nightCanvas);
      expect(dark.surface, MusicFlowColors.nightSurface);
      expect(light.canvas, isNot(dark.canvas));
    });

    test('accent foregrounds meet WCAG AA for varied user colors', () {
      const candidates = <Color>[
        Color(0xFFFFFFFF),
        Color(0xFFFFFF00),
        Color(0xFF00E5FF),
        Color(0xFF050505),
        Color(0xFF7E57C2),
      ];

      for (final candidate in candidates) {
        for (final palette in <MusicFlowColors>[
          MusicFlowColors.light(accent: candidate),
          MusicFlowColors.dark(accent: candidate),
        ]) {
          expect(
            MusicFlowColors.contrastRatio(palette.onAccent, palette.accent),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            MusicFlowColors.contrastRatio(palette.accent, palette.canvas),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    });

    test(
      'dynamic content surfaces are normalized for readable foregrounds',
      () {
        const foreground = Colors.white;
        const candidates = <Color>[
          Color(0xFFFFFF00),
          Color(0xFF00E5FF),
          Color(0xFFFFFFFF),
          Color(0xFF7E57C2),
        ];

        for (final candidate in candidates) {
          final normalized = MusicFlowColors.ensureForegroundContrast(
            candidate,
            foreground: foreground,
          );
          expect(
            MusicFlowColors.contrastRatio(foreground, normalized),
            greaterThanOrEqualTo(4.5),
          );
        }
      },
    );

    test('message accents are normalized against inverse surfaces', () {
      final colors = MusicFlowColors.light();
      final action = MusicFlowColors.ensureColorContrast(
        colors.accent,
        background: colors.ink,
      );
      expect(
        MusicFlowColors.contrastRatio(action, colors.ink),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('error and warning inks meet WCAG AA on every stable surface', () {
      for (final palette in <MusicFlowColors>[
        MusicFlowColors.light(),
        MusicFlowColors.dark(),
      ]) {
        for (final surface in <Color>[
          palette.canvas,
          palette.surface,
          palette.raised,
        ]) {
          expect(
            MusicFlowColors.contrastRatio(palette.error, surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            MusicFlowColors.contrastRatio(palette.warning, surface),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(
          MusicFlowColors.contrastRatio(palette.onError, palette.error),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          MusicFlowColors.contrastRatio(palette.onWarning, palette.warning),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('interactive control boundaries meet non-text contrast', () {
      for (final palette in <MusicFlowColors>[
        MusicFlowColors.light(),
        MusicFlowColors.dark(),
      ]) {
        for (final surface in <Color>[
          palette.canvas,
          palette.surface,
          palette.raised,
        ]) {
          expect(
            MusicFlowColors.contrastRatio(palette.controlBoundary, surface),
            greaterThanOrEqualTo(3),
          );
        }
      }
    });

    test('token extensions support copyWith and lerp', () {
      final light = MusicFlowColors.light();
      final dark = MusicFlowColors.dark();
      final typography = MusicFlowTypography.standard(light);

      expect(light.copyWith(accent: Colors.red).accent, Colors.red);
      expect(light.lerp(dark, 0.5).canvas, isNot(light.canvas));
      expect(typography.copyWith(title: typography.display).title.fontSize, 26);
      expect(
        typography.lerp(MusicFlowTypography.standard(dark), 0.5).body,
        isA<TextStyle>(),
      );
      expect(MusicFlowSpacing.standard.copyWith(md: 20).md, 20);
      expect(
        MusicFlowSpacing.standard
            .lerp(MusicFlowSpacing.standard.copyWith(md: 24), 0.5)
            .md,
        20,
      );
      expect(
        MusicFlowRadii.standard.copyWith(control: MusicFlowRadii.standard.scene).control,
        MusicFlowRadii.standard.scene,
      );
      expect(
        MusicFlowRadii.standard.lerp(MusicFlowRadii.standard, 0.5).surface,
        MusicFlowRadii.standard.surface,
      );
      expect(
        MusicFlowMotion.standard.copyWith(feedback: Duration.zero).feedback,
        Duration.zero,
      );
      expect(
        MusicFlowMotion.standard
            .lerp(
              MusicFlowMotion.standard.copyWith(
                feedback: const Duration(milliseconds: 200),
              ),
              0.5,
            )
            .feedback,
        const Duration(milliseconds: 180),
      );
      expect(
        MusicFlowInteraction.standard
            .copyWith(minimumTouchTarget: 52)
            .minimumTouchTarget,
        52,
      );
      expect(
        MusicFlowInteraction.standard
            .lerp(
              MusicFlowInteraction.standard.copyWith(minimumTouchTarget: 56),
              0.5,
            )
            .minimumTouchTarget,
        52,
      );
      expect(MusicFlowBreakpoints.standard.copyWith(medium: 640).medium, 640);
      expect(
        MusicFlowBreakpoints.standard
            .lerp(MusicFlowBreakpoints.standard.copyWith(medium: 640), 0.5)
            .medium,
        620,
      );
    });

    test('breakpoints use the documented three structural widths', () {
      expect(MusicFlowBreakpoints.standard.classify(599), MusicFlowWindowClass.compact);
      expect(MusicFlowBreakpoints.standard.classify(600), MusicFlowWindowClass.medium);
      expect(MusicFlowBreakpoints.standard.classify(839), MusicFlowWindowClass.medium);
      expect(MusicFlowBreakpoints.standard.classify(840), MusicFlowWindowClass.expanded);
    });
  });

  group('AppTheme bridge', () {
    test('registers every MusicFlow ThemeExtension in both modes', () {
      for (final theme in <ThemeData>[AppTheme.light(), AppTheme.dark()]) {
        expect(theme.extension<MusicFlowColors>(), isNotNull);
        expect(theme.extension<MusicFlowTypography>(), isNotNull);
        expect(theme.extension<MusicFlowSpacing>(), isNotNull);
        expect(theme.extension<MusicFlowRadii>(), isNotNull);
        expect(theme.extension<MusicFlowMotion>(), isNotNull);
        expect(theme.extension<MusicFlowInteraction>(), isNotNull);
        expect(theme.extension<MusicFlowBreakpoints>(), isNotNull);
        expect(theme.splashFactory, NoSplash.splashFactory);
      }
    });

    testWidgets('BuildContext exposes registered tokens and window class', (
      tester,
    ) async {
      late MusicFlowColors colors;
      late MusicFlowWindowClass windowClass;
      late double pagePadding;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              colors = context.musicFlowColors;
              windowClass = context.musicFlowWindowClass;
              pagePadding = context.musicFlowPageHorizontalPadding;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(colors.canvas, MusicFlowColors.dayCanvas);
      expect(windowClass, MusicFlowWindowClass.medium);
      expect(pagePadding, MusicFlowSpacing.standard.lg);
    });
  });

  group('MusicFlow interaction primitives', () {
    testWidgets('buttons expose 48dp targets and activate', (tester) async {
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  MusicFlowIconButton(
                    icon: AppIcons.play,
                    label: '播放',
                    onPressed: () => activations++,
                  ),
                  MusicFlowButton.primary(
                    label: '重试',
                    onPressed: () => activations++,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(MusicFlowIconButton)), const Size(48, 48));
      expect(
        tester.getSize(find.byType(MusicFlowButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(find.bySemanticsLabel('播放'), findsOneWidget);

      await tester.tap(find.byType(MusicFlowIconButton));
      await tester.tap(find.byType(MusicFlowButton));
      expect(activations, 2);
    });

    testWidgets('long-press-only targets remain enabled and interactive', (
      tester,
    ) async {
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MusicFlowPressable(
              onPressed: null,
              onLongPress: () => activations++,
              child: const Text('任务行'),
            ),
          ),
        ),
      );

      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await tester.longPress(find.text('任务行'));
      expect(activations, 1);
    });

    testWidgets('skeleton becomes static when animations are disabled', (
      tester,
    ) async {
      // 组件已改 Consumer：裸 pump 无 ProviderScope 必挂（ref.watch 抛
      // No ProviderScope found），包一层默认可见容器。
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: MusicFlowSkeleton(width: 120, height: 16),
            ),
          ),
        ),
      );

      expect(find.byType(MusicFlowSkeleton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('AppIcons are backed by the Remix icon font', () {
      expect(AppIcons.play.fontPackage, 'remixicon');
      expect(AppIcons.library.fontPackage, 'remixicon');
    });
  });
}
