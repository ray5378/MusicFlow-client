// b38c3 —— login_page.dart 剩余可达分支补测（Route C）。
//
// 两处缺口都是「键盘提交动作」回调体：
//   * line 289 地址标签框 `onSubmitted: (_) => _detectServer()`；
//   * line 405 密码框 `onSubmitted: (_) => _login()`。
// 既有用例一律点「下一步 / 登录」按钮，从未对输入框提交软键盘动作。
//
// 走真实 LoginPage + 真实 AuthNotifier，仓库换可编排假实现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/auth/pages/login_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:mocktail/mocktail.dart';

ServerCapabilities _caps({required bool supportsApiKey}) => ServerCapabilities(
      isOpenSubsonic: true,
      serverType: 'Subsonic',
      supportsApiKey: supportsApiKey,
    );

Future<void> _enter(WidgetTester tester, int index, String text) async {
  await tester.enterText(find.byType(TextField).at(index), text);
  await tester.pump();
}

Future<_LoginHarness> _pumpLogin(
  WidgetTester tester, {
  required ServerCapabilities capabilities,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1080, 1800);
  addTearDown(tester.view.reset);

  final repository = _FakeAuthRepository(capabilities: capabilities);
  final libraryRepository = FakeLibraryRepository();
  when(() => libraryRepository.watchLibraries()).thenAnswer(
    (_) => Stream<List<MusicLibrary>>.value(const <MusicLibrary>[]),
  );

  final container = ProviderContainer(
    overrides: <Override>[
      authRepositoryProvider.overrideWithValue(repository),
      libraryRepositoryProvider.overrideWithValue(libraryRepository),
      authStateProvider.overrideWith(
        (ref) => AuthNotifier(repository, libraryRepository),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: '/login',
    routes: <RouteBase>[
      GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
      GoRoute(
        path: '/home',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('HOME_OK'))),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return _LoginHarness(container: container, repository: repository);
}

void main() {
  testWidgets('地址标签框提交软键盘动作 → 触发服务器检测', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );

    // 第一步三个输入框：服务器地址(0) / 库名(1) / 地址标签(2，done)。
    await _enter(tester, 0, 'https://server.example');
    await _enter(tester, 2, 'Home');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(harness.repository.detected, <String>['https://server.example']);
    // 检测成功 → 进到认证步骤。
    expect(find.text('输入认证信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('密码框提交软键盘动作 → 触发登录链路', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('输入认证信息'), findsOneWidget);

    // 认证步骤：用户名(0) / 密码(1，done)。
    await _enter(tester, 0, 'alice');
    await _enter(tester, 1, 'right-pass');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(harness.repository.loginCalls, <String>['password']);
    expect(find.text('HOME_OK'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// 基础设施（对齐 b29c_login_cov_test）
// ---------------------------------------------------------------------------

class _LoginHarness {
  const _LoginHarness({required this.container, required this.repository});

  final ProviderContainer container;
  final _FakeAuthRepository repository;
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({required this.capabilities});

  final ServerCapabilities capabilities;
  final List<String> detected = <String>[];
  final List<String> loginCalls = <String>[];

  @override
  Future<ServerCapabilities> detectServerCapabilities(String serverUrl) async {
    detected.add(serverUrl);
    return capabilities;
  }

  @override
  Future<LoginResult> loginWithPassword({
    required String serverUrl,
    required String username,
    required String password,
    String? libraryName,
    String? addressLabel,
  }) async {
    loginCalls.add('password');
    return _result();
  }

  @override
  Future<LoginResult> loginWithApiKey({
    required String serverUrl,
    required String username,
    required String apiKey,
    String? libraryName,
    String? addressLabel,
  }) async {
    loginCalls.add('apikey');
    return _result();
  }

  LoginResult _result() => LoginResult(
        success: true,
        library: MusicLibrary(
          id: 'lib-1',
          name: '主库',
          isActive: true,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
}

class FakeLibraryRepository extends Mock implements LibraryRepository {
  @override
  Future<void> addLibrary(MusicLibrary library) async {}

  @override
  Future<void> setActiveLibrary(String id) async {}
}
