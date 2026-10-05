// ============================================================================
// batch30-C —— `lib/widgets/main_scaffold.dart` Widget 层补测
//
// 目标：把 batch29 全量 lcov 里 main_scaffold.dart 的未覆盖行（45–52 / 176–274
// 托盘消息 / 365–425 返回键 / 455 Windows 侧栏文案 / 307–311 网络兜底定时器 /
// 281–287 didUpdateWidget / 369–380 分支越界告警）逐个打起来。
//
// **不改产品代码**：本轮发现的问题只在此注释里记录，不修 lib/。
//
// 踩坑：
// #30C-1 Riverpod 2.6.1：`UncontrolledProviderScope` **没有** overrides 参数，
//        必须是 `ProviderContainer(overrides: [...])` + `UncontrolledProviderScope(
//        container: container, child: ...)`。MainScaffold 依赖 GoRouter（要
//        `StatefulNavigationShell`），所以 child 是 `MaterialApp.router`，壳
//        本体在 `StatefulShellRoute.indexedStack` 的 builder 里造。
// #30C-2 `MainScaffold.initState` 里 `_initTrayListener()` 会给
//        `com.musicflow.app/tray` 这个 BasicMessageChannel **装上 handler**。
//        测试里直接 `await channel.send('toggle_play_pause')` 就能走进 handler
//        ——flutter_test 的 defaultBinaryMessenger 是本地回路，不需要原生层。
//        这是打 176–274 这一段唯一的正门。
// #30C-3 `statusLyricsControllerProvider` 必须用 `extends Mock implements
//        StatusLyricsController` 的桩（`app_settings_page_cov_test.dart` 同款）。
//        真 controller 一构造就起一堆 provider 监听 + 拉 LocalStorage，
//        会让用例挂着一堆 pending timer。
// #30C-4 `playerProvider` 必须用 `playerProvider.overrideWith((ref) => notifier)`
//        塞 `TestPlayerNotifier` 的子类（见 #86-D）：`overrideWithValue` 塞进去
//        的是裸 StateNotifier，`ref.read(playerProvider.notifier).xxx()` 会
//        NoSuchMethodError。另外 `persistPlaybackStateNow()` 在 PlayerNotifier
//        里**有方法体**，子类不继承 ⇒ 托盘 'quit' 必须自己在桩里实现。
// #30C-5 返回键：`await tester.binding.handlePopRoute()` 会遍历
//        WidgetsBindingObserver 调 didPopRoute，Router 的
//        RootBackButtonDispatcher 再把事件递给 `BackButtonListener`。抽屉**关闭**
//        时 DrawerController 没注册自己的 ChildBackButtonDispatcher，所以不会被
//        抽屉抢走（抽屉抢的话 390–392 那条分支就打不到）。
// #30C-6 Windows 侧栏文案看的是 `defaultTargetPlatform`：
//        `debugDefaultTargetPlatformOverride = TargetPlatform.windows` 必须在
//        **用例体内 try/finally 还原**（见 #88-D），写 addTearDown 会被
//        debug variable 变更断言拦下。
// #30C-7 网络兜底：不传 `networkStatusOverride` 时 `_startNetworkObservation()`
//        会起一个 450ms Timer。Testing 环境下 connectivity_plus 没有事件，
//        `networkTypeStream` 走不到；但 **`tester.pump(Duration(ms: 600))`**
//        能把 307–311 那条定时器分支打起来（落到
//        `monitor.currentNetworkType == NetworkType.none` ⇒ offline 条）。
// ============================================================================

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/settings/pages/offline_cached_songs_page.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/navigation_provider.dart';
import 'package:musicflow_client/widgets/main_scaffold.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_network_status_bar.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/player/test_player_notifier.dart';

const BasicMessageChannel<String> _trayChannel = BasicMessageChannel<String>(
  'com.musicflow.app/tray',
  StringCodec(),
);

const MethodChannel _appLifecycleChannel = MethodChannel(
  'com.musicflow.app/app_lifecycle',
);

