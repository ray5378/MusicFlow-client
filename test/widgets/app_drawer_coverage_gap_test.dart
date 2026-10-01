import 'dart:async';

import 'package:flutter/services.dart';

import 'package:musicflow_client/core/design/components/music_flow_bottom_sheet.dart';
import 'package:musicflow_client/core/design/components/music_flow_skeleton.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/features/settings/pages/offline_cached_songs_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/widgets/app_drawer.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 整个测试文件共用一个真实 drift 实例(避免 drift 的「重复创建数据库」告警)。
AppDatabase? _sharedDb;

// 假仓库：只暴露可控的 [watchCtrl] 与 [activeCalls]，不碰真实 drift 表。
class TestLibraryRepository extends LibraryRepository {
  TestLibraryRepository() : super(_db);

  final StreamController<List<MusicLibrary>> watchCtrl =
      StreamController<List<MusicLibrary>>.broadcast();
  final List<String> activeCalls = <String>[];

  @override
  Stream<List<MusicLibrary>> watchLibraries() => watchCtrl.stream;

  @override
  Future<void> setActiveLibrary(String id) async {
    activeCalls.add(id);
  }
}

AppDatabase get _db => _sharedDb ??= AppDatabase();

final List<Widget> _openedPages = <Widget>[];
Future<void> Function(Widget)? _onOpenPage;
ServerAddress? _address;

ServerAddress _addr(String id, ServerAddressStatus status) => ServerAddress(
  id: id,
  libraryId: 'lib-1',
  label: '线路 $id',
  url: 'http://$id.local',
  priority: 0,
  status: status,
);

MusicLibrary _lib(
  String id, {
  String name = '音乐库',
  String? username,
  bool isActive = false,
  List<ServerAddress> addresses = const <ServerAddress>[],
  Map<String, Object?> extensions = const <String, Object?>{},
}) =>
    MusicLibrary(
      id: id,
      name: name,
      username: username,
      isActive: isActive,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      addresses: addresses,
      extensions: extensions,
    );

// 骨架屏 shimmer 会 repeat 动画导致 pumpAndSettle 永不静止，
// 这里关掉动效。⚠️ 必须基于上下文现有 MediaQuery 复制：直接写
// `MediaQueryData(disableAnimations: true)` 会让 size 退化成 0×0，
// 整个抽屉被压扁(导航只渲染出 6 行、点击全部落空)。
Widget _drawerBody(BuildContext context) => MediaQuery(
  data: MediaQuery.of(context).copyWith(disableAnimations: true),
  child: AppDrawer(onOpenPage: _onOpenPage),
);

/// ⚠️ 每个用例都要**新建一个** GoRouter：这些用例会走 `_closeDrawerAndPushLocation`
/// 把 `/login?add=true` 或 `/library/edit/:id` push 出去(且落在 post-frame 回调里)，
/// 共享一个单例 router 会让上一次的路由状态泄漏到下一个用例(开屏就已经在
/// /login 上，抽屉根本没渲染，`查看音乐库` 点不到)。
/// 基础路由的 [Scaffold] 用 key 打开抽屉。⚠️ AppDrawer 必须挂在真正的
/// `Drawer`(独立路由)里：它的 `onSelected` 会 `Navigator.pop()`，若直接挂在
/// 根路由的 body 上，pop 会把根路由一起弹掉、整棵树被卸载，之后任何断言都找不到东西。
final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

GoRouter _routerFor() => GoRouter(
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      builder: (BuildContext context, GoRouterState state) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? child) => Scaffold(
            key: _scaffoldKey,
            appBar: AppBar(title: const Text('PLACEHOLDER_HOME')),
            drawer: Drawer(width: 320, child: _drawerBody(context)),
            body: Text('ACTIVE=${ref.watch(authStateProvider).currentLibrary?.username ?? '-'}'),
          ),
        ),
      ),
    ),
    GoRoute(
      path: '/login',
      builder: (BuildContext context, GoRouterState state) =>
          const MaterialApp(home: Scaffold(body: Center(child: Text('PLACEHOLDER_LOGIN')))),
    ),
    GoRoute(
      path: '/library/edit/:id',
      builder: (BuildContext context, GoRouterState state) => MaterialApp(
        home: Scaffold(
          body: Center(child: Text('PLACEHOLDER_EDIT_${state.pathParameters['id']}')),
        ),
      ),
    ),
  ],
);

