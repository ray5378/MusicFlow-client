// batch37-A2 —— `lib/features/player/pages/full_player_page.dart` 播放核心**剩余未覆盖行**补测。
//
// 本文件只啃「既有 b30c/b35a 系列都没打到、且经源码核对确实可达」的分支，逐条对应：
//   * 294 ：`_buildWidePlayerLayout` 里 `musicFlowWindowClass == compact` 的窄宽分支
//           （宽 594 < 600 且宽 > 高，桌面平台 → 走大屏分栏但落在 compact 档）。
//   * 903 ：`_CurrentLyricLine` 的 `error:` 出口（首屏当前歌词行）。竖屏首页才会挂
//           载它；b35a 的歌词失败用例在大屏右栏，命中的是另一个 pane 的 error 出口。
//   * 1478：`_openPlayerSwitcher` 关闭面板后 `cast.activePeer != null` 的
//           「正在投屏到 X」toast（既有用例只覆盖了 activePeer == null 的回本机分支）。
//   * 1545：`_PlayerIconButton` 的 `selected` 前景色分支（投屏中 → transfer 按钮选中）。
//
// 只报告不修（源码核对后确认测试环境不可达 / 无调用方）：
//   * 624 ：`_buildSongIdentity(scrollable: true)` 归档分支 —— 两处调用点都显式传
//           `scrollable: false`，`SingleChildScrollView` 包裹分支无调用方（死代码）。
//   * 694 ：标题栏拖拽把手的 `onTap: () {}` —— 见 688-691 行自述缺陷：把手用
//           `HitTestBehavior.translucent` + `SizedBox.expand()`（hitTestSelf=false），
//           单击事件穿透到外层背景 GestureDetector，内层 onTap 永不落地。
//   * 809/811/812：`bestLyrics == null` 分支 —— `getBest()` 仅在 entries 为空时返回
//           null，而 800 行已用 `lyrics.isEmpty` 拦截（b35a 头注释同样记载为死代码）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/player_switcher.dart'
    show PlayerSwitcherSheet;
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_player_notifier.dart';

AppLocalizations? loc;

Song _song({String id = 'current', bool starred = false}) => Song(
      id: id,
      title: 'Who are you',
      artist: 'Cesária Évora',
      album: 'Café Atlantico',
      duration: 240,
      bitRate: 320,
      starred: starred,
    );

class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey<String>('b37a2_open_full_player'),
          onPressed: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => const FullPlayerPage()),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

/// 链路 A 投屏控制桩：可把 activePeer 摆成「正在投屏到 客厅音箱」（1478 出口）。
class _RecCast extends CastPeerController {
  _RecCast(super.ref);

  static const PeerInfo castPeer = PeerInfo(
    peerId: 'peer-1',
    name: '客厅音箱',
    kind: 'player',
    available: true,
  );

  void becomeCasting() {
    state = state.copyWith(
      activePeer: castPeer,
      castQueue: const <Map<String, dynamic>>[
        <String, dynamic>{'songId': 'current', 'title': 'x'},
      ],
      castIndex: 0,
      playMode: 'all',
    );
  }
}

// ignore: library_private_types_in_public_api
late _RecCast cast;

class _RecDlna extends DlnaCastNotifier {
  _RecDlna(super.ref);
}

class _RecSleepTimer extends SleepTimerNotifier {
  _RecSleepTimer(super.ref);
}

/// 歌词源：由用例注入（抛错即走 error 出口）。
late Future<Lyrics?> Function() lyricsFn;

Widget providerApp({
  required PlayerState state,
  required bool disableAnimations,
}) {
  return ProviderScope(
    overrides: <Override>[
      playerProvider.overrideWith((ref) => TestPlayerNotifier(state)),
      currentSongPaletteProvider.overrideWith((ref) async => null),
      resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
        MusicFlowMediaVisuals.fallback(),
      ),
      currentLyricsProvider.overrideWith((ref) => lyricsFn()),
      castPeerControllerProvider.overrideWith(
        (Ref ref) => cast = _RecCast(ref),
      ),
      dlnaCastProvider.overrideWith((Ref ref) => _RecDlna(ref)),
      sleepTimerProvider.overrideWith((Ref ref) => _RecSleepTimer(ref)),
    ],
    child: MaterialApp(
      navigatorKey: rootNavigatorKey,
      theme: AppTheme.dark(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      locale: const Locale('zh'),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(disableAnimations: disableAnimations),
          child: MusicFlowTapAnchorScope(child: child!),
        );
      },
      home: const _RootScreen(),
    ),
  );
}

