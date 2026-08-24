import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MusicFlowMessage contrast', () {
    test('inverse-surface accents can be normalized to non-text contrast', () {
      const candidates = <Color>[
        MusicFlowColors.dayInk,
        MusicFlowColors.nightInk,
        Color(0xFFFFFFFF),
        Color(0xFF050505),
        Color(0xFFFFFF00),
        Color(0xFF00E5FF),
      ];

      for (final candidate in candidates) {
        for (final palette in <MusicFlowColors>[
          MusicFlowColors.light(accent: candidate),
          MusicFlowColors.dark(accent: candidate),
        ]) {
          final normalized = MusicFlowColors.ensureColorContrast(
            palette.accent,
            background: palette.ink,
            minimumRatio: 3,
          );

          expect(
            MusicFlowColors.contrastRatio(normalized, palette.ink),
            greaterThanOrEqualTo(3),
          );
        }
      }
    });

    testWidgets('icon and border remain visible with extreme user accents', (
      tester,
    ) async {
      for (final theme in <ThemeData>[
        AppTheme.light(seedColor: MusicFlowColors.dayInk),
        AppTheme.dark(seedColor: MusicFlowColors.nightInk),
      ]) {
        final colors = theme.extension<MusicFlowColors>()!;

        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: Center(child: MusicFlowMessage(message: '播放已恢复')),
            ),
          ),
        );

        final messageSurface = tester.widget<MusicFlowSurface>(
          find.byType(MusicFlowSurface),
        );
        final messageIcon = tester.widget<Icon>(find.byIcon(AppIcons.info));

        expect(messageSurface.borderColor, isNotNull);
        expect(messageIcon.color, isNotNull);
        expect(
          MusicFlowColors.contrastRatio(messageSurface.borderColor!, colors.ink),
          greaterThanOrEqualTo(3),
        );
        expect(
          MusicFlowColors.contrastRatio(messageIcon.color!, colors.ink),
          greaterThanOrEqualTo(3),
        );
      }
    });
  });

  testWidgets(
    'full-height bottom sheet preserves the top safe area at 200% text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      const safeInsets = EdgeInsets.only(top: 44, bottom: 34);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                padding: safeInsets,
                viewPadding: safeInsets,
                textScaler: const TextScaler.linear(2),
              ),
              child: child!,
            );
          },
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () {
                    showEchoBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (sheetContext) => LayoutBuilder(
                        builder: (context, constraints) => SizedBox(
                          height: constraints.maxHeight,
                          child: const MusicFlowBottomSheet(
                            title: '播放队列与播放选项',
                            child: Text('当前队列'),
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      final sheetRect = tester.getRect(find.byType(MusicFlowBottomSheet));
      expect(sheetRect.top, greaterThanOrEqualTo(safeInsets.top));
      expect(sheetRect.bottom, lessThanOrEqualTo(844));
      expect(tester.takeException(), isNull);
    },
  );
}
