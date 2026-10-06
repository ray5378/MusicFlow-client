import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/compact_navigation.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/medium_navigation_rail.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/shell_destinations.dart';

// Route C 补测：app shell 导航组件
// - lib/widgets/music_flow_app_shell/compact_navigation.dart（含 ShellSidebarAppActions）
// - lib/widgets/music_flow_app_shell/medium_navigation_rail.dart
void main() {
  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: child),
        ),
      );

  List<MusicFlowShellDestination> dests() => <MusicFlowShellDestination>[
        const MusicFlowShellDestination(
          branchIndex: 0,
          label: '发现',
          icon: AppIcons.search,
          selectedIcon: AppIcons.search,
        ),
        const MusicFlowShellDestination(
          branchIndex: 1,
          label: '媒体库',
          icon: AppIcons.album,
          selectedIcon: AppIcons.album,
        ),
      ];

  testWidgets('compact navigation renders destinations and selects',
      (tester) async {
    var selected = -1;
    await tester.pumpWidget(
      wrap(
        MusicFlowCompactNavigation(
          destinations: dests(),
          selectedBranchIndex: 0,
          onDestinationSelected: (i) => selected = i,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('媒体库'));
    expect(selected, 1);
  });

  testWidgets('medium navigation rail taps destination', (tester) async {
    var selected = -1;
    await tester.pumpWidget(
      wrap(
        MusicFlowMediumNavigationRail(
          destinations: dests(),
          selectedBranchIndex: 0,
          onDestinationSelected: (i) => selected = i,
          onOpenDrawer: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('媒体库'));
    expect(selected, 1);
  });

  testWidgets('sidebar app actions dispatch settings via onOpenPage',
      (tester) async {
    Widget? opened;
    await tester.pumpWidget(
      wrap(
        ShellSidebarAppActions(
          collapsed: true,
          onOpenPage: (page) async => opened = page,
        ),
      ),
    );
    await tester.pump();

    // 收起态条目（ShellSidebarIconEntry）只渲染图标 + Tooltip，文本仅存在于
    // 语义标签里，树中没有 Text('设置')，所以按「设置图标」上溯到它的可点击
    // MusicFlowPressable，并校验该入口的语义标签确实是「设置」。
    final settingsEntry = find.ancestor(
      of: find.byIcon(AppIcons.settings),
      matching: find.byWidgetPredicate(
        (Widget widget) =>
            widget is MusicFlowPressable && widget.semanticLabel == '设置',
      ),
    );
    expect(settingsEntry, findsOneWidget);

    await tester.tap(settingsEntry);
    await tester.pump();
    expect(opened, isNotNull);
    expect(opened, isA<AppSettingsPage>());
  });
}