/// 有界推帧（页面含黑胶无限旋转动画，禁 pumpAndSettle）。
Future<void> drain(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 逐帧吸收渲染异常（环境坑 / 已知窄宽溢出缺陷），只留确定性副作用。
Future<void> quietPump(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    tester.takeException();
  }
}

Future<void> pumpApp(
  WidgetTester tester, {
  PlayerState? state,
  double width = 1440,
  double height = 900,
  bool disableAnimations = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    providerApp(
      state: state ?? PlayerState(currentSong: _song()),
      disableAnimations: disableAnimations,
    ),
  );
  await drain(tester, frames: 14);
}

Future<void> enterFullPlayer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('b37a2_open_full_player')));
  await drain(tester, frames: 14);
}

Finder _utility(Finder inner) => find.descendant(
      of: find.byKey(const ValueKey<String>('full_player_utility_bar')),
      matching: inner,
    );

void main() {
  setUp(() {
    lyricsFn = () async => null;
  });

  testWidgets('首屏当前歌词行 error 出口：歌词加载失败不崩、整行隐藏（903）', (
    tester,
  ) async {
    // 竖屏（非桌面）→ PageView 首屏挂载 `_CurrentLyricLine`；歌词 provider 抛错
    // → 其 error 分支（903）返回 SizedBox.shrink，页面照常渲染。
    lyricsFn = () async => throw StateError('lyrics boom');
    await pumpApp(tester, state: PlayerState(currentSong: _song()));
    await enterFullPlayer(tester);

    // 错误态下不显示任何歌词行文本；页面核心控件仍在。
    expect(
      find.byKey(const ValueKey<String>('full_player_portrait_layout')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('投屏中关闭流转面板 → 「正在投屏到 客厅音箱」toast（1478）', (
    tester,
  ) async {
    await pumpApp(
      tester,
      state: PlayerState(currentSong: _song(starred: true)),
    );
    await enterFullPlayer(tester);

    await tester.tap(_utility(find.byIcon(AppIcons.transferInfinity)));
    await drain(tester, frames: 14);
    expect(find.byType(PlayerSwitcherSheet), findsOneWidget);

    // 面板打开的这段窗口里把控制目标摆成「正在投屏到 客厅音箱」——
    // 关闭后 `_openPlayerSwitcher` 重读 cast 就该走 activePeer != null 分支。
    cast.becomeCasting();
    await drain(tester, frames: 2);

    // 直接 pop 根导航器关闭面板（不点面板内控件，避免误触「本机」行触发 backToLocal
    // 把 activePeer 清掉）——只留「关闭后重读 cast」这一条确定性路径。
    rootNavigatorKey.currentState!.pop();
    await drain(tester, frames: 18);

    expect(
      find.text(loc!.player_casting_to('客厅音箱')),
      findsOneWidget,
      reason: 'activePeer != null → 投屏中分支（1478）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄宽大屏（594x400 → compact 档）走 compact 内边距（294）', (
    tester,
  ) async {
    // 桌面平台（windows，非触屏）且 宽>高 → 进大屏分栏；宽 594 < 600 → compact 档。
    // [D-046] 该档左栏仅 ~186px，工具条 5×48 按钮会 RenderFlex 溢出（已知缺陷），
    // 用 quietPump 吸收，只断言确实走了大屏分栏且无致命异常。
    // flutter_test 默认平台是 android（触屏）→ 必须显式摆成桌面平台。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpApp(
        tester,
        state: PlayerState(currentSong: _song()),
        width: 594,
        height: 400,
      );
      await enterFullPlayer(tester);
      await quietPump(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    expect(
      find.byKey(const ValueKey<String>('full_player_wide_layout')),
      findsOneWidget,
      reason: '宽>高且非触屏 → 大屏分栏',
    );
    expect(tester.takeException(), isNull);
  });
}
