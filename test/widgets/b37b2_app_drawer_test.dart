// ============================================================================
// b37b2 —— `lib/widgets/app_drawer.dart` 残余未覆盖分支补测。
//
// 基线 lcov（coverage/lcov.info）里 app_drawer.dart 仍标 0 的 12 行：
//   213,214,215,216,217,218  `_buildNavigationList` 里 `entry == null` 的分隔条分支
//   237,239,240              非 Android 平台导航项右侧的 chevron 箭头
//   275,276,277              `_closeDrawerAndPushPage` 中 onOpenPage 为空时的回退推页
//
// 本文件打**可覆盖**的 6 行（237/239/240 + 275/276/277），剩 6 行（213–218）是
// 死代码，见文件末尾「不可覆盖说明」。
//
// 关键点：
//   * flutter_test 默认 `defaultTargetPlatform == TargetPlatform.android`，
//     所以 chevron 分支（237–240）在旧用例里一直打不到。用具例体内
//     try/finally 切换 `debugDefaultTargetPlatformOverride` 到 iOS 即可覆盖。
//   * 旧 gap 用例恒传 onOpenPage ⇒ 永远走 `unawaited(opener(page))`；本轮改用
//     不传 onOpenPage 的抽屉，命中 `navigator.push(...)` 回退（275–278）。
//
// 只读 lib，零产品代码改动。
// ============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/widgets/app_drawer.dart';

/// 假仓库：`watchLibraries()` 返回一条**永不发事件**的广播流，
/// 让 AuthNotifier._init 的 `.first` 悬停（既不报错也不建 drift 实例）。
class _MockLibraryRepository extends Mock implements LibraryRepository {
  final StreamController<List<MusicLibrary>> ctrl =
      StreamController<List<MusicLibrary>>.broadcast();

  @override
  Stream<List<MusicLibrary>> watchLibraries() => ctrl.stream;
}

final List<Widget> _openedPages = <Widget>[];
Future<void> Function(Widget)? _onOpenPage;

final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

Widget _drawerBody(BuildContext context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: AppDrawer(onOpenPage: _onOpenPage),
    );

/// AppDrawer 必须挂在真正的 `Drawer`（独立路由）里：`onSelected` 会
/// `Navigator.pop()`，直接挂根路由 body 会把整棵树弹掉。
GoRouter _routerFor() => GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (BuildContext context, GoRouterState state) => MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            theme: AppTheme.light(),
            home: Scaffold(
              key: _scaffoldKey,
              appBar: AppBar(title: const Text('PLACEHOLDER_HOME')),
              drawer: Drawer(width: 320, child: _drawerBody(context)),
              body: const Text('PLACEHOLDER_BODY'),
            ),
          ),
        ),
      ],
    );

Future<void> _pump(
  WidgetTester tester, {
  Future<void> Function(Widget page)? onOpenPage,
}) async {
  _onOpenPage = onOpenPage;
  _openedPages.clear();

  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 800);
  addTearDown(tester.view.reset);

  final repo = _MockLibraryRepository();
  // ⚠️ 刻意**不 close** repo.ctrl：AuthNotifier._init 会 await
  // watchLibraries().first，收尾时 close 会让这个 pending 的 first 以
  // StateError 落地、继而在 dispose 之后写 state，触发
  // "Tried to use AuthNotifier after dispose" 的假失败。

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWith((ref) => repo),
        activeAddressProvider.overrideWith((ref) => null),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        routerConfig: _routerFor(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  _scaffoldKey.currentState!.openDrawer();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('非 Android 平台导航项保留 chevron 箭头', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pump(tester);
      expect(
        find.byIcon(AppIcons.chevronRight),
        findsWidgets,
        reason: 'iOS 端侧边栏应保留向右箭头（237–240）',
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('未提供 onOpenPage 时回退为直接 push 页面', (tester) async {
    // 不传 onOpenPage ⇒ opener == null ⇒ 走 275–277 的 navigator.push 回退。
    await _pump(tester);

    final entry = find.bySemanticsLabel('艺术家');
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ArtistListPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提供 onOpenPage 时不走回退 push，改由回调接管', (tester) async {
    await _pump(
      tester,
      onOpenPage: (Widget page) async {
        _openedPages.add(page);
      },
    );

    await tester.tap(find.bySemanticsLabel('专辑'));
    await tester.pumpAndSettle();

    expect(_openedPages, isNotEmpty);
    // 回退分支没有把页面推到根导航器。
    expect(find.byType(ArtistListPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // 不可覆盖说明（死代码，如需覆盖必须先改 lib，本轮铁律不改）：
  //   * 213–218 `_buildNavigationList` 里 `entries[index] == null` 的分隔条
  //     分支：`entries` 是 `<_DrawerNavigationEntry?>` 但**只塞了 7 个非空项**，
  //     从不含 null ⇒ `entry == null` 永不成立，整段是死代码。建议删掉可空
  //     类型或补一个真实的分隔项。
  // -------------------------------------------------------------------------
}
