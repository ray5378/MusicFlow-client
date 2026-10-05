// ============================================================================
// batch30-C —— `lib/features/player/pages/full_player_page.dart` 补测
//
// 打的是 batch29 lcov 里剩下的几处「页面上确实存在、但没人把控件点起来」的分支：
//   * 63–65：`ModalRoute.of(context)?.animation == null`（页面不是走
//     push 进来的场景，例如被当作某些壳的内嵌内容）；
//   * 121–149：`currentSong == null` 的「未在播放」空态 + 空态关闭按钮闭包；
//   * 186：`PopScope` 返回手势 → `_closeToMini`；
//   * 297–299：宽屏背景 GestureDetector 的 `onTap: _closeToMini`；
//   * 671–691：`_WideDragBanner`（仅 Windows 桌面端）的拖拽 / 双击走 native
//     窗口控制，两条 catch 各自打一遍。
//
// **不改产品代码**，发现的问题只在注释里记录。
//
// 踩坑：
// #30C-8 `FullPlayerPage` 的布局分支看的是 `Theme.of(context).platform`
//       （不是 `defaultTargetPlatform`）：只要不是 android/iOS，视口足够宽就走
//       `_buildWidePlayerLayout`。Windows 专属的拖拽条则还要 `isWindowsDesktop`
//       —— 那个才是 `defaultTargetPlatform`，必须用
//       `debugDefaultTargetPlatformOverride = TargetPlatform.windows`（用例体内
//       try/finally 还原，见 #88-D）。
// #30C-9 `MaterialApp.builder` 拿到的 context 在 Navigator **之上**：用它返回页面
//       即可构造「没有 ModalRoute 祖先」的场景（打到 63–65）。
// #30C-10 页面 p.s. `_closeToMini` 会 `Navigator.of(context).pop()`：直接把它当
//       `home:` 打开再点关闭＝弹根路由，测试会黑屏/报错。统一从根屏 push 进去，
//       关闭后退回根屏，断言「回到根屏」。
// ============================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_player_notifier.dart';

/// 树内的 AppLocalizations，供断言本地化文案（不硬编码中文）。
AppLocalizations? loc;

Song _song() => Song(
      id: 'current',
      title: 'Who are you',
      artist: 'Cesária Évora',
      album: 'Café Atlantico',
      duration: 240,
      bitRate: 320,
    );

/// 根屏：从这里 push 进全屏播放器，便于验证「关闭＝退回根屏」。
class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey<String>('b30c_open_full_player'),
          onPressed: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const FullPlayerPage(),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

/// [noRoute] = true 时把页面挂在 `MaterialApp.builder` 上（无 ModalRoute 祖先）。
Widget providerApp({
  required PlayerState state,
  required double width,
  required double height,
  bool noRoute = false,
}) {
  return ProviderScope(
    overrides: <Override>[
      playerProvider.overrideWith((ref) => TestPlayerNotifier(state)),
      currentSongPaletteProvider.overrideWith((ref) async => null),
      resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
        MusicFlowMediaVisuals.fallback(),
      ),
      currentLyricsProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      locale: const Locale('zh'),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(disableAnimations: true),
          // #30C-9：builder 的 context 在 Navigator **之上**，这里直接拿 page 顶掉
          // child ⇒ 页面没有 ModalRoute 祖先。RawTooltip 需要 Overlay，补一个；
          // Overlay 本身给的是 loose 约束（否则里层 Column 会「overflow 99116px」），
          // 所以 entry 内部用 Positioned.fill 撑满。
          child: noRoute
              ? Overlay(
                  initialEntries: <OverlayEntry>[
                    OverlayEntry(
                      builder: (_) =>
                          const Positioned.fill(child: FullPlayerPage()),
                    ),
                  ],
                )
              : child!,
        );
      },
      home: noRoute ? null : const _RootScreen(),
    ),
  );
}

Future<void> pumpApp(
  WidgetTester tester, {
  PlayerState? state,
  double width = 1440,
  double height = 900,
  bool noRoute = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    providerApp(
      state: state ?? PlayerState(currentSong: _song()),
      width: width,
      height: height,
      noRoute: noRoute,
    ),
  );
  await tester.pumpAndSettle();
}