const ValueKey<String> _drawerKey = ValueKey<String>('b30c-drawer');

// ---------------------------------------------------------------------------
// 桩
// ---------------------------------------------------------------------------

class FakeStatusLyricsController extends Mock
    implements StatusLyricsController {}

/// 全链路 Cast peer 桩：只记调用（#87-D 同款）。
class RecordingCastPeer extends CastPeerController {
  RecordingCastPeer(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> toggle() async {
    calls.add('toggle');
  }

  @override
  Future<void> previous() async {
    calls.add('previous');
  }

  @override
  Future<void> next() async {
    calls.add('next');
  }

  @override
  Future<void> setVolume(int volume) async {
    calls.add('setVolume:$volume');
  }
}

/// DLNA 直投桩：只保 `isCasting == false`，让所有路由落到本机/投屏分支。
class RecordingDlnaCast extends DlnaCastNotifier {
  RecordingDlnaCast(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> toggle() async {
    calls.add('toggle');
  }

  @override
  Future<void> setVolume(int volume) async {
    calls.add('setVolume:$volume');
  }
}

/// PlayerNotifier 桩：`persistPlaybackStateNow()` 在 PlayerNotifier 里有方法体，
/// TestPlayerNotifier 用 noSuchMethod 兜过去（返回 null），这里显式实现以便断言。
class B30cPlayerNotifier extends TestPlayerNotifier {
  B30cPlayerNotifier(super.state);

  final List<double> volumes = <double>[];
  int favoriteCount = 0;
  int persistCount = 0;

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    state = state.copyWith(volume: volume);
  }

  @override
  Future<void> toggleFavorite() async {
    favoriteCount += 1;
  }

  @override
  Future<void> persistPlaybackStateNow() async {
    persistCount += 1;
  }
}

// ---------------------------------------------------------------------------
// 仿真台
// ---------------------------------------------------------------------------

class MainScaffoldBench {
  MainScaffoldBench({
    this.branchCount = 2,
    this.initialLocation = '/home',
    this.networkStatusOverride = MusicFlowNetworkStatus.online,
    this.branchNavigatorKeys,
    this.drawerOverride,
    this.size = const Size(1280, 900),
  });

  final int branchCount;
  final String initialLocation;
  MusicFlowNetworkStatus? networkStatusOverride;
  final List<GlobalKey<NavigatorState>>? branchNavigatorKeys;
  final Widget? drawerOverride;
  final Size size;

  late ConnectivityMonitor connectivity;
  late RecordingCastPeer cast;
  late RecordingDlnaCast dlna;
  late B30cPlayerNotifier player;
  late FakeStatusLyricsController lyrics;
  late GoRouter router;
  late ProviderContainer container;

  final FocusNode homeFocus = FocusNode();

  /// 运行时切换 `networkStatusOverride`（null ⇄ 值），用来触发 didUpdateWidget。
  final ValueNotifier<MusicFlowNetworkStatus?> status = ValueNotifier(null);

  AppLocalizations? loc;

  /// 分支导航器 key：始终按 branchCount 生成，与传给 MainScaffold 的
  /// `branchNavigatorKeys`（可被外部换成空数组以打越界分支）解耦。
  late List<GlobalKey<NavigatorState>> branchKeys;

