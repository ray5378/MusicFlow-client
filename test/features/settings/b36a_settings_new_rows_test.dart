// b36a —— 设置页两处新增 UI 的补测
// （`lib/features/settings/pages/app_settings_page.dart`）：
//   1) 音乐库分区「添加新音乐库」行 → 点击跳转 `/login?add=true`；
//   2) 播放分区「默认控制当前客户端」开关 → initState 读盘 + 切换落盘。
//
// 产品代码零改动；仅新增 test/。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

class _FakeLibraryRepository extends Mock implements LibraryRepository {}

class _FakeAuthRepository extends Mock implements AuthRepository {}

AppLocalizations? loc;

/// 在页面里捞一份 AppLocalizations，断言文案不硬编码。
class _LocProbe extends StatelessWidget {
  const _LocProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    loc = AppLocalizations.of(context);
    return child;
  }
}

/// 页面主体是长 ListView（踩坑：默认 800×600 只构建可见行），拉高视口。
void enlargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1.0;
}

/// 页面里 Ticker/动画不断请求新帧，固定帧推进而非 pumpAndSettle。
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<ProviderContainer> pumpSettings(WidgetTester tester) async {
  enlargeViewport(tester);
  addTearDown(tester.view.reset);

  final repo = _FakeLibraryRepository();
  when(() => repo.watchLibraries()).thenAnswer(
    (_) => Stream<List<MusicLibrary>>.value(const <MusicLibrary>[]),
  );
  when(() => repo.setActiveLibrary(any())).thenAnswer((_) async {});

  final c = ProviderContainer(
    overrides: <Override>[
      libraryRepositoryProvider.overrideWithValue(repo),
      librariesProvider.overrideWith(
        (ref) => Stream<List<MusicLibrary>>.value(const <MusicLibrary>[]),
      ),
      authStateProvider.overrideWith(
        (ref) => AuthNotifier(_FakeAuthRepository(), repo),
      ),
    ],
  );
  addTearDown(c.dispose);

  final router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, _) => const _LocProbe(child: AppSettingsPage()),
      ),
      GoRoute(
        path: '/login',
        builder: (_, state) => Scaffold(
          body: Text('login-page:add=${state.uri.queryParameters['add']}'),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
      ),
    ),
  );
  await settle(tester);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    loc = null;
  });

  testWidgets('音乐库分区出现「添加新音乐库」行（标题 + 副标题）', (tester) async {
    await pumpSettings(tester);

    expect(find.text(loc!.widgets_drawer_add_new_library), findsOneWidget);
    expect(
      find.textContaining(loc!.widgets_drawer_add_new_library_subtitle),
      findsOneWidget,
    );
  });

  testWidgets('播放分区出现「默认控制当前客户端」开关行', (tester) async {
    await pumpSettings(tester);

    expect(
      find.text(loc!.settings_default_control_current_client),
      findsOneWidget,
    );
    expect(find.byType(MusicFlowToggleSettingRow), findsWidgets);
  });

  testWidgets('点击「添加新音乐库」→ 跳转 /login?add=true', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text(loc!.widgets_drawer_add_new_library));
    await settle(tester, frames: 8);

    expect(find.text('login-page:add=true'), findsOneWidget);
  });

  testWidgets('切换「默认控制当前客户端」→ 往返落盘', (tester) async {
    await pumpSettings(tester);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isFalse);

    // 开：false → true
    await tester.tap(find.text(loc!.settings_default_control_current_client));
    await settle(tester);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isTrue);

    // 关：true → false
    await tester.tap(find.text(loc!.settings_default_control_current_client));
    await settle(tester);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isFalse);
  });

  testWidgets('initState 从盘里读回 true → 首次点击落为 false', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'default_control_current_client': true,
    });
    await pumpSettings(tester);

    // 读盘成功（initState 分支），点击后翻转并落盘。
    await tester.tap(find.text(loc!.settings_default_control_current_client));
    await settle(tester);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isFalse);
  });
}
