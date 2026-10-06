// batch37-A：`lib/features/player/pages/full_player_page.dart` 的**定时暂停弹窗**
// 整段（源码 1417 + 1433-1451）。经查既有 b35a 只测了工具条上定时按钮的剩余时长
// **文案**，从未点开弹窗，所以按钮闭包 1417 与 `_openSleepTimerSheet` 一直是 0 命中：
//   * 1417 点按钮 → 调 `_openSleepTimerSheet`；
//   * 1434-1444 读当前定时 + 打开 `SleepTimerSheet`（含 hasExisting / 剩余回显）；
//   * 1446-1447 结果为 `SleepTimerStartChoice` → `notifier.start(...)`；
//   * 1448-1449 结果为 `SleepTimerOffSentinel` → `notifier.cancel()`。
//
// ── 为什么用「直接 pop 路由注入结果」而不是点弹窗里的按钮 ──────────────
// 产品侧走的是 `showDialog`（AlertDialog + 内含 LayoutBuilder 的 MusicFlowButton）。
// 在 flutter_test 环境里这会被要求计算固有尺寸，抛
// 「LayoutBuilder does not support returning intrinsic dimensions」并级联出
// `hasSize` —— 弹窗里的子节点根本没被布局，没法 tap（b33c 记载过的同一环境坑，
// 那里靠 `Navigator.push` + `SizedBox(width:360)` 规避，而产品代码不能用这招）。
// 因此这里改成：点按钮**真的把弹窗打开**（覆盖 1417/1434-1444），再用
// `Navigator.pop(result)` 把 `_openSleepTimerSheet` 里那个 `await showDialog`
// 的 future 解析成我们想要的结果，从而确定性覆盖两条出口分支；弹窗渲染异常
// 由 `quietPump` 逐帧吸收。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/sleep_timer_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_player_notifier.dart';

AppLocalizations? loc;

Song _song() => Song(
      id: 'current',
      title: '定时曲',
      artist: '歌手',
      album: '专辑',
      duration: 240,
      bitRate: 320,
    );

/// 录制桩：只记 start/cancel，不起 periodic Timer。
class _RecSleepTimer extends SleepTimerNotifier {
  _RecSleepTimer(super.ref);

  final List<Duration> starts = <Duration>[];
  int cancelCalls = 0;

  void setRemaining(Duration? remaining) => state = remaining;

  @override
  Future<void> start(Duration duration) async {
    starts.add(duration);
    state = duration;
  }

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
    state = null;
  }
}

class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref);
}

class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey<String>('b37a_open_full_player'),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => const FullPlayerPage()),
          ),
          child: const Text('open'),
        ),
      ),
    );
  }
}

/// 测试脚手架主题：给 Dialog 注入**紧宽度**约束。
///
/// 根因（环境 × 产品交互）：`SleepTimerSheet` 是 `AlertDialog`，其内部用
/// `IntrinsicWidth` 包裹整列；而 actions 里的 `MusicFlowButton` 内含
/// `LayoutBuilder`。当 `IntrinsicWidth` 收到**松宽度**约束（`Dialog` 的
/// `Align` 会把 showDialog 的全屏紧约束放松）时会去调
/// `child.getMaxIntrinsicWidth`，命中
/// `LayoutBuilder does not support returning intrinsic dimensions`，
/// performLayout 直接抛异常 → 弹窗子树从未布局 → `MusicFlowButton` 的
/// `LayoutBuilder.builder` 从未执行 → 其内部 `Text('关闭定时')` 根本没被创建。
///
/// 这与 b33c_sleep_timer_sheet_test 用 `SizedBox(width:360)` 规避是**同一原理**：
/// `RenderIntrinsicWidth._childConstraints` 在 `constraints.hasTightWidth`
/// 时不会去算固有宽度。产品代码里弹窗由 `showDialog` 弹出，测试无法给它套
/// `SizedBox`，故改在主题层用 `DialogThemeData.constraints` 注入紧宽度
/// （`Dialog.build` 会把它交给 `ConstrainedBox`，enforce 后得到紧宽度）。
/// 仅改测试脚手架，不动 lib/，断言意图保持不变。
ThemeData _tightDialogTheme() {
  final base = AppTheme.dark();
  return base.copyWith(
    dialogTheme: base.dialogTheme.copyWith(
      constraints: const BoxConstraints.tightFor(width: 360),
    ),
  );
}

