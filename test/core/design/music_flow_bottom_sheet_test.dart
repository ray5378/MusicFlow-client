import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_bottom_sheet.dart';

void main() {
  group('MusicFlowBottomSheet platform adaptation', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('desktop dialog has no drag handle and no top-only radius', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showMusicFlowBottomSheet<void>(
                  context: context,
                  builder: (_) => const MusicFlowBottomSheet(
                    title: '关于 MusicFlow',
                    child: Text('body'),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>('music_flow_bottom_sheet_drag_handle'),
        ),
        findsNothing,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('compact bottom sheet keeps drag handle', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showMusicFlowBottomSheet<void>(
                  context: context,
                  builder: (_) => const MusicFlowBottomSheet(
                    title: '关于 MusicFlow',
                    child: Text('body'),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>('music_flow_bottom_sheet_drag_handle'),
        ),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