  Future<void> pump(WidgetTester tester) async {
    status.value = networkStatusOverride;

    SharedPreferences.setMockInitialValues(<String, Object>{});
    Logger.setLoggingEnabled(false);
    addTearDown(homeFocus.dispose);
    addTearDown(status.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    connectivity = ConnectivityMonitor(AddressPool(Dio()));
    addTearDown(connectivity.stop);

    final localLyrics = FakeStatusLyricsController();
    lyrics = localLyrics;

    branchKeys = List<GlobalKey<NavigatorState>>.generate(
      branchCount,
      (_) => GlobalKey<NavigatorState>(),
    );

    container = ProviderContainer(
      overrides: <Override>[
        // 非空地址 + 无 token ⇒ RandomSongsPush 不启连接 Timer（避免 pending）。
        activeAddressProvider.overrideWith(
          (ref) => const ServerAddress(
            id: 'test-addr',
            libraryId: 'test-lib',
            label: '测试服务器',
            url: 'https://music.example.test',
            priority: 1,
          ),
        ),
        connectivityMonitorProvider.overrideWithValue(connectivity),
        playerProvider.overrideWith((ref) => B30cPlayerNotifier(PlayerState())),
        castPeerControllerProvider.overrideWith(
          (Ref ref) => RecordingCastPeer(ref),
        ),
        dlnaCastProvider.overrideWith((Ref ref) => RecordingDlnaCast(ref)),
        statusLyricsControllerProvider.overrideWithValue(localLyrics),
      ],
    );
    addTearDown(container.dispose);

    // 立刻落定三个桩实例，不依赖 widget 树先走到哪条分支（#125-D / #126-D）。
    player = container.read(playerProvider.notifier) as B30cPlayerNotifier;
    cast = container.read(castPeerControllerProvider.notifier)
        as RecordingCastPeer;
    dlna = container.read(dlnaCastProvider.notifier) as RecordingDlnaCast;

    final localKeys = branchKeys;
    final localStatus = status;
    final localHomeFocus = homeFocus;
    final drawer = drawerOverride;
    final overrideKeys = branchNavigatorKeys;

    router = GoRouter(
      initialLocation: initialLocation,
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) {
            return ValueListenableBuilder<MusicFlowNetworkStatus?>(
              valueListenable: localStatus,
              builder: (context, value, _) {
                return MainScaffold(
                  navigationShell: navigationShell,
                  branchNavigatorKeys: overrideKeys ?? localKeys,
                  drawerOverride: drawer,
                  miniPlayerOverride: const SizedBox.shrink(),
                  showMiniPlayerOverride: false,
                  networkStatusOverride: value,
                );
              },
            );
          },
          branches: <StatefulShellBranch>[
            StatefulShellBranch(
              navigatorKey: localKeys[0],
              routes: <RouteBase>[
                GoRoute(
                  path: '/home',
                  builder: (context, state) =>
                      _BranchPage('Home root', focusNode: localHomeFocus),
                  routes: <RouteBase>[
                    GoRoute(
                      path: 'detail',
                      builder: (context, state) =>
                          const _BranchPage('Home detail'),
                    ),
                  ],
                ),
              ],
            ),
            if (branchCount > 1)
              StatefulShellBranch(
                navigatorKey: localKeys[1],
                routes: <RouteBase>[
                  GoRoute(
                    path: '/songs',
                    builder: (context, state) =>
                        const _BranchPage('Songs root'),
                  ),
                ],
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          builder: (context, child) {
            loc = AppLocalizations.of(context);
            return child!;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 向 tray 通道**注入一条来自平台的消息**（#30C-2 续）。
  ///
  /// 注意方向：MainScaffold 的 `_trayChannel.setMessageHandler` 是注册在
  /// `TestDefaultBinaryMessenger._inboundHandlers` 上的，**必须**用
  /// `handlePlatformMessage` 注入；反过来用 `channel.send()` 发出去的话，
  /// 那是「framework → platform」方向，走 deploy/真引擎，没人回包，测试直接挂死。
  ///
  /// 另一半坑：`handlePlatformMessage` 返回的 Future **不能 await**（SDK 注释
  /// 明说 testWidgets 在 FakeAsync zone，handler 里有 await 时会永久 pending）。
  /// 这里丢掉返回值，随后靠 `settle()` 的 pump 把微任务推完。
  void tray(String message) {
    unawaited(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _trayChannel.name,
        _trayChannel.codec.encodeMessage(message),
        null,
      ),
    );
  }
}

class _BranchPage extends StatelessWidget {
  const _BranchPage(this.label, {this.focusNode});

  final String label;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label),
            Focus(
              focusNode: focusNode,
              child: Container(
                width: 48,
                height: 24,
                key: ValueKey<String>('b30c-focus-$label'),
                color: const Color(0xFF000000),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 固定帧推进代替 `pumpAndSettle`（#85-D / #140-D 同款）。
Future<void> settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  late MainScaffoldBench bench;

  setUp(() {
    bench = MainScaffoldBench();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_appLifecycleChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kWindowsWindowChannel, null);
  });

  group('main_scaffold 抽屉入口', () {
    testWidgets('openMusicFlowAppDrawer 记下触发焦点并打开抽屉', (tester) async {
      final drawerBench = MainScaffoldBench(
        drawerOverride: Container(
          key: _drawerKey,
          width: 320,
          color: const Color(0xFF112233),
        ),
      );
      await drawerBench.pump(tester);
      expect(
        drawerBench.container.read(currentVisibleBranchIndexProvider),
        discoverBranchIndex,
      );

      drawerBench.homeFocus.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(bench.loc, isNull);
      expect(drawerBench.loc, isNotNull);
      expect(find.byKey(_drawerKey), findsNothing);

      openMusicFlowAppDrawer();
      await tester.pumpAndSettle();

      expect(find.byKey(_drawerKey), findsOneWidget);
      expect(find.text('Home root'), findsOneWidget);
    });
  });

  group('main_scaffold 托盘 volume 通道', () {
    testWidgets('volume:<v> 经 ThrottledVolumeSender 下发本机音量', (tester) async {
      await bench.pump(tester);

      bench.tray('volume:0.42');
      await settle(tester);

      expect(bench.player.volumes, <double>[0.42]);
      expect(bench.cast.calls, isEmpty);
      expect(bench.dlna.calls, isEmpty);

      // 非数字负载：解析失败，不落任何下发。
      bench.tray('volume:not-a-number');
      await settle(tester);
      expect(bench.player.volumes, hasLength(1));
    });
  });

  group('main_scaffold 托盘歌词窗通道', () {
    testWidgets('queue_jump / switch_pull / switch_push / switch_pick 路由到歌'
        '词控制器', (tester) async {
      await bench.pump(tester);
      when(() => bench.lyrics.jumpToQueueIndex(any())).thenAnswer(
        (_) async {},
      );
      when(() => bench.lyrics.handoffSwitchRow(any(), push: any(named: 'push')))
          .thenAnswer((_) async {});
      when(() => bench.lyrics.pickSwitchRow(any())).thenAnswer((_) async {});

      bench.tray('queue_jump:3');
      await settle(tester);
      bench.tray('switch_pull:1');
      await settle(tester);
      bench.tray('switch_push:1');
      await settle(tester);
      bench.tray('switch_pick:2');
      await settle(tester);

      verify(() => bench.lyrics.jumpToQueueIndex(3)).called(1);
      verify(() => bench.lyrics.handoffSwitchRow(1, push: false)).called(1);
      verify(() => bench.lyrics.handoffSwitchRow(1, push: true)).called(1);
      verify(() => bench.lyrics.pickSwitchRow(2)).called(1);
    });

    testWidgets('switch_player_open / switch_close / toggle_status_lyrics 走'
        '同一条路由', (tester) async {
      await bench.pump(tester);
      when(() => bench.lyrics.requestSwitchList()).thenAnswer((_) async {});
      when(() => bench.lyrics.stopSwitchAutoRefresh()).thenReturn(null);
      when(() => bench.lyrics.toggle()).thenAnswer((_) async {});

      bench.tray('switch_player_open');
      await settle(tester);
      bench.tray('switch_close');
      await settle(tester);
      bench.tray('toggle_status_lyrics');
      await settle(tester);

      verify(() => bench.lyrics.requestSwitchList()).called(1);
      verify(() => bench.lyrics.stopSwitchAutoRefresh()).called(1);
      verify(() => bench.lyrics.toggle()).called(1);
    });

    testWidgets('未知托盘消息落到 switch 默认分支并返回空串', (tester) async {
      await bench.pump(tester);

      bench.tray('not_a_known_command');
      await settle(tester);
      bench.tray('switch_pull:oops');
      await settle(tester);
      bench.tray('queue_jump:x');
      await settle(tester);

      // 解析失败 / 未知 ⇒ 不产生任何歌词控制器调用（走到 273 行空 return）。
      verifyNever(() => bench.lyrics.handoffSwitchRow(
            any(),
            push: any(named: 'push'),
          ));
      verifyNever(() => bench.lyrics.jumpToQueueIndex(any()));
      verifyNever(() => bench.lyrics.pickSwitchRow(any()));
      verifyNever(() => bench.lyrics.toggle());
      expect(bench.cast.calls, isEmpty);
    });
  });

  group('main_scaffold 托盘播放控制通道', () {
    testWidgets('toggle_play_pause / previous / next 落到当前链路控制器',
        (tester) async {
      await bench.pump(tester);

      bench.tray('toggle_play_pause');
      await settle(tester);
      bench.tray('previous');
      await settle(tester);
      bench.tray('next');
      await settle(tester);

      expect(bench.cast.calls, <String>['toggle', 'previous', 'next']);
    });

    testWidgets('cycle_playback_mode 本机链路循环四态，toggle_like 落 Preference',
        (tester) async {
      await bench.pump(tester);
      final before = bench.container.read(playerProvider).playbackMode;

      bench.tray('cycle_playback_mode');
      await settle(tester);
      expect(bench.container.read(playerProvider).playbackMode, isNot(before));

      bench.tray('toggle_like');
      await settle(tester);
      expect(bench.player.favoriteCount, 1);
    });
  });

  group('main_scaffold 托盘 quit', () {
    testWidgets('quit 先落盘播放状态再调原生 quit', (tester) async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kWindowsWindowChannel, (call) async {
        methods.add(call.method);
        return null;
      });

      await bench.pump(tester);
      expect(bench.player.persistCount, 0);

      bench.tray('quit');
      await settle(tester);

      expect(bench.player.persistCount, 1);
      expect(methods, <String>['quit']);
      // 进程没被真实杀掉：首页还在。
      expect(find.text('Home root'), findsOneWidget);
    });
  });

  group('main_scaffold 返回键', () {
    testWidgets('分支子页返回 → 弹掉分支导航器一层', (tester) async {
      await bench.pump(tester);
      bench.router.go('/home/detail');
      await tester.pumpAndSettle();
      expect(find.text('Home detail'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Home detail'), findsNothing);
      expect(find.text('Home root'), findsOneWidget);
    });

    testWidgets('非首页分支到达根 → 切回音乐流分支', (tester) async {
      final songs = MainScaffoldBench(initialLocation: '/songs');
      await songs.pump(tester);
      expect(find.text('Songs root'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Songs root'), findsNothing);
      expect(find.text('Home root'), findsOneWidget);
      expect(
        songs.container.read(currentVisibleBranchIndexProvider),
        discoverBranchIndex,
      );
    });

    testWidgets('首页根 MissingPluginException → 保持当前路由', (tester) async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_appLifecycleChannel, (call) async {
        methods.add(call.method);
        throw MissingPluginException('no activity');
      });

      await bench.pump(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(methods, <String>['moveTaskToBack']);
      expect(find.text('Home root'), findsOneWidget);
    });

    testWidgets('首页根 PlatformException → 保持当前路由', (tester) async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_appLifecycleChannel, (call) async {
        methods.add(call.method);
        throw PlatformException(code: 'failed');
      });

      await bench.pump(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(methods, <String>['moveTaskToBack']);
      expect(find.text('Home root'), findsOneWidget);
    });

    testWidgets('branchNavigatorKeys 越界 → 先告警再走 fallback', (tester) async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_appLifecycleChannel, (call) async {
        methods.add(call.method);
        return null;
      });

      final broken = MainScaffoldBench(
        branchNavigatorKeys: const <GlobalKey<NavigatorState>>[],
      );
      await broken.pump(tester);
      expect(find.text('Home root'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // 370–380 的 index 越界分支不打刀警告也无 dev null 异常，
      // 最终仍落到 moveAppToBackground。
      expect(methods, <String>['moveTaskToBack']);
      expect(find.text('Home root'), findsOneWidget);
    });
  });

  group('main_scaffold 侧栏曲库入口', () {
    /// 只看侧栏内部的入口文案 —— 推进来的页面标题同文案时不会串台。
    Finder sidebarEntry(String label) => find.descendant(
          of: find.byKey(
            const ValueKey<String>('musicflow-expanded-navigation'),
          ),
          matching: find.text(label),
        );

    testWidgets('六个库入口各推一页到内容区分支导航器', (tester) async {
      await bench.pump(tester);
      final branchNavigator = bench.branchKeys[0].currentState!;
      expect(branchNavigator.canPop(), isFalse);

      final labels = <String>[
        bench.loc!.widgets_playlists,
        bench.loc!.widgets_music,
        bench.loc!.widgets_artists,
        bench.loc!.widgets_albums,
        bench.loc!.widgets_i_like,
        bench.loc!.offline_cache_cached_songs_title,
      ];
      for (final label in labels) {
        expect(sidebarEntry(label), findsOneWidget,
            reason: '侧栏缺少入口 $label');
        await tester.tap(sidebarEntry(label));
        await settle(tester);
      }

      // `_openPageInContentArea` 走的是**分支**导航器：侧栏一直在，且分支栈能弹。
      expect(branchNavigator.canPop(), isTrue);
      expect(find.text(bench.loc!.widgets_playlists), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('分支导航器缺失时回落到根导航器推页', (tester) async {
      final fallback = MainScaffoldBench(
        branchNavigatorKeys: const <GlobalKey<NavigatorState>>[],
      );
      await fallback.pump(tester);

      await tester.tap(sidebarEntry(fallback.loc!.offline_cache_cached_songs_title));
      await settle(tester);

      expect(find.byType(OfflineCachedSongsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('main_scaffold 平台文案与网络状态', () {
    testWidgets('Windows 桌面端侧栏入口文案为主页', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await bench.pump(tester);
        expect(bench.loc!.widgets_home, isNotEmpty);
        expect(find.text(bench.loc!.widgets_home), findsOneWidget);
        expect(find.text(bench.loc!.widgets_music_flow), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('未注入 networkStatus 时兜底定时器落到 offline 条', (tester) async {
      final offline = MainScaffoldBench(networkStatusOverride: null);
      await offline.pump(tester);
      expect(find.byType(MusicFlowNetworkStatusBar), findsOneWidget);

      // 450ms 兜底定时器在 pump 到 600ms 时落地。
      await tester.pump(const Duration(milliseconds: 600));
      await settle(tester);

      expect(find.text(offline.loc!.widgets_network_offline_title),
          findsOneWidget);
    });

    testWidgets('didUpdateWidget 在 override 进出时重启/停止网络观测',
        (tester) async {
      final live = MainScaffoldBench(networkStatusOverride: null);
      await live.pump(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await settle(tester);
      expect(
        find.text(live.loc!.widgets_network_offline_title),
        findsOneWidget,
      );

      // 重新注入 override ⇒ 走 didUpdateWidget 的「有 override → 停观测」分支。
      live.status.value = MusicFlowNetworkStatus.online;
      await tester.pumpAndSettle();
      expect(find.text(live.loc!.widgets_network_offline_title), findsNothing);

      // 再撤掉 override ⇒ 「回到 null → 重启观测」，450ms 后重新落到 offline。
      live.status.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await settle(tester, frames: 10);
      await tester.pumpAndSettle();
      expect(
        find.text(live.loc!.widgets_network_offline_title),
        findsOneWidget,
      );
    });
  });
}