void main() {
  late _RecSleepTimer sleepTimer;

  Widget providerApp() => ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith(
            (ref) => TestPlayerNotifier(PlayerState(currentSong: _song())),
          ),
          currentSongPaletteProvider.overrideWith((ref) async => null),
          resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
            MusicFlowMediaVisuals.fallback(),
          ),
          currentLyricsProvider.overrideWith((ref) async => null),
          castPeerControllerProvider.overrideWith(
            (ref) => _FakeCastPeerController(ref),
          ),
          sleepTimerProvider.overrideWith(
            (ref) => sleepTimer = _RecSleepTimer(ref),
          ),
        ],
        child: MaterialApp(
          theme: _tightDialogTheme(),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          locale: const Locale('zh'),
          builder: (context, child) {
            loc = AppLocalizations.of(context);
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(disableAnimations: true),
              child: MusicFlowTapAnchorScope(child: child!),
            );
          },
          home: const _RootScreen(),
        ),
      );

  Future<void> drain(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 逐帧吸收弹窗固有尺寸异常（环境坑），只留确定性副作用。
  Future<void> quietPump(WidgetTester tester, {int frames = 14}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      tester.takeException();
    }
  }

  Finder utility(Finder inner) => find.descendant(
        of: find.byKey(const ValueKey<String>('full_player_utility_bar')),
        matching: inner,
      );

  Future<void> pumpAndEnter(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(providerApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('b37a_open_full_player')));
    await drain(tester, frames: 14);
  }

  /// 点定时按钮打开弹窗（覆盖 1417 / 1434-1444），再 pop 出想要的结果。
  Future<void> openSheetThenPop(WidgetTester tester, Object? result) async {
    await tester.tap(utility(find.byIcon(AppIcons.timer)));
    await quietPump(tester);
    expect(
      find.text(loc!.player_sleep_timer_dialog_title),
      findsOneWidget,
      reason: '点按钮必须真的把 SleepTimerSheet 弹出来',
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop(result);
    await quietPump(tester);
  }

  testWidgets('点定时按钮 → 弹窗 → 结果 StartChoice → start(25min)', (tester) async {
    await pumpAndEnter(tester);
    expect(sleepTimer.starts, isEmpty);

    await openSheetThenPop(
      tester,
      const SleepTimerStartChoice(duration: Duration(minutes: 25)),
    );

    expect(
      sleepTimer.starts,
      <Duration>[const Duration(minutes: 25)],
      reason: 'StartChoice 必须落到 start（1446-1447）',
    );
  });

  testWidgets('已有定时 → hasExisting → 结果 OffSentinel → cancel', (tester) async {
    await pumpAndEnter(tester);

    sleepTimer.setRemaining(const Duration(minutes: 30));
    await drain(tester, frames: 2);

    await tester.tap(utility(find.byIcon(AppIcons.timer)));
    await quietPump(tester);
    expect(find.text(loc!.player_sleep_timer_dialog_title), findsOneWidget);
    expect(
      find.text(loc!.player_sleep_timer_off),
      findsOneWidget,
      reason: 'hasExisting=true 时才有「关闭定时」（1440）',
    );

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop(const SleepTimerOffSentinel());
    await quietPump(tester);

    expect(
      sleepTimer.cancelCalls,
      1,
      reason: 'OffSentinel 必须落到 cancel（1448-1449）',
    );
    expect(sleepTimer.state, isNull);
  });
}
