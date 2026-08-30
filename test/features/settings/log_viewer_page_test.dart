import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/features/settings/pages/log_viewer_page.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show kWindowsWindowControlsWidth;

import '../../helpers/windows_overlap.dart';

void main() {
  group('LogViewerPage Windows title-bar overlap', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'Windows desktop keeps app-bar actions clear of window controls',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;

        await tester.pumpWidget(
          const MaterialApp(home: LogViewerPage()),
        );
        // 页面内 1s 轮询 Timer 让 pumpAndSettle 无法收敛，只 pump 一帧。
        await tester.pump();

        final actions = find.byType(MusicFlowIconButton);
        expect(actions, findsNWidgets(2));

        final lastRect = tester.getRect(actions.last);
        expect(
          lastRect.right,
          lessThanOrEqualTo(1200 - kWindowsWindowControlsWidth),
        );
        // 通用重叠防线：页面内任何可点击控件都不得侵入右上角系统按钮区。
        expectNoWindowsWindowControlOverlap(tester, viewportWidth: 1200);
        // 平台 override 须在测试体结束前复位：invariant 校验早于任何 addTearDown。
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'non-Windows platform uses full width for app-bar actions',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;

        await tester.pumpWidget(
          const MaterialApp(home: LogViewerPage()),
        );
        await tester.pump();

        final actions = find.byType(MusicFlowIconButton);
        final lastRect = tester.getRect(actions.last);
        // Linux 没有 Windows 窗口按钮，actions 应贴近窗口右边缘。
        expect(lastRect.right, greaterThan(1200 - kWindowsWindowControlsWidth));
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}
