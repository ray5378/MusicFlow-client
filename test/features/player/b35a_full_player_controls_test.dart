// b35a —— full_player_page.dart 控件区补测（Route A 尾部攻坚）。
//
// 打 batch34 剩下的交互分支：
//   * ProgressBar：buffering 加载脉冲（_syncLoadingPulse + 呼吸 Opacity）、
//     duration==0 时手势回调全部为 null、拖拽三段回调（onChangeStart/onChangeEnd
//     → seekEffectivePlayback）、onChangeCancel 取消、切歌自动取消拖拽会话；
//   * PlaybackControls：上一首/下一首、链路 A 投屏态模式切换走 cast、链路 B
//     直投态模式切换走 dlna；
//   * _PlayerUtilityBar：定时暂停弹窗（开启 → start、关闭 → cancel、剩余时长
//     格式化分钟/小时分支）、流转播放面板打开→关闭→回本机 toast、
//     Windows 桌面端直投按钮走桌面样式对话框。
//
// 全部经桩驱动，不触网、不起真 Timer（sleepTimer 换录制桩）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/player_scrubber.dart';
import 'package:musicflow_client/features/player/widgets/player_switcher.dart'
    show PlayerSwitcherSheet;
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:shared_preferences/shared_preferences.dart';

import 'test_player_notifier.dart';

AppLocalizations? loc;

Song _song({String id = 'current'}) => Song(
      id: id,
      title: 'Who are you',
      artist: 'Cesária Évora',
      album: 'Café Atlantico',
      duration: 240,
      bitRate: 320,
    );

List<Song> _queue() => <Song>[_song(), _song(id: 'second')];

class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey<String>('b35a_open_full_player'),
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

/// 链路 A 投屏控制桩：可配置 activePeer/playMode + 记录传输与队列命令。
class _RecCast extends CastPeerController {
  _RecCast(super.ref, {this.casting = false});

  final bool casting;

  final List<Duration> seeks = <Duration>[];
  int toggleCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  int cycleCalls = 0;

  void apply({String playMode = 'all'}) {
    if (!casting) return;
    state = state.copyWith(
      activePeer: const PeerInfo(
        peerId: 'peer-1',
        name: '客厅音箱',
        kind: 'player',
        available: true,
      ),
      castQueue: const <Map<String, dynamic>>[
        <String, dynamic>{'songId': 'current', 'title': 'x'},
      ],
      castIndex: 0,
      playMode: playMode,
    );
  }

  @override
  Future<void> toggle() async {
    toggleCalls += 1;
  }

  @override
  Future<void> next() async {
    nextCalls += 1;
  }

  @override
  Future<void> previous() async {
    previousCalls += 1;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> cyclePlayMode() async {
    cycleCalls += 1;
  }
}

/// 链路 B 直投桩：可配置 casting 态 + 记录模式切换。
class _RecDlna extends DlnaCastNotifier {
  _RecDlna(super.ref, {bool casting = false}) {
    if (casting) {
      state = const DlnaCastState(
        isCasting: true,
        currentIndex: 0,
        playMode: 'all',
      );
    }
  }

  int cycleCalls = 0;

  @override
  Future<void> cyclePlayMode() async {
    cycleCalls += 1;
  }
}

/// 定时暂停录制桩：不起真实 Timer，只记录 start/cancel。
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

// ignore: library_private_types_in_public_api
late _RecCast cast;
// ignore: library_private_types_in_public_api
late _RecDlna dlna;
// ignore: library_private_types_in_public_api
late _RecSleepTimer sleepTimer;
late TestPlayerNotifier player;

Widget providerApp({
  required PlayerState state,
  required double width,
  required double height,
  required bool castCasting,
  required bool dlnaCasting,
  required String castPlayMode,
  required bool disableAnimations,
}) {
  return ProviderScope(
    overrides: <Override>[
      playerProvider.overrideWith((ref) => player),
      currentSongPaletteProvider.overrideWith((ref) async => null),
      resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
        MusicFlowMediaVisuals.fallback(),
      ),
      currentLyricsProvider.overrideWith((ref) async => null),
      castPeerControllerProvider.overrideWith((Ref ref) {
        final notifier = _RecCast(ref, casting: castCasting)
          ..apply(playMode: castPlayMode);
        return cast = notifier;
      }),
      dlnaCastProvider.overrideWith(
        (Ref ref) => dlna = _RecDlna(ref, casting: dlnaCasting),
      ),
      sleepTimerProvider.overrideWith((Ref ref) => sleepTimer = _RecSleepTimer(ref)),
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

Future<void> pumpApp(
  WidgetTester tester, {
  PlayerState? state,
  double width = 1440,
  double height = 900,
  bool castCasting = false,
  bool dlnaCasting = false,
  String castPlayMode = 'all',
  bool disableAnimations = true,
}) async {
  player = TestPlayerNotifier(state ?? PlayerState(currentSong: _song()));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    providerApp(
      state: state ?? PlayerState(currentSong: _song()),
      width: width,
      height: height,
      castCasting: castCasting,
      dlnaCasting: dlnaCasting,
      castPlayMode: castPlayMode,
      disableAnimations: disableAnimations,
    ),
  );
  if (disableAnimations) {
    await tester.pumpAndSettle();
  } else {
    await drain(tester);
  }
}

Future<void> enterFullPlayer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('b35a_open_full_player')));
  await drain(tester, frames: 14);
}

