import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_page_header.dart';
import 'package:musicflow_client/core/design/components/music_flow_scaffold.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show kWindowsWindowControlsWidth;

import '../../helpers/windows_overlap.dart';

void main() {
  const double viewportWidth = 1200;

  Widget app(Widget child) {
    return MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));
  }

  group('Windows top-bar window-control clearance', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('MusicFlowTopBar reserves space for window controls', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        app(
          MusicFlowTopBar(
            title: '专辑详情',
            actions: <Widget>[
              MusicFlowIconButton(
                icon: Icons.sort,
                label: '排序',
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      final actionRect = tester.getRect(find.byType(MusicFlowIconButton));
      expect(
        actionRect.right,
        lessThanOrEqualTo(viewportWidth - kWindowsWindowControlsWidth),
        reason: 'Windows 无标题栏时右上角有最小化/最大化/关闭按钮，'
            '顶栏操作按钮不得进入该区域。',
      );
      expectNoWindowsWindowControlOverlap(tester, viewportWidth: viewportWidth);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('MusicFlowTopBar uses full width on non-Windows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      await tester.pumpWidget(
        app(
          MusicFlowTopBar(
            title: '专辑详情',
            actions: <Widget>[
              MusicFlowIconButton(
                icon: Icons.sort,
                label: '排序',
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      final actionRect = tester.getRect(find.byType(MusicFlowIconButton));
      expect(
        actionRect.right,
        greaterThan(viewportWidth - kWindowsWindowControlsWidth),
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('MusicFlowPageHeader trailing keeps clear of window controls', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(viewportWidth, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        app(
          MusicFlowPageHeader(
            title: '音乐流',
            trailing: MusicFlowIconButton(
              icon: Icons.settings,
              label: '设置',
              onPressed: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final trailingRect = tester.getRect(find.byType(MusicFlowIconButton));
      expect(
        trailingRect.right,
        lessThanOrEqualTo(viewportWidth - kWindowsWindowControlsWidth),
      );
      expectNoWindowsWindowControlOverlap(tester, viewportWidth: viewportWidth);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
