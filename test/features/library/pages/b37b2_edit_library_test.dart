// b37b2 —— `lib/features/library/pages/edit_library_page.dart` 残余分支补测。
//
// edit_library_page_coverage_test.dart 已覆盖表单校验 / 凭据判定 / 扩展清洗 /
// 地址增删改 / 重排 / 删除库等 29 例。本文件补：
//   * libraries 流 error → 错误态 + 点「重试」触发 invalidate（不抛）；
//   * isActive 库的「探测全部」动作按钮 → addressPool.probeAll 被调用。
// 产品代码零改动；仅新增 test/。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/library/pages/edit_library_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

class _MockLibraryRepository extends Mock implements LibraryRepository {}

class _MockAuthRepository extends Mock implements AuthRepository {}

class _StubAddressPool extends AddressPool {
  _StubAddressPool(super.dio);

  int probeCalls = 0;

  @override
  Future<ServerAddress?> probeAll() async {
    probeCalls += 1;
    return null;
  }
}

final DateTime _now = DateTime(2026, 1, 1);
const String _libId = 'library-1';

ServerAddress addr({
  String id = 'addr-1',
  String label = '主服务器',
  String url = 'https://primary.example',
  int priority = 0,
  ServerAddressStatus status = ServerAddressStatus.ok,
  int? latencyMs = 24,
}) =>
    ServerAddress(
      id: id,
      libraryId: _libId,
      label: label,
      url: url,
      priority: priority,
      lastLatencyMs: latencyMs,
      status: status,
    );

MusicLibrary lib({
  String id = _libId,
  String name = '主库',
  bool isActive = true,
  List<ServerAddress> addresses = const <ServerAddress>[],
}) =>
    MusicLibrary(
      id: id,
      name: name,
      isActive: isActive,
      addresses: addresses,
      createdAt: _now,
      updatedAt: _now,
    );

Finder _iconButton(String label) => find.byWidgetPredicate(
      (Widget w) => w is MusicFlowIconButton && w.label == label,
    );

Future<void> pumpPage(
  WidgetTester tester, {
  required Stream<List<MusicLibrary>> Function() buildStream,
  // ignore: library_private_types_in_public_api
  required _MockLibraryRepository libraryRepository,
  // ignore: library_private_types_in_public_api
  required _MockAuthRepository authRepository,
  // ignore: library_private_types_in_public_api
  required _StubAddressPool pool,
  Size size = const Size(900, 1400),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final router = GoRouter(
    initialLocation: '/library/edit/$_libId',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Center(child: Text('home'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'library/edit/:id',
            builder: (_, state) =>
                EditLibraryPage(libraryId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const Scaffold(body: Center(child: Text('login'))),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        librariesProvider.overrideWith((ref) => buildStream()),
        libraryRepositoryProvider.overrideWithValue(libraryRepository),
        authRepositoryProvider.overrideWithValue(authRepository),
        addressPoolProvider.overrideWithValue(pool),
        activeAddressProvider.overrideWith(
          (ref) => addr(id: 'addr-1', label: '活动地址'),
        ),
      ],
      child: MaterialApp.router(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    registerFallbackValue(addr());
    registerFallbackValue(lib());
  });

  testWidgets('libraries 流 error → 错误态 + 重试触发 invalidate 不抛', (tester) async {
    final libRepo = _MockLibraryRepository();
    final authRepo = _MockAuthRepository();
    final pool = _StubAddressPool(Dio());
    when(() => libRepo.watchLibraries()).thenAnswer(
      (_) => Stream<List<MusicLibrary>>.error(StateError('boom')),
    );

    await pumpPage(
      tester,
      buildStream: () => Stream<List<MusicLibrary>>.error(StateError('boom')),
      libraryRepository: libRepo,
      authRepository: authRepo,
      pool: pool,
    );

    expect(find.byType(MusicFlowErrorState), findsWidgets);
    final loc = AppLocalizations.of(tester.element(find.byType(MusicFlowErrorState).first));
    await tester.tap(find.text(loc.widgets_retry));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('isActive 库：点「探测全部」→ addressPool.probeAll 被调用', (tester) async {
    final libRepo = _MockLibraryRepository();
    final authRepo = _MockAuthRepository();
    final pool = _StubAddressPool(Dio());

    await pumpPage(
      tester,
      buildStream: () => Stream<List<MusicLibrary>>.value(<MusicLibrary>[
        lib(isActive: true, addresses: <ServerAddress>[addr()]),
      ]),
      libraryRepository: libRepo,
      authRepository: authRepo,
      pool: pool,
    );

    final loc = AppLocalizations.of(tester.element(find.byType(EditLibraryPage)));
    final probe = _iconButton(loc.library_edit_probe_all);
    expect(probe, findsOneWidget, reason: 'isActive 库才显示「探测全部」');
    await tester.tap(probe);
    await tester.pumpAndSettle();
    expect(pool.probeCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('非 isActive 库：不显示「探测全部」', (tester) async {
    final libRepo = _MockLibraryRepository();
    final authRepo = _MockAuthRepository();
    final pool = _StubAddressPool(Dio());

    await pumpPage(
      tester,
      buildStream: () => Stream<List<MusicLibrary>>.value(<MusicLibrary>[
        lib(isActive: false, addresses: <ServerAddress>[addr()]),
      ]),
      libraryRepository: libRepo,
      authRepository: authRepo,
      pool: pool,
    );

    final loc = AppLocalizations.of(tester.element(find.byType(EditLibraryPage)));
    expect(_iconButton(loc.library_edit_probe_all), findsNothing);
  });
}
