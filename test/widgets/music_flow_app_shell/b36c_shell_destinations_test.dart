// b36c —— `lib/widgets/music_flow_app_shell/shell_destinations.dart` 补测（原 32 miss）。
//
// 覆盖 6 个侧栏目的地/动作条目 widget 的渲染与交互：
//   * ShellCompactDestination：选中态标记 key、选中/未选中图标切换、点击回调；
//   * ShellRailDestination / ShellSidebarDestination：同上；
//   * ShellSidebarIconDestination / ShellSidebarIconEntry：折叠态 Tooltip 图标 +
//     点击回调；
//   * ShellSidebarActionEntry：曲库快捷入口点击回调；
//   * ShellAnimatedDestinationIcon / ShellAnimatedDestinationLabel：独立渲染。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/shell_destinations.dart';

const _destination = MusicFlowShellDestination(
  branchIndex: 3,
  label: '探索',
  icon: AppIcons.discover,
  selectedIcon: AppIcons.discoverFilled,
);

Widget _wrap(Widget child, {double width = 320, double height = 140}) {
  return MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: AppTheme.light(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  group('ShellCompactDestination', () {
    testWidgets('未选中：显示普通图标、标记 key，点击回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          ShellCompactDestination(
            destination: _destination,
            selected: false,
            onPressed: () => taps++,
          ),
        ),
      );
      expect(find.text('探索'), findsOneWidget);
      expect(find.byIcon(AppIcons.discover), findsOneWidget);
      expect(find.byIcon(AppIcons.discoverFilled), findsNothing);
      expect(
        find.byKey(
          const ValueKey<String>('musicflow-compact-selection-indicator-3'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byType(MusicFlowPressable));
      expect(taps, 1);
    });

    testWidgets('选中：切换为 selectedIcon', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ShellCompactDestination(
            destination: _destination,
            selected: true,
            onPressed: () {},
          ),
        ),
      );
      expect(find.byIcon(AppIcons.discoverFilled), findsOneWidget);
      expect(find.byIcon(AppIcons.discover), findsNothing);
    });
  });

  group('ShellRailDestination', () {
    testWidgets('渲染垂直标记与图标，点击回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          ShellRailDestination(
            destination: _destination,
            selected: true,
            onPressed: () => taps++,
          ),
          height: 180,
        ),
      );
      expect(
        find.byKey(
          const ValueKey<String>('musicflow-medium-selection-indicator-3'),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(AppIcons.discoverFilled), findsOneWidget);
      await tester.tap(find.byType(MusicFlowPressable));
      expect(taps, 1);
    });
  });

  group('ShellSidebarDestination', () {
    testWidgets('未选中：显示普通图标并点击回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          ShellSidebarDestination(
            destination: _destination,
            selected: false,
            onPressed: () => taps++,
          ),
          height: 180,
        ),
      );
      expect(find.text('探索'), findsOneWidget);
      expect(find.byIcon(AppIcons.discover), findsOneWidget);
      await tester.tap(find.byType(MusicFlowPressable));
      expect(taps, 1);
    });
  });

  group('ShellSidebarIconDestination', () {
    testWidgets('折叠态：Tooltip 承载标签、标记 key、点击回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          ShellSidebarIconDestination(
            destination: _destination,
            selected: true,
            onPressed: () => taps++,
          ),
          height: 120,
        ),
      );
      expect(find.byTooltip('探索'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>(
            'musicflow-expanded-collapsed-selection-indicator-3',
          ),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(AppIcons.discoverFilled), findsOneWidget);
      await tester.tap(find.byType(MusicFlowPressable));
      expect(taps, 1);
    });
  });

  group('ShellSidebarActionEntry', () {
    testWidgets('渲染标签/图标并点击回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          ShellSidebarActionEntry(
            label: '歌曲',
            icon: AppIcons.music,
            onPressed: () => taps++,
          ),
          height: 120,
        ),
      );
      expect(find.text('歌曲'), findsOneWidget);
      expect(find.byIcon(AppIcons.music), findsOneWidget);
      await tester.tap(find.byType(MusicFlowPressable));
      expect(taps, 1);
    });
  });

  group('ShellSidebarIconEntry', () {
    testWidgets('折叠态曲库入口：Tooltip + 点击回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          ShellSidebarIconEntry(
            label: '专辑',
            icon: AppIcons.album,
            onPressed: () => taps++,
          ),
          height: 120,
        ),
      );
      expect(find.byTooltip('专辑'), findsOneWidget);
      expect(find.byIcon(AppIcons.album), findsOneWidget);
      await tester.tap(find.byType(MusicFlowPressable));
      expect(taps, 1);
    });
  });

  group('ShellAnimatedDestinationIcon / Label', () {
    testWidgets('独立图标与文字渲染', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              ShellAnimatedDestinationIcon(
                icon: AppIcons.home,
                color: Colors.black,
                size: 20,
              ),
              ShellAnimatedDestinationLabel(
                label: '主页',
                color: Colors.black,
                selected: true,
              ),
            ],
          ),
        ),
      );
      expect(find.byIcon(AppIcons.home), findsOneWidget);
      expect(find.text('主页'), findsOneWidget);
    });
  });
}
