// batch40 E3：D-012 诊断 + 修复锁定用例。
//
// 台账观测：库列表 error 分支的「重试」是死按钮 ——
//   `onAction: () => ref.invalidate(librariesProvider)` 从 onPressed 回调调用后
//   无任何可观测变化（连 AsyncLoading 骨架屏都不闪现）。
//
// 本文件用两种流模型做对照实验：
//   A) 单 broadcast controller（复刻守卫用例的 TestLibraryRepository 模型）：
//      invalidate 重建 provider 后会重新订阅同一个 ctrl，但没有新事件。
//      修复后的可观测行为：点重试必须立刻出现骨架屏（AsyncLoading），
//      且后续向 ctrl 发数据能恢复列表。
//   B) 每次 watchLibraries() 返回新流（贴近真实 drift 每次新建查询流）：
//      点重试必须让 watchCalls +1，且新流首帧数据直接恢复列表。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicflow_client/core/design/components/music_flow_skeleton.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/widgets/app_drawer.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_drawer.dart';

AppDatabase? _sharedDb;
AppDatabase get _db => _sharedDb ??= AppDatabase();

/// 模型 A：所有重订阅共享同一个 broadcast ctrl。
class SingleCtrlRepo extends LibraryRepository {
  SingleCtrlRepo() : super(_db);

  final StreamController<List<MusicLibrary>> watchCtrl =
      StreamController<List<MusicLibrary>>.broadcast();
  int watchCalls = 0;

  @override
  Stream<List<MusicLibrary>> watchLibraries() {
    watchCalls++;
    return watchCtrl.stream;
  }
}

/// 模型 B：每次调用创建新 ctrl（贴近真实 drift 查询流）。
class MultiCtrlRepo extends LibraryRepository {
  MultiCtrlRepo() : super(_db);

  int watchCalls = 0;
  final List<StreamController<List<MusicLibrary>>> ctrls =
      <StreamController<List<MusicLibrary>>>[];

  StreamController<List<MusicLibrary>> get lastCtrl => ctrls.last;

  @override
  Stream<List<MusicLibrary>> watchLibraries() {
    watchCalls++;
    final c = StreamController<List<MusicLibrary>>.broadcast();
    ctrls.add(c);
    return c.stream;
  }
}

MusicLibrary _lib(String id, {String name = '主库', bool isActive = true}) =>
    MusicLibrary(
      id: id,
      name: name,
      isActive: isActive,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      addresses: <ServerAddress>[
        ServerAddress(
          id: 'a1',
          libraryId: id,
          label: '线路 a1',
          url: 'http://a1.local',
          priority: 0,
          status: ServerAddressStatus.ok,
        ),
      ],
    );

final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

Widget _drawerBody(BuildContext context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: AppDrawer(),
    );

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
              builder: (BuildContext context, WidgetRef ref, Widget? child) =>
                  Scaffold(
                key: _scaffoldKey,
                appBar: AppBar(title: const Text('PLACEHOLDER_HOME')),
                drawer: Drawer(width: 320, child: _drawerBody(context)),
                body: Text(
                  'ACTIVE=${ref.watch(authStateProvider).currentLibrary?.username ?? '-'}',
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/login',
          builder: (BuildContext context, GoRouterState state) =>
              const MaterialApp(
            home: Scaffold(body: Center(child: Text('PLACEHOLDER_LOGIN'))),
          ),
        ),
      ],
    );

Future<void> _pump(
  WidgetTester tester, {
  required LibraryRepository repo,
  required List<Override> extraOverrides,
}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('path_provider'),
          (MethodCall call) async {
    if (call.method == 'getApplicationDocumentsDirectory') {
      return <String, Object?>{'path': '/tmp/mf_b40e3_drawer_retry'};
    }
    return null;
  });

  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 800);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        libraryRepositoryProvider.overrideWith((ref) => repo),
        activeAddressProvider.overrideWith((ref) => null),
        ...extraOverrides,
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

  // 展开库列表（折叠态不读 librariesProvider）。
  await tester.tap(find.bySemanticsLabel('查看音乐库'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('A: 单 ctrl 模型 — 点重试立即骨架反馈，流恢复后列表恢复(D-012)',
      (tester) async {
    final repo = SingleCtrlRepo();
    await _pump(tester, repo: repo, extraOverrides: const <Override>[]);

    repo.watchCtrl.addError(StateError('watch boom'));
    await tester.pumpAndSettle();
    expect(find.text('无法读取音乐库'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    // [D-012 已修复] 点重试立即有可观测反馈：退出错误态、骨架屏在场。
    expect(find.text('无法读取音乐库'), findsNothing,
        reason: '[D-012 已修复] 点重试立即退出错误态');
    expect(find.byType(MusicFlowSkeleton), findsWidgets,
        reason: '[D-012 已修复] 重试有加载反馈');

    // 重试窗口（800ms）内流无新事件 → 回到错误态，可再次重试。
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('无法读取音乐库'), findsOneWidget,
        reason: '[D-012 已修复] 流未恢复时回到错误态（不再无限骨架）');

    // 流恢复事件到达 → 列表正常渲染。
    repo.watchCtrl.add(<MusicLibrary>[_lib('lib-1')]);
    await tester.pumpAndSettle();
    expect(find.text('主库'), findsOneWidget,
        reason: '[D-012 已修复] 重订阅后数据事件恢复列表');
  });

  testWidgets('B: 新流模型 — 点重试重新拉流，新流数据直接恢复', (tester) async {
    final repo = MultiCtrlRepo();
    await _pump(tester, repo: repo, extraOverrides: const <Override>[]);

    repo.lastCtrl.addError(StateError('watch boom'));
    await tester.pumpAndSettle();
    expect(find.text('无法读取音乐库'), findsOneWidget);

    final callsBefore = repo.watchCalls;
    await tester.tap(find.text('重试'));
    await tester.pump();


    expect(repo.watchCalls, greaterThan(callsBefore),
        reason: '[D-012 修复] 点重试必须重新执行 watchLibraries()（provider 重建）');

    repo.lastCtrl.add(<MusicLibrary>[_lib('lib-1')]);
    // 走完 800ms 重试窗口 Timer，避免用例结束时遗留 pending timers。
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    expect(find.text('主库'), findsOneWidget,
        reason: '[D-012 修复] 新流数据应恢复列表');
    expect(find.text('无法读取音乐库'), findsNothing);
  });
}
