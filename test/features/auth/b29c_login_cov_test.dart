import 'dart:async';

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

void main() {
  // ---------------------------------------------------------------------------
  // 服务器地址归一化与校验
  // ---------------------------------------------------------------------------

  testWidgets('检测时会传入归一化后的服务器基地址', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );

    await _enter(tester, 0, '  https://server.example/login/  ');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(harness.repository.detected, <String>['https://server.example']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务器地址为空或非法时拦截检测并给出对应校验文案', (tester) async {
    final harness = await _pumpLogin(tester, capabilities: _caps(supportsApiKey: false));

    await tester.tap(find.text('下一步'));
    await tester.pump();
    expect(find.text('请输入服务器地址'), findsOneWidget);
    expect(harness.repository.detected, isEmpty);

    await _enter(tester, 0, 'not-a-url');
    await tester.tap(find.text('下一步'));
    await tester.pump();
    expect(find.text('请输入完整的 URL（包括 http:// 或 https://）'), findsOneWidget);
    expect(harness.repository.detected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // 第一步 → 第二步 状态机
  // ---------------------------------------------------------------------------

  testWidgets('首屏渲染服务器步骤、步骤指示与下一步按钮', (tester) async {
    await _pumpLogin(tester, capabilities: _caps(supportsApiKey: true));

    expect(find.text('连接到服务器'), findsOneWidget);
    expect(find.text('先确认服务器地址'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('上一步'), findsNothing);
    // 「服务器」出现两处：步骤指示器步骤名 + 第一步区块标题（文案相同）。
    expect(find.text('服务器'), findsNWidgets(2));
    expect(find.text('认证'), findsOneWidget);
    expect(find.bySemanticsLabel('登录进度，第 1 步，共 2 步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('检测中显示状态条且主按钮为检测文案', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
      gateDetect: true,
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pump();

    expect(find.text('正在检测…'), findsOneWidget);
    expect(find.text('正在检测服务器能力'), findsOneWidget);
    expect(harness.repository.detected, <String>['https://server.example']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('检测失败时留在第一步并提示无法连接', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: true),
      throwOnDetect: true,
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('无法连接到服务器，请检查地址是否正确'), findsOneWidget);
    expect(find.text('先确认服务器地址'), findsOneWidget);
    expect(harness.repository.detected, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('上一步可回到服务器步骤且步骤指示前进到第二步', (tester) async {
    await _pumpLogin(tester, capabilities: _caps(supportsApiKey: false));

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('输入认证信息'), findsOneWidget);
    expect(find.bySemanticsLabel('登录进度，第 2 步，共 2 步'), findsOneWidget);

    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('先确认服务器地址'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('上一步'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // 认证步骤的能力分支
  // ---------------------------------------------------------------------------

  testWidgets('OpenSubsonic 能力下渲染检测卡片与 API Key 字段', (tester) async {
    await _pumpLogin(
      tester,
      capabilities: ServerCapabilities(
        isOpenSubsonic: true,
        serverType: 'Subsonic',
        supportsApiKey: true,
      ),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('已检测到 OpenSubsonic'), findsOneWidget);
    expect(find.text('Subsonic'), findsOneWidget);
    expect(find.text('API Key（推荐）'), findsOneWidget);
    expect(find.text('或使用密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不支持 API Key 时隐藏 API Key 字段与分隔文案', (tester) async {
    await _pumpLogin(
      tester,
      capabilities: ServerCapabilities(
        isOpenSubsonic: false,
        serverType: 'Other',
        supportsApiKey: false,
      ),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('已检测到 OpenSubsonic'), findsNothing);
    expect(find.text('API Key（推荐）'), findsNothing);
    expect(find.text('或使用密码'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知服务器类型回退为默认文案', (tester) async {
    await _pumpLogin(
      tester,
      capabilities: ServerCapabilities(
        isOpenSubsonic: true,
        serverType: null,
        supportsApiKey: true,
      ),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('未知服务器类型'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('认证步骤 username 为空时拦截登录', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    // 认证步骤不做任何输入：username / password 均为空 → 拦截在 username。
    await tester.tap(find.text('登录'));
    await tester.pump();

    expect(find.text('请输入用户名'), findsOneWidget);
    expect(harness.repository.loginCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // 登录链路：密码 / API Key / 失败 / 成功
  // ---------------------------------------------------------------------------

  testWidgets('不支持 API Key 时走密码登录链路', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );
    // 让登录失败：留在登录页，断言点就只剩「链路选了哪一条」。
    harness.repository.failLogin = true;
    harness.repository.loginError = '密码错误';

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await _enter(tester, 0, 'alice');
    await _enter(tester, 1, 'secret-pass');

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(harness.repository.loginCalls, <String>['password']);
    expect(find.text('密码错误'), findsOneWidget);
    expect(find.text('HOME_OK'), findsNothing);
    expect(harness.container.read(authStateProvider).isAuthenticated, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('密码为空且无 API Key 时提示密码必填', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await _enter(tester, 0, 'alice');

    await tester.tap(find.text('登录'));
    await tester.pump();

    expect(find.text('请输入密码'), findsOneWidget);
    expect(harness.repository.loginCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('填写 API Key 时走 API Key 登录链路', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: true),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await _enter(tester, 0, 'alice');
    await _enter(tester, 1, 'api-key-123');

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(harness.repository.loginCalls, <String>['apikey']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录失败时提示认证错误并清除错误态', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );
    harness.repository.failLogin = true;
    harness.repository.loginError = '用户名或密码错误';

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await _enter(tester, 0, 'alice');
    await _enter(tester, 1, 'wrong-pass');

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.text('用户名或密码错误'), findsOneWidget);
    // ref.listen 触发 _showError 后紧跟 clearError()。
    expect(harness.container.read(authStateProvider).errorMessage, isNull);
    expect(find.text('HOME_OK'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录进行中主按钮显示登录中并渲染验证状态', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
      gateLogin: true,
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await _enter(tester, 0, 'alice');
    await _enter(tester, 1, 'right-pass');

    await tester.tap(find.text('登录'));
    await tester.pump();

    expect(harness.repository.loginCalls, <String>['password']);
    expect(find.text('正在登录…'), findsOneWidget);
    expect(find.text('正在验证认证信息'), findsOneWidget);

    // 门控着不放行：这里只钉住「登录中」这一态的 UI 与链路痕迹。
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录成功后路由跳到首页且状态机置为已认证', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: false),
    );

    await _enter(tester, 0, 'https://server.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await _enter(tester, 0, 'alice');
    await _enter(tester, 1, 'right-pass');

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(harness.repository.loginCalls, <String>['password']);
    expect(find.text('HOME_OK'), findsOneWidget);
    expect(harness.container.read(authStateProvider).isAuthenticated, isTrue);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // HTTP 不安全确认
  // ---------------------------------------------------------------------------

  testWidgets('HTTP 地址弹出不安全确认，确认后继续检测', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: true),
    );

    await _enter(tester, 0, 'http://192.168.1.20:8118');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('HTTP 连接不安全'), findsOneWidget);
    expect(find.text('仍然继续'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('仍然继续'));
    await tester.pumpAndSettle();

    expect(find.text('HTTP 连接不安全'), findsNothing);
    expect(find.text('输入认证信息'), findsOneWidget);
    expect(harness.repository.detected, <String>['http://192.168.1.20:8118']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTTP 不安全确认点取消则中止检测', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: true),
    );

    await _enter(tester, 0, 'http://192.168.1.20:8118');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('HTTP 连接不安全'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('先确认服务器地址'), findsOneWidget);
    expect(harness.repository.detected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一 HTTP 地址确认过后不再重复弹确认', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: true),
    );

    await _enter(tester, 0, 'http://192.168.1.20:8118');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍然继续'));
    await tester.pumpAndSettle();
    expect(find.text('输入认证信息'), findsOneWidget);

    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('HTTP 连接不安全'), findsNothing);
    expect(find.text('输入认证信息'), findsOneWidget);
    expect(harness.repository.detected, <String>[
      'http://192.168.1.20:8118',
      'http://192.168.1.20:8118',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTTPS 地址不触发不安全确认', (tester) async {
    final harness = await _pumpLogin(
      tester,
      capabilities: _caps(supportsApiKey: true),
    );

    await _enter(tester, 0, 'https://secure.example');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('HTTP 连接不安全'), findsNothing);
    expect(find.text('输入认证信息'), findsOneWidget);
    expect(harness.repository.detected, <String>['https://secure.example']);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // 返回按钮（context.canPop 两分支）
  // ---------------------------------------------------------------------------

  testWidgets('可 pop 的路由里渲染返回按钮', (tester) async {
    await _pumpLoginIn(tester, pushDummyFirst: true);

    expect(find.bySemanticsLabel('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根级不可 pop 的路由里不渲染返回按钮', (tester) async {
    await _pumpLoginIn(tester, pushDummyFirst: false);

    expect(find.bySemanticsLabel('返回'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

// -----------------------------------------------------------------------------
// 基础设施
// -----------------------------------------------------------------------------

ServerCapabilities _caps({required bool supportsApiKey}) => ServerCapabilities(
  isOpenSubsonic: true,
  serverType: 'Subsonic',
  supportsApiKey: supportsApiKey,
);

/// 让出一次事件循环，再收敛所有挂起的帧：给「Future 链 + 帧」的双重推进留
/// 出一个确定的回合，避免断言跑在链路还没走完的半路上。
Future<void> _drain(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, int index, String text) async {
  await tester.enterText(find.byType(TextField).at(index), text);
  await tester.pump();
}

/// 登录页主测试台：go_router 提供 `/login` → `/home` 两条路由；
/// auth / library 两个仓库换成可编排的假实现，登录状态机仍是真实的
/// [AuthNotifier]，这样错误提示与 clearError 链路走的是产品代码。
Future<_LoginHarness> _pumpLogin(
  WidgetTester tester, {
  required ServerCapabilities capabilities,
  bool throwOnDetect = false,
  bool gateDetect = false,
  bool gateLogin = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1080, 1800);
  addTearDown(tester.view.reset);

  final repository = _FakeAuthRepository(capabilities: capabilities);
  repository.throwOnDetect = throwOnDetect;
  repository.gateDetect = gateDetect;
  repository.gateLogin = gateLogin;

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
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('HOME_OK')),
        ),
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

  return _LoginHarness(
    container: container,
    repository: repository,
  );
}

/// 返回按钮两分支用的轻量台架：登录页挂在 go_router 上，可 pop 性由
/// [pushDummyFirst] 显式控制（`/login` 单层 canPop=false，
/// `/login/child` 嵌套一层 canPop=true）。
Future<void> _pumpLoginIn(
  WidgetTester tester, {
  required bool pushDummyFirst,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1080, 1800);
  addTearDown(tester.view.reset);

  final repository = _FakeAuthRepository(capabilities: _caps(supportsApiKey: false));
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

  // LoginPage 的返回按钮读 `context.canPop()`（go_router 扩展），因此必须
  // 由 GoRouter 提供上下文。嵌套一层子路由即可造出「可 pop / 不可 pop」两态：
  // /login 只有一层匹配 → canPop=false；/login/child 有两层 → canPop=true。
  final router = GoRouter(
    initialLocation: pushDummyFirst ? '/login/child' : '/login',
    routes: <RouteBase>[
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
        routes: <RouteBase>[
          GoRoute(
            path: 'child',
            builder: (context, state) => const LoginPage(),
          ),
        ],
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
}

class _LoginHarness {
  const _LoginHarness({required this.container, required this.repository});

  final ProviderContainer container;
  final _FakeAuthRepository repository;
}

/// 可编排的认证仓库：记录检测入参与登录链路调用，门控时把未来挂住。
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({required this.capabilities});

  ServerCapabilities capabilities;
  bool throwOnDetect = false;
  bool gateDetect = false;
  bool gateLogin = false;
  Completer<ServerCapabilities>? _detectGate;
  Completer<LoginResult>? _loginGate;

  final List<String> detected = <String>[];
  final List<String> loginCalls = <String>[];

  @override
  Future<ServerCapabilities> detectServerCapabilities(
    String serverUrl,
  ) async {
    detected.add(serverUrl);
    if (gateDetect) {
      _detectGate ??= Completer<ServerCapabilities>();
      return _detectGate!.future;
    }
    if (throwOnDetect) throw StateError('detect failed');
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
    return _loginResult();
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
    return _loginResult();
  }

  bool failLogin = false;
  String? loginError;

  /// 把挂在 `_loginGate` 上的登录未来放行。
  ///
  /// 先把门清零再取结果：[_loginResult] 在 gated 时返回的是门自身的
  /// future，直接 `complete(_loginResult())` 会撞上
  /// “Cannot complete a future with itself”。
  void releaseLogin() {
    final gate = _loginGate;
    // 必须先摘门再放行，且放行值走 [_buildResult] 而不是 [_loginResult]：
    // 否则 _loginResult 会就地重建一个新门并把「门的 future」灌回自己，
    // 撞上 “Cannot complete a future with itself”，登录链直接断在半路。
    _loginGate = null;
    gate?.complete(_buildResult());
  }

  LoginResult _buildResult() => LoginResult(
    success: !failLogin,
    library: failLogin
        ? null
        : MusicLibrary(
          id: 'lib-1',
          name: '主库',
          isActive: true,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
    errorMessage: failLogin ? loginError : null,
  );

  Future<LoginResult> _loginResult() async {
    if (gateLogin) {
      _loginGate ??= Completer<LoginResult>();
      return _loginGate!.future;
    }
    return _buildResult();
  }
}

/// 认证状态机的落库依赖：[AuthNotifier] 登录后会把库写回这里。
///
/// 直接以具体实现兜住 `addLibrary` / `setActiveLibrary` 两个 `Future<void>`
/// 入口：不桩的 mock 会返回 `null`，`await null` 会让
/// `AuthNotifier._handleLoginResult` 抛 “type 'Null' is not a subtype of
/// type 'Future<void>'”，而用 mocktail `any()` / `isA<>` 匹配
/// `MusicLibrary` 又会分别撞上「未注册 fallback」和「TypeMatcher 不满足
/// covariant 形参」——直接用实现最干净。
class FakeLibraryRepository extends Mock implements LibraryRepository {
  @override
  Future<void> addLibrary(MusicLibrary library) async {}

  @override
  Future<void> setActiveLibrary(String id) async {}
}