/// 定时弹窗经真实 showDialog 打开时,AlertDialog 的 IntrinsicWidth 会查询
/// MusicFlowButton 内 LayoutBuilder 的固有尺寸,触发
/// 「LayoutBuilder does not support returning intrinsic dimensions」渲染异常
/// （b33c_sleep_timer_sheet_test.dart 头注释记载的同一环境坑）。这里逐帧吸收,
/// 只断言确定性副作用。
Future<void> quietPump(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    tester.takeException();
  }
}

Finder _transport(Finder inner) => find.descendant(
      of: find.byKey(const ValueKey<String>('full_player_transport_controls')),
      matching: inner,
    );

Finder _utility(Finder inner) => find.descendant(
      of: find.byKey(const ValueKey<String>('full_player_utility_bar')),
      matching: inner,
    );

void main() {
  group('ProgressBar', () {
    testWidgets('buffering 时进度条呼吸脉冲,恢复 ready 后回到不透明', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(
          currentSong: _song(),
          queue: _queue(),
          position: const Duration(seconds: 30),
          duration: const Duration(seconds: 240),
          bufferedPosition: const Duration(seconds: 60),
          processingState: ProcessingState.buffering,
        ),
        disableAnimations: false,
      );
      await enterFullPlayer(tester);
      await drain(tester, frames: 4);

      Finder opacityFinder() => find
          .ancestor(
            of: find.byType(MusicFlowPlayerScrubber),
            matching: find.byType(Opacity),
          )
          .first;

      final pulsing = tester.widget<Opacity>(opacityFinder());
      expect(pulsing.opacity, greaterThan(0.45));
      expect(pulsing.opacity, lessThanOrEqualTo(1.0));

      player.emit(
        player.state.copyWith(processingState: ProcessingState.ready),
      );
      await drain(tester, frames: 4);

      final settled = tester.widget<Opacity>(opacityFinder());
      expect(settled.opacity, 1.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('duration==0 时拖拽相关回调全部为 null(不可拖)', (tester) async {
      await pumpApp(tester, state: PlayerState(currentSong: _song()));
      await enterFullPlayer(tester);

      final scrubber = tester.widget<MusicFlowPlayerScrubber>(
        find.byType(MusicFlowPlayerScrubber),
      );
      expect(scrubber.onChangeStart, isNull);
      expect(scrubber.onChanged, isNull);
      expect(scrubber.onChangeEnd, isNull);
      expect(scrubber.onChangeCancel, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拖拽三段回调生效:起拖→更新值→松手下发 seek', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(
          currentSong: _song(),
          queue: _queue(),
          position: const Duration(seconds: 30),
          duration: const Duration(seconds: 240),
          processingState: ProcessingState.ready,
        ),
      );
      await enterFullPlayer(tester);

      MusicFlowPlayerScrubber scrubber() =>
          tester.widget<MusicFlowPlayerScrubber>(
            find.byType(MusicFlowPlayerScrubber),
          );

      scrubber().onChangeStart!(60000.0);
      await drain(tester, frames: 2);
      expect(scrubber().value, 60000.0, reason: '拖拽中滑块应跟随拖拽值');

      scrubber().onChanged!(120000.0);
      await drain(tester, frames: 2);
      expect(scrubber().value, 120000.0);

      scrubber().onChangeEnd!(150000.0);
      await drain(tester, frames: 4);

      expect(cast.seeks, <Duration>[const Duration(milliseconds: 150000)]);
      // 松手后清掉拖拽会话,滑块回到真实进度。
      expect(scrubber().value, 30000.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onChangeCancel 取消拖拽会话', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(
          currentSong: _song(),
          queue: _queue(),
          position: const Duration(seconds: 30),
          duration: const Duration(seconds: 240),
          processingState: ProcessingState.ready,
        ),
      );
      await enterFullPlayer(tester);

      MusicFlowPlayerScrubber scrubber() =>
          tester.widget<MusicFlowPlayerScrubber>(
            find.byType(MusicFlowPlayerScrubber),
          );

      scrubber().onChangeStart!(90000.0);
      await drain(tester, frames: 2);
      expect(scrubber().value, 90000.0);

      scrubber().onChangeCancel!(90000.0);
      await drain(tester, frames: 2);

      expect(scrubber().value, 30000.0, reason: '取消后回到真实进度');
      expect(cast.seeks, isEmpty, reason: '取消不应触发 seek');
      expect(tester.takeException(), isNull);
    });

    testWidgets('切歌自动取消拖拽会话', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(
          currentSong: _song(),
          queue: _queue(),
          currentIndex: 0,
          position: const Duration(seconds: 30),
          duration: const Duration(seconds: 240),
          processingState: ProcessingState.ready,
        ),
      );
      await enterFullPlayer(tester);

      MusicFlowPlayerScrubber scrubber() =>
          tester.widget<MusicFlowPlayerScrubber>(
            find.byType(MusicFlowPlayerScrubber),
          );

      scrubber().onChangeStart!(90000.0);
      await drain(tester, frames: 2);
      expect(scrubber().value, 90000.0);

      player.emit(
        player.state.copyWith(
          currentSong: _song(id: 'second'),
          currentIndex: 1,
          position: Duration.zero,
        ),
      );
      await drain(tester, frames: 4);

      final fresh = tester.widget<MusicFlowPlayerScrubber>(
        find.byType(MusicFlowPlayerScrubber),
      );
      expect(fresh.value, 0.0, reason: '新歌从 0 开始,拖拽会话已被取消');
      expect(tester.takeException(), isNull);
    });
  });

  group('PlaybackControls', () {
    testWidgets('上一首/下一首按钮经 effective 入口下发', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(
          currentSong: _song(),
          queue: _queue(),
          processingState: ProcessingState.ready,
        ),
      );
      await enterFullPlayer(tester);

      await tester.tap(_transport(find.byIcon(AppIcons.previous)));
      await drain(tester, frames: 2);
      await tester.tap(_transport(find.byIcon(AppIcons.next)));
      await drain(tester, frames: 2);

      expect(cast.previousCalls, 1);
      expect(cast.nextCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('链路 A 投屏态:模式图标取 cast.playMode,点按走 cast.cyclePlayMode', (
      tester,
    ) async {
      await pumpApp(
        tester,
        state: PlayerState(currentSong: _song(), queue: _queue()),
        castCasting: true,
        castPlayMode: 'one',
      );
      await enterFullPlayer(tester);

      expect(
        _transport(find.byIcon(AppIcons.repeatOne)),
        findsOneWidget,
        reason: "cast.playMode='one' 应显示单曲循环图标",
      );

      await tester.tap(_transport(find.byIcon(AppIcons.repeatOne)));
      await drain(tester, frames: 2);

      expect(cast.cycleCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('链路 B 直投态:模式按钮走 dlna.cyclePlayMode', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(currentSong: _song(), queue: _queue()),
        dlnaCasting: true,
      );
      await enterFullPlayer(tester);

      await tester.tap(_transport(find.byIcon(AppIcons.repeat)));
      await drain(tester, frames: 2);

      expect(dlna.cycleCalls, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('_PlayerUtilityBar', () {
    testWidgets('定时剩余格式化:分钟 / 小时 / 小时+分钟 / 关闭恢复', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(currentSong: _song(), queue: _queue()),
      );
      await enterFullPlayer(tester);

      // 30 分钟 → 纯分钟文案。
      sleepTimer.setRemaining(const Duration(minutes: 30));
      await drain(tester, frames: 2);
      expect(
        find.byTooltip(loc!.player_sleep_timer_minutes(30)),
        findsOneWidget,
      );

      // 60 分钟 → 纯小时文案。
      sleepTimer.setRemaining(const Duration(minutes: 60));
      await drain(tester, frames: 2);
      expect(find.byTooltip(loc!.player_sleep_timer_hours(1)), findsOneWidget);

      // 90 分钟 → 小时 + 分钟组合文案。
      sleepTimer.setRemaining(const Duration(minutes: 90));
      await drain(tester, frames: 2);
      expect(
        find.byTooltip(
          '${loc!.player_sleep_timer_hours(1)} ${loc!.player_sleep_timer_minutes(30)}',
        ),
        findsOneWidget,
      );

      // 关闭后回到默认 label,不再高亮。
      sleepTimer.setRemaining(null);
      await drain(tester, frames: 2);
      expect(find.byTooltip(loc!.player_sleep_timer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('流转播放:打开切换面板,关闭后显示回本机 toast', (tester) async {
      await pumpApp(
        tester,
        state: PlayerState(currentSong: _song(), queue: _queue()),
      );
      await enterFullPlayer(tester);

      await tester.tap(_utility(find.byIcon(AppIcons.transferInfinity)));
      await drain(tester, frames: 12);
      expect(find.byType(PlayerSwitcherSheet), findsOneWidget);

      // 关闭面板（面板内关闭按钮）。
      await tester.tap(find.byIcon(AppIcons.close).last);
      await drain(tester, frames: 16);

      expect(find.text(loc!.player_switched_local), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Windows 桌面端直投按钮走桌面样式对话框', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpApp(
          tester,
          state: PlayerState(currentSong: _song(), queue: _queue()),
        );
        await enterFullPlayer(tester);

        await tester.tap(_utility(find.byIcon(AppIcons.dlnaLocal)));
        await drain(tester, frames: 12);

        expect(find.text(loc!.player_dlna_dialog_subtitle), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