/// 从根屏 push 进全屏播放器（#30C-10）。
Future<void> enterFullPlayer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('b30c_open_full_player')));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kWindowsWindowChannel, null);
  });

  group('full_player_page 空态', () {
    testWidgets('无当前歌曲时渲染「未在播放」空态', (tester) async {
      await pumpApp(tester, state: PlayerState());
      await enterFullPlayer(tester);

      expect(find.text(loc!.player_empty_title), findsOneWidget);
      expect(find.text(loc!.player_empty_desc), findsOneWidget);
      // 有歌时才有的控件在空态里不存在。
      expect(
        find.byKey(const ValueKey<String>('full_player_transport_controls')),
        findsNothing,
      );
    });

    testWidgets('空态点「关闭」退回上一页', (tester) async {
      await pumpApp(tester, state: PlayerState());
      await enterFullPlayer(tester);
      expect(find.text(loc!.player_empty_title), findsOneWidget);

      await tester.tap(find.byTooltip(loc!.player_close));
      await tester.pumpAndSettle();

      expect(find.text(loc!.player_empty_title), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('b30c_open_full_player')),
        findsOneWidget,
      );
    });

    testWidgets('没有 ModalRoute 祖先时前景淡入退化为恒 1', (tester) async {
      // 必须有当前歌曲：Route 前景倒计时 estimator 只在「非空白_state」分支 `_buildRouteForeground`
      // 里用得上（空态在它之前就 return 了）。
      await pumpApp(tester, noRoute: true);

      final fade = tester.widget<FadeTransition>(
        find.byKey(const ValueKey<String>('full_player_foreground_transition')),
      );
      expect(fade.opacity, isA<AlwaysStoppedAnimation<double>>());
      expect(fade.opacity.value, 1.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('full_player_page 关闭出口', () {
  /// #30C-8：Linux 机器上 `Theme.platform` 走到 android/未知分支会退回竖版，
  /// 想稳定进大屏分栏就得显式把平台声明成 Windows（现有
  /// `full_player_page_test.dart` 的宽屏用例也是这么做的）。
  Future<void> pumpWideWindows(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpApp(tester);
      await enterFullPlayer(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

    testWidgets('宽屏背景单击 → _closeToMini 退回根屏', (tester) async {
      await pumpWideWindows(tester);
      expect(
        find.byKey(const ValueKey<String>('full_player_wide_layout')),
        findsOneWidget,
      );

      await tester.tapAt(const Offset(700, 700));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('full_player_wide_layout')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('b30c_open_full_player')),
        findsOneWidget,
      );
    });

    testWidgets('系统返回手势走 PopScope → _closeToMini', (tester) async {
      await pumpWideWindows(tester);
      expect(
        find.byKey(const ValueKey<String>('full_player_wide_layout')),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('full_player_wide_layout')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('b30c_open_full_player')),
        findsOneWidget,
      );
    });
  });

  group('full_player_page Windows 窗口拖拽条', () {
    void mockWindowChannel(
      List<String> calls,
      Object Function() failure,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kWindowsWindowChannel, (call) async {
        calls.add(call.method);
        throw failure();
      });
    }

    Future<void> pumpWindows(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpApp(tester);
        await enterFullPlayer(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('拖拽顶栏经 MissingPluginException 静默', (tester) async {
      final calls = <String>[];
      mockWindowChannel(calls, () => MissingPluginException('no windows'));

      await pumpWindows(tester);
      await tester.dragFrom(
        const Offset(700, 6),
        const Offset(60, 20),
      );
      await tester.pumpAndSettle();

      expect(calls, <String>['start_move']);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('full_player_wide_layout')),
        findsOneWidget,
      );
    });

    testWidgets('双击顶栏经 PlatformException 静默', (tester) async {
      final calls = <String>[];
      mockWindowChannel(
        calls,
        () => PlatformException(code: 'window_failed'),
      );

      await pumpWindows(tester);
      await tester.tapAt(const Offset(700, 6));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(700, 6));
      await tester.pumpAndSettle();

      expect(calls, <String>['maximize_toggle']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('矮而宽的大屏视口走 compactHeight 分支（900×330）', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        // 900 > 330 ⇒ 仍走大屏分栏；左栏可用高 < 460 ⇒ `compactHeight` 为真，
        // 走「详情可滚动 + 控件固定底部」那条分支。
        await pumpApp(tester, width: 900, height: 330);
        await enterFullPlayer(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      expect(
        find.byKey(const ValueKey<String>('full_player_wide_layout')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('full_player_control_panel')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('非 compact 下点队列按钮走右侧队列面板', (tester) async {
      // #94-D：面板开关是模块级静态量，跨用例会串味。
      addTearDown(closeRightQueuePanel);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpApp(tester);
        await enterFullPlayer(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      // `_PlayerIconButton` 不套 Tooltip，按图标 + 传输控件作用域定位。
      final queue = find.descendant(
        of: find.byKey(
          const ValueKey<String>('full_player_transport_controls'),
        ),
        matching: find.byIcon(AppIcons.queue),
      );
      expect(queue, findsOneWidget);

      await tester.tap(queue);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('right-queue-panel')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
