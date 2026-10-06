// b36c —— `lib/features/discover/widgets/remote_control_metrics.dart` 补测（原 5/10）。
//
// 覆盖：standard / expanded 两个平台预设的不变量（bodyHeight、
// lyricViewportHeight、isNowConsistent、isConsistent）以及
// remoteControlMetricsFor 按窗口宽度在 expanded / compact 间路由。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';

void main() {
  group('RemoteControlMetrics 不变量', () {
    test('standard 预设：主体/歌词视口/总高自洽', () {
      const m = RemoteControlMetrics.standard;
      expect(m.lyricViewportHeight, 4 * 20);
      expect(
        m.bodyHeight,
        m.switcherHeight + m.gap + m.nowHeight + m.gap + m.controlsHeight,
      );
      expect(m.isNowConsistent, isTrue);
      expect(m.isConsistent, isTrue);
      expect(m.totalHeight, 252);
    });

    test('expanded 预设：主体/歌词视口/总高自洽', () {
      const m = RemoteControlMetrics.expanded;
      expect(m.lyricViewportHeight, 8 * 20);
      expect(m.isNowConsistent, isTrue);
      expect(m.isConsistent, isTrue);
      expect(m.totalHeight, 330);
    });

    test('两个预设的关键字段非零，符合放大语义', () {
      const s = RemoteControlMetrics.standard;
      const e = RemoteControlMetrics.expanded;
      expect(e.coverSize > s.coverSize, isTrue);
      expect(e.controlIconSize > s.controlIconSize, isTrue);
      expect(e.lyricLineCount > s.lyricLineCount, isTrue);
      expect(e.nowHeight > s.nowHeight, isTrue);
    });
  });

  group('remoteControlMetricsFor 断点路由', () {
    Future<RemoteControlMetrics> pumpAt(
      WidgetTester tester,
      double width,
    ) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late RemoteControlMetrics metrics;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              metrics = remoteControlMetricsFor(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return metrics;
    }

    testWidgets('宽 ≥ 840 走 expanded 放大尺寸', (tester) async {
      final metrics = await pumpAt(tester, 1000);
      expect(metrics.totalHeight, RemoteControlMetrics.expanded.totalHeight);
    });

    testWidgets('窄屏(compact)回落 standard 尺寸', (tester) async {
      final metrics = await pumpAt(tester, 400);
      expect(metrics.totalHeight, RemoteControlMetrics.standard.totalHeight);
    });
  });
}
