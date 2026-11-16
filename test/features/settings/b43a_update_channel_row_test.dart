// b43a —— 设置页「更新通道」行的行为测试。
//
// 覆盖 lib/features/settings/pages/app_settings_page.dart 里的
// Consumer + MusicFlowSettingRow（更新通道行）与 _showUpdateChannelSheet：
//   - 默认显示 Gitee（默认通道，无 prefs 记录也成立）；
//   - 点行弹出两选一面板（Gitee / GitHub，当前项选中）；
//   - 选 GitHub → 行值即时变 GitHub 且持久化到 prefs('update_channel')；
//   - 通道行不受平台门控（非 Android 平台同样显示，与下方四态更新行不同）。
//
// 下载控制器沿用 b42a 的 stub 子类；页面长 ListView 滚动到诊断分区。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/data/sources/prefs_gate.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/settings/update_channel_provider.dart';
import 'package:musicflow_client/providers/settings/update_download_provider.dart';

class _FakeLibraryRepository extends Mock implements LibraryRepository {}

class _FakeAuthRepository extends Mock implements AuthRepository {}

/// 固定 idle 状态的控制器：通道行测试不关心下载四态。
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
Future<ProviderContainer> _pumpSettings(WidgetTester tester) async {
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
        () => _StubDownloadController(const UpdateDownloadState()),
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

/// 滚到更新通道行（诊断分区在页面底部）。
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

  testWidgets('默认通道 gitee → 通道行显示 Gitee', (tester) async {
    await _pumpSettings(tester);
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_update_channel_title));

    expect(find.text(l.settings_update_channel_title), findsOneWidget);
    // MusicFlowSettingRow 把 value 与 description 拼成一行文本：
    // 「Gitee · 选择检查与下载更新使用的来源」（value 在前，' · ' 连接）。
    expect(
      find.text('Gitee · ${l.settings_update_channel_desc}'),
      findsOneWidget,
    );
    expect(find.text('GitHub'), findsNothing);
  });

  testWidgets('点通道行 → 弹出两选一面板，当前项选中', (tester) async {
    await _pumpSettings(tester);
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_update_channel_title));
    await tester.tap(find.text(l.settings_update_channel_title));
    // 面板有入场动效：固定帧推进而非 pumpAndSettle。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // 面板副标题（MusicFlowBottomSheet 独立文本）。
    expect(find.text(l.settings_update_channel_desc), findsOneWidget);
    // 行值行是拼接文本（'Gitee · desc'），裸 'Gitee' 只来自选择行标题。
    expect(find.text('Gitee'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    // 选择行描述：MusicFlowChoiceRow 无 value → 拼接文本就是 description 本身。
    expect(find.text(l.settings_update_channel_gitee), findsOneWidget);
    expect(find.text(l.settings_update_channel_github), findsOneWidget);
  });

  testWidgets('选 GitHub → 行值即时变 GitHub 并持久化到 prefs', (tester) async {
    final container = await _pumpSettings(tester);
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_update_channel_title));
    await tester.tap(find.text(l.settings_update_channel_title));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    await tester.tap(find.text('GitHub'));
    // 关闭面板动效 + setChannel 持久化：多推几帧。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // 面板已关闭：设置行行值变 GitHub（拼接文本），不再有 Gitee 拼接行。
    expect(
      find.text('GitHub · ${l.settings_update_channel_desc}'),
      findsOneWidget,
    );
    expect(
      find.text('Gitee · ${l.settings_update_channel_desc}'),
      findsNothing,
    );
    // Provider 状态与 prefs 同步落盘。
    expect(container.read(updateChannelProvider), UpdateChannel.github);
    final prefs = await getPrefs();
    expect(prefs.getString('update_channel'), 'github');
  });

  testWidgets('通道行不受平台门控：Windows 下也显示（与四态更新行不同）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _pumpSettings(tester);
    final l = loc!;

    await _scrollTo(tester, find.text(l.settings_update_channel_title));

    // 非 Android 平台：内置更新行退化回「检查更新」idle 行，但通道行始终可见。
    expect(find.text(l.settings_update_channel_title), findsOneWidget);
    expect(find.text(l.settings_check_update), findsOneWidget);
    // debug 变量必须在用例体内复位（tearDown 晚于框架不变量检查）。
    debugDefaultTargetPlatformOverride = null;
  });
}
