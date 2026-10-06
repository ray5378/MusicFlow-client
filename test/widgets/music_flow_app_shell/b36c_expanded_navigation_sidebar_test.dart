// b36c —— `lib/widgets/music_flow_app_shell/expanded_navigation_sidebar.dart`
// 补测（原 22 miss）。
//
// 覆盖：展开态渲染 ShellSidebarDestination / ShellSidebarActionEntry、
// 点击目的地回调 branchIndex；点击头部菜单折叠为图标窄栏（ShellSidebarIconDestination /
// ShellSidebarIconEntry + 语义标签切换）；再次点击展开；底部设置动作经 onOpenPage 派发。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/expanded_navigation_sidebar.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/shell_destinations.dart';

const _destinations = <MusicFlowShellDestination>[
  MusicFlowShellDestination(
    branchIndex: 0,
    label: '音乐流',
    icon: AppIcons.home,
    selectedIcon: AppIcons.homeFilled,
  ),
  MusicFlowShellDestination(
    branchIndex: 1,
    label: '探索',
    icon: AppIcons.discover,
    selectedIcon: AppIcons.discoverFilled,
  ),
];

final _libraryEntries = <MusicFlowSidebarLibraryEntry>[
  MusicFlowSidebarLibraryEntry(
    label: '歌曲',
    icon: AppIcons.music,
    onTap: () {},
  ),
];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(500, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.light(),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: c!,
        ),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              child,
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('展开态：渲染目的地与曲库入口，点击目的地回调 branchIndex', (tester) async {
    final selected = <int>[];
    await _pump(
      tester,
      MusicFlowExpandedNavigationSidebar(
        destinations: _destinations,
        selectedBranchIndex: 1,
        onDestinationSelected: selected.add,
        onOpenDrawer: () {},
        libraryEntries: _libraryEntries,
      ),
    );

    // 展开态列表用 ShellSidebarDestination（带可见文字标签）。
    expect(find.byType(ShellSidebarDestination), findsNWidgets(2));
    expect(find.byType(ShellSidebarActionEntry), findsNWidgets(2)); // 歌曲入口 + 设置
    expect(find.text('音乐流'), findsOneWidget);
    expect(find.text('探索'), findsOneWidget);
    expect(find.text('歌曲'), findsOneWidget);
    // 头部品牌标题。
    expect(find.text('MusicFlow'), findsOneWidget);

    await tester.tap(find.text('音乐流'));
    await tester.pumpAndSettle();
    expect(selected, <int>[0]);
  });

  testWidgets('点击菜单折叠为图标窄栏，再点恢复展开', (tester) async {
    await _pump(
      tester,
      MusicFlowExpandedNavigationSidebar(
        destinations: _destinations,
        selectedBranchIndex: 0,
        onDestinationSelected: (_) {},
        onOpenDrawer: () {},
        libraryEntries: _libraryEntries,
      ),
    );

    expect(find.byType(ShellSidebarDestination), findsNWidgets(2));

    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pumpAndSettle();

    // 折叠态：图标窄条 + Tooltip；不再有可见文字标签。
    expect(find.byType(ShellSidebarIconDestination), findsNWidgets(2));
    expect(find.byType(ShellSidebarIconEntry), findsNWidgets(2)); // 歌曲入口 + 设置
    expect(find.byType(ShellSidebarDestination), findsNothing);
    expect(find.text('MusicFlow'), findsNothing);
    expect(find.byTooltip('歌曲'), findsOneWidget);

    // 再次点击菜单恢复展开。
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pumpAndSettle();
    expect(find.byType(ShellSidebarDestination), findsNWidgets(2));
  });

  testWidgets('折叠态点击目的地回调 branchIndex', (tester) async {
    final selected = <int>[];
    await _pump(
      tester,
      MusicFlowExpandedNavigationSidebar(
        destinations: _destinations,
        selectedBranchIndex: 0,
        onDestinationSelected: selected.add,
        onOpenDrawer: () {},
      ),
    );

    // 先折叠。
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ShellSidebarIconDestination).last);
    await tester.pumpAndSettle();
    expect(selected, <int>[1]);
  });

  testWidgets('底部设置动作经 onOpenPage 派发', (tester) async {
    final opened = <Widget>[];
    await _pump(
      tester,
      MusicFlowExpandedNavigationSidebar(
        destinations: _destinations,
        selectedBranchIndex: 0,
        onDestinationSelected: (_) {},
        onOpenDrawer: () {},
        onOpenPage: (page) async => opened.add(page),
      ),
    );

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
  });
}