/// 将 [libraries] 推给假仓库。
///
/// ⚠️ **必须在展开之后调用**：折叠态下 AppDrawer 不读 `librariesProvider`，
/// 没有任何订阅者，broadcast 流里的事件会被直接丢弃(表现为永远停在骨架屏)。
Future<TestLibraryRepository> _pushLibraries(
  WidgetTester tester,
  TestLibraryRepository repo,
  List<MusicLibrary> libraries,
) async {
  repo.watchCtrl.add(libraries);
  await tester.pumpAndSettle();
  return repo;
}

/// 启动应用并(可选)展开库列表。
///
/// 注意:这里刻意**不 close** watchCtrl —— AuthNotifier._init 会 await
/// watchLibraries().first 并把 state 写回;若在测试收尾时 close 掉控制器,
/// 那个 pending 的 first 会以 StateError 落地,继而在 dispose 之后写 state,
/// 触发 "Tried to use AuthNotifier after dispose" 的假失败。
Future<TestLibraryRepository> _pump(
  WidgetTester tester, {
  ServerAddress? address,
  Future<void> Function(Widget page)? onOpenPage,
  bool expand = false,
}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('path_provider'),
    (MethodCall call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return <String, Object?>{'path': '/tmp/mf_app_drawer_test'};
      }
      return null;
    },
  );

  _onOpenPage = onOpenPage;
  _address = address;
  _openedPages.clear();
  final TestLibraryRepository repo = TestLibraryRepository();

  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 800);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWith((ref) => repo),
        activeAddressProvider.overrideWith((ref) => _address),
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

  // 打开抽屉：AppDrawer 本体在 Drawer 路由里。
  _scaffoldKey.currentState!.openDrawer();
  await tester.pumpAndSettle();

  if (expand) {
    await _expand(tester);
  }
  return repo;
}

/// 展开库列表(默认折叠态只渲染导航)。
Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('查看音乐库'));
  await tester.pumpAndSettle();
}

