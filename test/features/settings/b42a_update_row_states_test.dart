// b42a —— 设置页「更新行」四态的行为测试。
//
// 覆盖 lib/features/settings/pages/app_settings_page.dart 里那一段
// `Consumer` + `switch (downloadState.stage)`：
//   idle        → 「检查更新」原样行；
//   downloading → 「正在下载更新」+ 百分比；
//   completed   → 「下载完成…」+ 版本号；
//   failed      → 「检查更新」+ 一句失败原因；
//   非 Android  → 无论控制器什么状态，都退化回改动前那一行。
//
// 控制器用 stub 子类直接给定状态（不动产品代码）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/settings/update_download_provider.dart';

class _FakeLibraryRepository extends Mock implements LibraryRepository {}

class _FakeAuthRepository extends Mock implements AuthRepository {}

/// 固定状态的控制器：只让页面拿到想要的 [UpdateDownloadState]。
class _StubDownloadController extends UpdateDownloadController {
  _StubDownloadController(this.initial);

  final UpdateDownloadState initial;

  @override
  UpdateDownloadState build() => initial;
}

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

/// 页面主体是长 ListView：先拉高视口，再按需滚动到目标行。
Future<ProviderContainer> _pumpSettings(
  WidgetTester tester,
  UpdateDownloadState state,
) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final repo = _FakeLibraryRepository();
  when(
    () => repo.watchLibraries(),
  ).thenAnswer((_) => Stream<List<MusicLibrary>>.value(const <MusicLibrary>[]));
  when(() => repo.setActiveLibrary(any())).thenAnswer((_) async {});

  final container = ProviderContainer(
    overrides: <Override>[
      libraryRepositoryProvider.overrideWithValue(repo),
      librariesProvider.overrideWith(
        (ref) => Stream<List<MusicLibrary>>.value(const <MusicLibrary>[]),
      ),
      authStateProvider.overrideWith(
        (ref) => AuthNotifier(_FakeAuthRepository(), repo),
      ),
      updateDownloadControllerProvider.overrideWith(
        () => _StubDownloadController(state),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, _) => const _LocProbe(child: AppSettingsPage()),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
      ),
    ),
  );
  // 页面里 Ticker 不断请求新帧：固定帧推进而非 pumpAndSettle。
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return container;
}

/// 滚到更新行（诊断分区在页面底部）。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    320,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 80,
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    loc = null;
  });

  testWidgets('stage == idle → 显示「检查更新」原样行', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpSettings(tester, const UpdateDownloadState());
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_check_update));

    expect(find.text(l.settings_check_update), findsOneWidget);
    expect(find.text(l.settings_check_update_desc), findsOneWidget);
    expect(find.text(l.settings_update_downloading), findsNothing);
    expect(find.text(l.settings_update_download_ready), findsNothing);
    // debug 变量必须在用例体内复位（tearDown 晚于框架不变量检查）。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('stage == downloading → 显示「正在下载」+ 百分比文本', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpSettings(
      tester,
      const UpdateDownloadState(
        stage: UpdateDownloadStage.downloading,
        version: '1.2.3',
        progress: ApkDownloadProgress(received: 42, total: 100),
      ),
    );
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_update_downloading));

    expect(find.text(l.settings_update_downloading), findsOneWidget);
    // 标题右侧的百分比角标。
    expect(find.text('42%'), findsOneWidget);
    // 描述里的百分比 + 已下载/总量。
    expect(
      find.text(l.settings_update_download_progress('42', '42 B', '100 B')),
      findsOneWidget,
    );
    expect(find.text(l.settings_check_update), findsNothing);
    // debug 变量必须在用例体内复位（tearDown 晚于框架不变量检查）。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('stage == completed → 显示「下载完成」+ 版本号', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpSettings(
      tester,
      const UpdateDownloadState(
        stage: UpdateDownloadStage.completed,
        version: '1.2.3',
        apkPath: '/tmp/musicflow-1.2.3.apk',
        installPending: true,
      ),
    );
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_update_download_ready));

    expect(find.text(l.settings_update_download_ready), findsOneWidget);
    expect(find.text(l.settings_update_found_version('1.2.3')), findsOneWidget);
    expect(find.text(l.settings_check_update), findsNothing);
    // debug 变量必须在用例体内复位（tearDown 晚于框架不变量检查）。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('stage == failed → 描述里带出失败原因', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpSettings(
      tester,
      const UpdateDownloadState(
        stage: UpdateDownloadStage.failed,
        version: '1.2.3',
        errorMessage: '磁盘空间不足',
      ),
    );
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_check_update));

    expect(find.text(l.settings_check_update), findsOneWidget);
    expect(
      find.text(l.settings_update_download_failed('磁盘空间不足')),
      findsOneWidget,
    );
    expect(find.textContaining('磁盘空间不足'), findsOneWidget);
    // 失败态描述不再复用「从 GitHub Releases 检查最新版本」。
    expect(find.text(l.settings_check_update_desc), findsNothing);
    // debug 变量必须在用例体内复位（tearDown 晚于框架不变量检查）。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('非 Android 平台：控制器已在下载，也退化成「检查更新」行', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _pumpSettings(
      tester,
      const UpdateDownloadState(
        stage: UpdateDownloadStage.downloading,
        version: '1.2.3',
        progress: ApkDownloadProgress(received: 42, total: 100),
      ),
    );
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_check_update));

    expect(find.text(l.settings_check_update), findsOneWidget);
    expect(find.text(l.settings_check_update_desc), findsOneWidget);
    expect(find.text(l.settings_update_downloading), findsNothing);
    expect(find.text('42%'), findsNothing);
    // debug 变量必须在用例体内复位（tearDown 晚于框架不变量检查）。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('非 Android 平台：completed 状态也不显示「下载完成」行', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _pumpSettings(
      tester,
      const UpdateDownloadState(
        stage: UpdateDownloadStage.completed,
        version: '1.2.3',
        apkPath: '/tmp/musicflow-1.2.3.apk',
      ),
    );
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_check_update));

    expect(find.text(l.settings_check_update), findsOneWidget);
    expect(find.text(l.settings_update_download_ready), findsNothing);
    expect(find.text(l.settings_update_found_version('1.2.3')), findsNothing);
    // debug 变量必须在用例体内复位（tearDown 晚于框架不变量检查）。
    debugDefaultTargetPlatformOverride = null;
  });
}
