import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/auth/pages/login_page.dart';
import 'package:musicflow_client/features/library/pages/edit_library_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/features/settings/pages/theme_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 页面冒烟:不验证业务,只锁「构建不抛异常 + 骨架渲染出来」,
/// 把这些 0% 覆盖的页面纳入回归网(后续改动崩了立刻红)。
///
/// 两个坑位说明:
/// 1. 页面里会调 `context.go(...)`(登录成功跳转/返回上一页),测试树里必须真的有
///    **GoRouter 控件**(不是 MaterialApp.router 的 routerConfig)——go_router 的
///    `_GoRouterState.of()` 是从树上 findAncestorStateOfType 的,只有把 GoRouter
///    当根挂上去才成立,否则直接 `No GoRouter found in context` 断言失败。
/// 2. 部分页面开局会拉数据转圈(pumpAndSettle 永远等不到静止),所以这里用**有界
///    pump 循环**代替 pumpAndSettle:既把首帧渲染完,又不被转圈超时炸掉。
Future<dynamic> pumpPage(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final GoRouter router = GoRouter(
    initialLocation: '/smoke',
    routes: <RouteBase>[
      GoRoute(
        path: '/smoke',
        builder: (BuildContext context, GoRouterState state) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(body: child),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    ),
  );

  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return tester.takeException();
}

void main() {
  group('页面冒烟-零参数页面', () {
    testWidgets('LoginPage 可构建且无渲染异常', (tester) async {
      final error = await pumpPage(tester, const LoginPage());
      expect(error, isNull);
      expect(find.byType(Scaffold), findsWidgets);
    });

    testWidgets('ThemeSettingsPage 可构建且无渲染异常', (tester) async {
      final error = await pumpPage(tester, const ThemeSettingsPage());
      expect(error, isNull);
      expect(find.byType(Scaffold), findsWidgets);
    });

    testWidgets('AppSettingsPage 可构建且无渲染异常', (tester) async {
      final error = await pumpPage(tester, const AppSettingsPage());
      expect(error, isNull);
      expect(find.byType(Scaffold), findsWidgets);
    });

    testWidgets('StarredPage 可构建且无渲染异常', (tester) async {
      final error = await pumpPage(tester, const StarredPage());
      expect(error, isNull);
      expect(find.byType(Scaffold), findsWidgets);
    });

    testWidgets('StarredPage(收藏曲目 tab) 可构建且无渲染异常', (tester) async {
      final error =
          await pumpPage(tester, const StarredPage(initialTab: StarredTab.songs));
      expect(error, isNull);
      expect(find.byType(Scaffold), findsWidgets);
    });

    testWidgets('PlayerTransferPage 可构建且无渲染异常', (tester) async {
      final error = await pumpPage(
        tester,
        const PlayerTransferPage(onTransfer: _dummyTransfer),
      );
      expect(error, isNull);
      expect(find.byType(Scaffold), findsWidgets);
    });

    testWidgets('EditLibraryPage 可构建且无渲染异常', (tester) async {
      final error = await pumpPage(tester, const EditLibraryPage(libraryId: '1'));
      expect(error, isNull);
      expect(find.byType(Scaffold), findsWidgets);
    });
  });
}

/// 流转回调桩:永不执行成功路径,仅为了满足构造函数签名。
Future<bool> _dummyTransfer(PeerInfo from, PeerInfo to) async => false;