void main() {
  group('头像地址解析', () {
    test('非法/空头像返回 null，绝对地址原样保留', () {
      expect(resolveMusicFlowDrawerAvatarUrl(null), isNull);
      expect(resolveMusicFlowDrawerAvatarUrl(_lib('lib-1')), isNull);
      expect(
        resolveMusicFlowDrawerAvatarUrl(
          _lib('lib-1', extensions: <String, Object?>{'avatarUrl': '   '}),
        ),
        isNull,
      );
      expect(
        resolveMusicFlowDrawerAvatarUrl(
          _lib('lib-1', extensions: <String, Object?>{'avatarUrl': 42}),
        ),
        isNull,
      );
      expect(
        resolveMusicFlowDrawerAvatarUrl(
          _lib('lib-1', extensions: <String, Object?>{'avatarUrl': 'navidrome.local/avatar.png'}),
        ),
        isNull,
      );
      expect(
        resolveMusicFlowDrawerAvatarUrl(
          _lib('lib-1', extensions: <String, Object?>{'avatarUrl': '/avatar/1.png'}),
        ),
        '/avatar/1.png',
      );
      expect(
        resolveMusicFlowDrawerAvatarUrl(
          _lib('lib-1', extensions: <String, Object?>{'avatarUrl': ' https://cdn/x.png '}),
        ),
        'https://cdn/x.png',
      );
    });
  });

  group('身份头部连接状态', () {
    testWidgets('没有活动线路时显示未连接与未选择', (tester) async {
      await _pump(tester);

      expect(
        find.bySemanticsLabel('当前账户 Guest，音乐库 未选择，未连接，没有活动线路'),
        findsOneWidget,
      );
    });

    testWidgets('地址探测成功渲染连接正常', (tester) async {
      await _pump(tester, address: _addr('a1', ServerAddressStatus.ok));

      expect(find.text('连接正常 · 线路 a1'), findsOneWidget);
    });

    testWidgets('地址探测失败渲染连接失败', (tester) async {
      await _pump(tester, address: _addr('a1', ServerAddressStatus.failed));

      expect(find.text('连接失败 · 线路 a1'), findsOneWidget);
    });

    testWidgets('地址尚未探测渲染等待检测', (tester) async {
      await _pump(tester, address: _addr('a1', ServerAddressStatus.unknown));

      expect(find.text('等待检测 · 线路 a1'), findsOneWidget);
    });
  });

  group('导航列表', () {
    testWidgets('默认渲染七项导航且不出现库行', (tester) async {
      await _pump(tester);

      expect(find.byType(MusicFlowDrawerLibraryRow), findsNothing);
      expect(find.byType(MusicFlowSkeleton), findsNothing);
      for (final String title in <String>[
        '艺术家',
        '专辑',
        '歌曲',
        '歌单',
        '喜欢',
        '已缓存音乐',
        '设置',
      ]) {
        expect(find.text(title), findsOneWidget, reason: '缺导航项 $title');
      }
      expect(find.byType(MusicFlowActionRow), findsNWidgets(7));
    });

    testWidgets('七项导航各自把对应页面交给 onOpenPage', (tester) async {
      final List<MapEntry<String, Object>> expected = <MapEntry<String, Object>>[
        const MapEntry<String, Object>('艺术家', ArtistListPage),
        const MapEntry<String, Object>('专辑', AlbumListPage),
        const MapEntry<String, Object>('歌曲', SongListPage),
        const MapEntry<String, Object>('歌单', PlaylistSearchPage),
        const MapEntry<String, Object>('喜欢', StarredPage),
        const MapEntry<String, Object>('已缓存音乐', OfflineCachedSongsPage),
        const MapEntry<String, Object>('设置', AppSettingsPage),
      ];

      for (final MapEntry<String, Object> entry in expected) {
        await _pump(
          tester,
          onOpenPage: (Widget page) async {
            _openedPages.add(page);
          },
        );

        // ⚠️ 打开走 post-frame 回调(pop 之后)，必须 pumpAndSettle 才能落地。
        await tester.tap(find.bySemanticsLabel(entry.key));
        await tester.pumpAndSettle();

        expect(_openedPages, isNotEmpty, reason: '${entry.key} 未触发 onOpenPage');
        expect(_openedPages.removeLast().runtimeType, entry.value);
      }
    });
  });

  group('库列表展开/折叠', () {
    testWidgets('展开后显示库行并隐藏导航项，再点返回恢复导航', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      await _pushLibraries(
        tester,
        repo,
        <MusicLibrary>[_lib('lib-1', name: '主库', isActive: true, addresses: <ServerAddress>[_addr('a1', ServerAddressStatus.ok)])],
      );

      expect(find.byType(MusicFlowDrawerLibraryRow), findsOneWidget);
      expect(find.bySemanticsLabel('艺术家'), findsNothing);
      expect(find.bySemanticsLabel('返回应用功能菜单'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('返回应用功能菜单'));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('艺术家'), findsOneWidget);
      expect(find.byType(MusicFlowDrawerLibraryRow), findsNothing);
    });
  });

  group('库列表三态', () {
    testWidgets('展开后未推数据前渲染骨架屏', (tester) async {
      await _pump(tester, expand: true);

      expect(find.byType(MusicFlowDrawerLibraryRow), findsNothing);
      expect(find.byType(MusicFlowSkeleton), findsWidgets);
      expect(find.bySemanticsLabel('艺术家'), findsNothing);
    });

    testWidgets('空库列表渲染空态，点添加走路由 /login?add=true', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      await _pushLibraries(tester, repo, <MusicLibrary>[]);

      expect(find.text('还没有音乐库'), findsOneWidget);
      expect(find.byType(MusicFlowDrawerLibraryRow), findsNothing);

      await tester.tap(find.text('添加音乐库'));
      await tester.pumpAndSettle();

      expect(find.text('PLACEHOLDER_LOGIN'), findsOneWidget);
    });

    testWidgets('拉取失败渲染错误态，重试后重新订阅并恢复列表', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      repo.watchCtrl.addError(StateError('watch boom'));
      await tester.pumpAndSettle();

      expect(find.text('无法读取音乐库'), findsOneWidget);
      expect(find.byType(MusicFlowDrawerLibraryRow), findsNothing);

      // ⚠️ [D-012] 已知缺陷(守卫用例)：点「重试」后错误态不会恢复。
      // `onAction` 里的 `ref.invalidate(librariesProvider)` 从 onPressed 回调调用后
      // 没有任何可观测的状态变化；重新订阅(折叠再展开)也仍然停在错误态。
      // 修复后这条断言必须翻转（错误态 -> 骨架屏）。
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('无法读取音乐库'), findsOneWidget);
      expect(find.byType(MusicFlowSkeleton), findsNothing);

      await tester.tap(find.bySemanticsLabel('返回应用功能菜单'));
      await tester.pumpAndSettle();
      await _expand(tester);

      expect(find.text('无法读取音乐库'), findsOneWidget);

      await _pushLibraries(
        tester,
        repo,
        <MusicLibrary>[_lib('lib-1', name: '主库', isActive: true, addresses: <ServerAddress>[_addr('a1', ServerAddressStatus.ok)])],
      );

      expect(find.text('无法读取音乐库'), findsNothing);
      expect(find.byType(MusicFlowDrawerLibraryRow), findsOneWidget);
    });

    testWidgets('底部添加新音乐库行走路由 /login?add=true', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      await _pushLibraries(
        tester,
        repo,
        <MusicLibrary>[_lib('lib-1', name: '主库', isActive: true, addresses: <ServerAddress>[_addr('a1', ServerAddressStatus.ok)])],
      );

      expect(find.byType(MusicFlowActionRow), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('添加新音乐库，连接另一台服务器或另一个账户'));
      await tester.pumpAndSettle();

      expect(find.text('PLACEHOLDER_LOGIN'), findsOneWidget);
    });
  });

  group('切换音乐库', () {
    testWidgets('点非当前库会落库、切身份并收起列表', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      await _pushLibraries(
        tester,
        repo,
        <MusicLibrary>[
          _lib(
            'lib-1',
            name: '主库',
            username: 'listener-a',
            isActive: true,
            addresses: <ServerAddress>[_addr('a1', ServerAddressStatus.ok)],
          ),
          _lib(
            'lib-2',
            name: '副库',
            username: 'listener-b',
            addresses: <ServerAddress>[_addr('a2', ServerAddressStatus.ok)],
          ),
        ],
      );

      await tester.tap(find.bySemanticsLabel('副库，http://a2.local'));
      await tester.pumpAndSettle();

      // 落库到仓库 + 身份切到新账户(基础路由的 ACTIVE 文本可读到)。
      expect(repo.activeCalls, <String>['lib-2']);
      expect(find.text('ACTIVE=listener-b'), findsOneWidget);
      // onSelected 收起抽屉：库行随 Drawer 路由一起被卸载。
      expect(find.byType(MusicFlowDrawerLibraryRow), findsNothing);
    });

    testWidgets('点当前库不重复落库', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      await _pushLibraries(
        tester,
        repo,
        <MusicLibrary>[
          _lib(
            'lib-1',
            name: '主库',
            isActive: true,
            addresses: <ServerAddress>[_addr('a1', ServerAddressStatus.ok)],
          ),
        ],
      );

      await tester.tap(find.bySemanticsLabel('主库，http://a1.local，当前音乐库'));
      await tester.pumpAndSettle();

      expect(repo.activeCalls, isEmpty);
    });

    testWidgets('库行没有地址时回退为「未配置服务器地址」', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      await _pushLibraries(
        tester,
        repo,
        <MusicLibrary>[_lib('lib-1', name: '无地址库', isActive: true)],
      );

      expect(find.text('未配置服务器地址'), findsOneWidget);
    });

    testWidgets('点库行编辑走路由 /library/edit/:id', (tester) async {
      final TestLibraryRepository repo = await _pump(tester, expand: true);
      await _pushLibraries(
        tester,
        repo,
        <MusicLibrary>[
          _lib(
            'lib-1',
            name: '主库',
            isActive: true,
            addresses: <ServerAddress>[_addr('a1', ServerAddressStatus.ok)],
          ),
        ],
      );

      await tester.tap(find.bySemanticsLabel('编辑 主库'));
      await tester.pumpAndSettle();

      expect(find.text('PLACEHOLDER_EDIT_lib-1'), findsOneWidget);
    });
  });
}

