// player_switcher.dart 的缺口补齐测试。
//
// 这个文件对外只有两件东西：
//   - PeerCastRow：流转行 / 弹窗里的**单个远端设备行**（队列摘要 + 拉/推接续按钮）；
//   - PlayerSwitcherSheet：切换播放器的 bottom sheet（本机 / 停止投屏 / 远端列表 + 刷新）。
//
// 要测它必须先把 provider 换成桩：
//   1) playerProvider             —— 只看 queue 是否为空（决定「有没有本机现场可推」）；
//   2) castPeerControllerProvider —— activePeer / loadingPeers / offline + loadPeers、
//      switchTo、backToLocal、stopCasting、pull、push；
//   3) peerNowPlayingProvider     —— 那是个**死循环 StreamProvider**（每 5s 重拉一次），
//      不覆盖会挂起并留一个 pending timer，必须 override 成单值流。
//
// 桩的选择上有个坑：PlayerNotifier 是抽象类且**构造函数里就 _init()**（会去建
// just_audio / AudioService），所以不能直接继承它——仓库里有现成的 TestPlayerNotifier
// （implements PlayerNotifier + noSuchMethod），直接复用。CastPeerController 反过来是
// **具体类**（构造只做 super(const CastPeerState())），继承覆盖几个方法即可，没副作用。
//
// 其他坑位备忘：
//   a) 置灰的接续按钮 onPressed == null。别用 find.bySemanticsLabel：MusicFlowPressable
//      默认 semanticsMode 是 singleNode，压根不产语义节点，语义查找必然 0 命中；改成按
//      **最小 34x34**（接续按钮 minimumSize: Size.square(34)，行主体是默认的 48）筛
//      MusicFlowPressable，Row 里拉在前、推在后；
//   b) 弹窗里的 sheet 是**路由**装的，而「关掉自己」走的正是 Navigator.pop()，所以测试
//      树必须给一个真 Navigator（不能用抽象的 Page，用 onGenerateRoute + 首帧后 push）；
//   c) 路由 pop/进场都有动画：**退场 during 动画期间 widget 还挂在树上**，断言「关窗了」
//      得给到 600ms 以上，不能用一次 0 时长的 pump；
//   d) loadPeers 故意延迟 50ms，这样「正在加载…」这一帧才抓得住（0 延时会在同一次
//      pump 里直接跑完，loading 分支根本没法断言）；
//   e) 同一个 testWidgets 里第二次 pumpWidget 换 ProviderScope 时，override 闭包不一定
//      在当帧执行（provider 是懒读的），所以**一个用例只开一屏**，桩用文件级 lastFake 抓。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/components/music_flow_message.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/player_switcher.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

// 共用桩在同级目录上一层（test/ 不在 package 的 lib 里，只能用相对路径）。
import '../test_player_notifier.dart';

late AppLocalizations loc;

/// 最近一次建出来的控制器桩（override 闭包里写）。
_CastFake? lastFake;

class _CastFake extends CastPeerController {
  _CastFake(super.ref);

  List<PeerInfo> peers = const <PeerInfo>[];
  bool switchOk = true;
  bool pushOk = true;
  bool pullOk = true;

  int loadCalls = 0;
  int pullCalls = 0;
  int pushCalls = 0;
  int switchCalls = 0;
  int backToLocalCalls = 0;
  bool lastResumeLocal = false;
  int stopCastingCalls = 0;

  /// 随便改状态就够了：弹窗只读 activePeer / loadingPeers / offline。
  void apply({
    PeerInfo? activePeer,
    bool loadingPeers = false,
    bool offline = false,
  }) {
    state = CastPeerState(
      activePeer: activePeer,
      loadingPeers: loadingPeers,
      offline: offline,
    );
  }

  @override
  Future<List<PeerInfo>> loadPeers() async {
    loadCalls += 1;
    // 留一帧余量：让「正在加载…」能被稳定断言。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return peers;
  }

  @override
  Future<bool> switchTo(PeerInfo peer) async {
    switchCalls += 1;
    return switchOk;
  }

  @override
  Future<bool> pushLocalToPeer(PeerInfo peer) async {
    pushCalls += 1;
    return pushOk;
  }

  @override
  Future<bool> pullPeerToLocal(PeerInfo peer) async {
    pullCalls += 1;
    return pullOk;
  }

  @override
  Future<void> backToLocal({bool resumeLocal = false}) async {
    backToLocalCalls += 1;
    lastResumeLocal = resumeLocal;
  }

  @override
  Future<void> stopCasting() async {
    stopCastingCalls += 1;
  }
}

PeerInfo _peer(
  String id,
  String name, {
  String kind = 'dlna',
  bool self = false,
  bool available = true,
}) =>
    PeerInfo(peerId: id, name: name, kind: kind, available: available, self: self);

PeerNowPlaying _playing(String title, {String artist = '周杰伦', int total = 12}) =>
    PeerNowPlaying(
      isActive: true,
      currentIndex: 0,
      total: total,
      title: title,
      artist: artist,
    );

List<Song> _queue(int length) => List<Song>.generate(
  length,
  (int i) => Song(id: 'q$i', title: 'Q$i'),
);

Override _playerOverride(int queueLength) =>
    playerProvider.overrideWith(
      (ref) => TestPlayerNotifier(PlayerState(queue: _queue(queueLength))),
    );

Override _peerNowOverride(String peerId, PeerNowPlaying? now) =>
    peerNowPlayingProvider(peerId)
        .overrideWith((ref) => Stream<PeerNowPlaying?>.value(now));

/// 接续按钮：最小 34x34 的 MusicFlowPressable（拉在前、推在后）。
/// 必须用 descendant 限定到某一行里面，否则弹窗里别的 34x34 按钮会混进来。
Finder _handoffIn(Finder scope) => find.descendant(
  of: scope,
  matching: find.byWidgetPredicate(
    (Widget w) =>
        w is MusicFlowPressable && w.minimumSize == const Size.square(34),
  ),
);

Future<void> _pumpRow(
  WidgetTester tester, {
  required PeerInfo peer,
  required PeerNowPlaying? now,
  int localQueueLength = 2,
  bool activePeer = false,
  Future<void> Function()? onSwitch,
  Future<void> Function(bool push)? onHandoff,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      _playerOverride(localQueueLength),
      castPeerControllerProvider.overrideWith((ref) {
        final c = _CastFake(ref);
        c.apply(activePeer: activePeer ? peer : null);
        lastFake = c;
        return c;
      }),
      _peerNowOverride(peer.peerId, now),
    ],
    child: MediaQuery(
      data: const MediaQueryData(size: Size(900, 900)),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: MusicFlowTapAnchorScope(
            child: Center(
              child: SizedBox(
                width: 760,
                child: PeerCastRow(
                  peer: peer,
                  selected: false,
                  onSwitch: onSwitch ?? (() async {}),
                  onHandoff: onHandoff ?? ((bool _) async {}),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

/// sheet 的第一屏：只有 root 页，首帧后自己 push 出 sheet 页。
class _SheetHost extends StatefulWidget {
  const _SheetHost();

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pushNamed('sheet');
    });
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox(key: ValueKey<String>('root'));
}

Finder _actionRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(MusicFlowActionRow),
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<PeerInfo> peers,
  PeerInfo? activePeer,
  bool loadingPeers = false,
  bool offline = false,
  bool switchOk = true,
  bool pushOk = true,
  bool pullOk = true,
  int localQueueLength = 1,
  PeerInfo? playingPeer,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      _playerOverride(localQueueLength),
      castPeerControllerProvider.overrideWith((ref) {
        final c = _CastFake(ref);
        c.peers = peers;
        c.switchOk = switchOk;
        c.pushOk = pushOk;
        c.pullOk = pullOk;
        c.apply(
          activePeer: activePeer,
          loadingPeers: loadingPeers,
          offline: offline,
        );
        lastFake = c;
        return c;
      }),
      for (final p in peers) _peerNowOverride(p.peerId, null),
      if (playingPeer != null)
        _peerNowOverride(playingPeer.peerId, _playing('稻香')),
    ],
    child: MediaQuery(
      data: const MediaQueryData(size: Size(900, 900)),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: const _TestOverlay(),
      ),
    ),
  ));
  // 帧 1：root 建好 -> 回调 push sheet
  await tester.pump();
  // 帧 2：sheet 建好 -> initState 挂的回调触发 _reload（loadPeers 还没回）
  await tester.pump();
}

/**
 * 显式 Overlay 壳：Toast 是插进 Overlay 的 OverlayEntry，而 `showMusicFlowToast`
 * 走的是 `Overlay.maybeOf(context, rootOverlay: true)`。测试树里光靠 MaterialApp
 * 拿不到这个祖先（rootOverlay 找的是最顶层 Overlay），toast 会静默不显示——
 * 这里补一层 Overlay，保证提示链路真的跑通。
 */
class _TestOverlay extends StatelessWidget {
  const _TestOverlay();

  @override
  Widget build(BuildContext context) => Overlay(
    initialEntries: <OverlayEntry>[
      OverlayEntry(
        builder: (BuildContext _) => const _NavigatorHost(),
      ),
    ],
  );
}

class _NavigatorHost extends StatelessWidget {
  const _NavigatorHost();

  @override
  Widget build(BuildContext context) => Navigator(
    initialRoute: 'root',
    onGenerateRoute: (RouteSettings settings) {
      if (settings.name == 'root') {
        return MaterialPageRoute<void>(
          builder: (BuildContext _) => const _SheetHost(),
        );
      }
      return MaterialPageRoute<void>(
        builder: (BuildContext _) => MusicFlowTapAnchorScope(
          child: PlayerSwitcherSheet(),
        ),
      );
    },
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

_CastFake _fake() {
  final c = lastFake;
  if (c == null) throw StateError('controller 桩没建出来');
  return c;
}

void main() {
  setUp(() {
    loc = lookupAppLocalizations(const Locale('zh'));
  });

  group('PeerCastRow · 队列摘要', () {
    testWidgets('now 为空 -> 「状态未知」', (WidgetTester tester) async {
      await _pumpRow(tester, peer: _peer('p1', '主卧音箱'), now: null);

      expect(find.text('主卧音箱'), findsOneWidget);
      expect(find.text(loc.player_peer_state_unknown), findsOneWidget);
      expect(find.text(loc.player_peer_not_playing), findsNothing);
    });

    testWidgets('now 有曲目 -> 显示「歌名 - 歌手」',
        (WidgetTester tester) async {
      await _pumpRow(
        tester,
        peer: _peer('p2', '客厅音箱'),
        now: _playing('稻香'),
      );

      expect(find.text('稻香 - 周杰伦'), findsOneWidget);
      expect(find.text(loc.player_peer_state_unknown), findsNothing);
    });

    testWidgets('now 在无歌手时只出歌名，且仍算「在播」',
        (WidgetTester tester) async {
      await _pumpRow(
        tester,
        peer: _peer('p2b', '客厅音箱'),
        now: _playing('稻香', artist: ''),
      );

      expect(find.text('稻香'), findsOneWidget);
      expect(find.text(loc.player_peer_state_unknown), findsNothing);
    });

    testWidgets('now 在播但无曲目 -> 「未在播放」', (WidgetTester tester) async {
      await _pumpRow(
        tester,
        peer: _peer('p3', '书房音箱'),
        now: PeerNowPlaying(
          isActive: true,
          currentIndex: -1,
          total: 0,
          title: '',
        ),
      );

      expect(
        find.text(loc.player_peer_not_playing),
        findsOneWidget,
        reason: 'trackLabel 为空 => 未在播放',
      );
    });
  });

  group('PeerCastRow · 接续按钮', () {
    testWidgets('点行主体 -> 切控制目标', (WidgetTester tester) async {
      var switched = 0;
      await _pumpRow(
        tester,
        peer: _peer('p4', '卧室音箱'),
        now: null,
        onSwitch: () async {
          switched += 1;
        },
      );

      await tester.tap(find.byType(MusicFlowPressable).first);
      await tester.pump();
      expect(switched, 1);
    });

    testWidgets('远端在播 + 本机有队列 -> 拉/推都可用，方向对上',
        (WidgetTester tester) async {
      final hits = <bool>[];
      await _pumpRow(
        tester,
        peer: _peer('p5', '主卧'),
        now: _playing('稻香'),
        localQueueLength: 2,
        onHandoff: (bool push) async {
          hits.add(push);
        },
      );

      final buttons = _handoffIn(find.byType(PeerCastRow));
      expect(buttons, findsNWidgets(2), reason: '拉 + 推');
      final pull = buttons.first;
      final push = buttons.last;

      expect(tester.widget<MusicFlowPressable>(pull).onPressed, isNotNull);
      expect(tester.widget<MusicFlowPressable>(push).onPressed, isNotNull);

      await tester.tap(pull);
      await tester.pump();
      await tester.tap(push);
      await tester.pump();

      expect(
        hits,
        <bool>[false, true],
        reason: '拉=false(接回本机) 推=true(推到音箱)',
      );
    });

    testWidgets('远端没在播 -> 拉按钮置灰，点了不回调',
        (WidgetTester tester) async {
      var hits = 0;
      await _pumpRow(
        tester,
        peer: _peer('p6', '没在播的音箱'),
        now: null,
        localQueueLength: 2,
        onHandoff: (bool _) async {
          hits += 1;
        },
      );

      final pull = _handoffIn(find.byType(PeerCastRow)).first;
      expect(tester.widget<MusicFlowPressable>(pull).onPressed, isNull,
          reason: 'canPull 要求 now.isActive && total>0');
      await tester.tap(pull);
      await tester.pump();
      expect(hits, 0);
    });

    testWidgets('本机队列空 -> 推按钮置灰', (WidgetTester tester) async {
      var hits = 0;
      await _pumpRow(
        tester,
        peer: _peer('p7', '可推的音箱'),
        now: _playing('稻香', total: 3),
        localQueueLength: 0,
        onHandoff: (bool _) async {
          hits += 1;
        },
      );

      final push = _handoffIn(find.byType(PeerCastRow)).last;
      expect(tester.widget<MusicFlowPressable>(push).onPressed, isNull,
          reason: '本机没现场可推');
      await tester.tap(push);
      await tester.pump();
      expect(hits, 0);
    });

    testWidgets('投屏态（activePeer 非空）-> 推按钮也置灰',
        (WidgetTester tester) async {
      var hits = 0;
      await _pumpRow(
        tester,
        peer: _peer('p8', '投屏中的音箱'),
        now: _playing('稻香', total: 3),
        localQueueLength: 5,
        activePeer: true,
        onHandoff: (bool _) async {
          hits += 1;
        },
      );

      final push = _handoffIn(find.byType(PeerCastRow)).last;
      expect(tester.widget<MusicFlowPressable>(push).onPressed, isNull,
          reason: '投屏态下本机队列只是远端镜像，没有「现场」可推');
      await tester.tap(push);
      await tester.pump();
      expect(hits, 0);
    });
  });

  group('PlayerSwitcherSheet · 设备列表', () {
    testWidgets('先「正在加载…」，拉完为空再显示「没有其他播放端」',
        (WidgetTester tester) async {
      await _pumpSheet(tester, peers: const <PeerInfo>[]);

      expect(find.text(loc.player_loading_peers), findsOneWidget);
      expect(find.text(loc.player_no_other_players), findsNothing);

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(loc.player_no_other_players), findsOneWidget);
      expect(find.text(loc.player_loading_peers), findsNothing);
    });

    testWidgets('self / 不可用的设备被过滤掉', (WidgetTester tester) async {
      await _pumpSheet(
        tester,
        peers: <PeerInfo>[
          _peer('self', '我自己', self: true),
          _peer('off', '离线的音箱', available: false),
          _peer('r1', '主卧音箱'),
          _peer('r2', '客厅音箱'),
        ],
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('主卧音箱'), findsOneWidget);
      expect(find.text('客厅音箱'), findsOneWidget);
      expect(find.text('我自己'), findsNothing, reason: 'self 要过滤');
      expect(find.text('离线的音箱'), findsNothing, reason: '不可用要过滤');
    });

    testWidgets('点本机行 -> 回本机（resumeLocal）后关掉弹窗',
        (WidgetTester tester) async {
      await _pumpSheet(tester, peers: const <PeerInfo>[]);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(loc.player_source_local_title), findsOneWidget);
      expect(find.text(loc.player_source_local_desc), findsOneWidget);

      await tester.tap(_actionRow(loc.player_source_local_title));
      await _settle(tester);

      expect(_fake().backToLocalCalls, 1, reason: '要真的回本机');
      expect(_fake().lastResumeLocal, true, reason: '快照当时在播则续播本机');
      expect(find.byType(MusicFlowBottomSheet), findsNothing,
          reason: 'backToLocal 后 Navigator.pop');
      expect(find.byKey(const ValueKey<String>('root')), findsOneWidget);
    });

    testWidgets('投屏中额外出现「停止投屏」行，点了也关窗',
        (WidgetTester tester) async {
      await _pumpSheet(
        tester,
        peers: const <PeerInfo>[],
        activePeer: _peer('p9', '主卧音箱'),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(loc.player_stop_cast), findsOneWidget);
      expect(
        find.text(loc.player_stop_cast_subtitle('主卧音箱')),
        findsOneWidget,
      );
      expect(
        find.text(loc.player_source_casting),
        findsOneWidget,
        reason: '本机行副标题切成「投屏中」',
      );

      await tester.tap(_actionRow(loc.player_stop_cast));
      await _settle(tester);

      expect(_fake().stopCastingCalls, 1, reason: '要真的停投屏');
      expect(find.byType(MusicFlowBottomSheet), findsNothing);
    });

    testWidgets('投屏中且设备离线 -> 本机行副标题是「离线」',
        (WidgetTester tester) async {
      await _pumpSheet(
        tester,
        peers: const <PeerInfo>[],
        activePeer: _peer('p10', '断线音箱'),
        offline: true,
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(loc.player_source_offline), findsOneWidget,
          reason: '离线优先于「投屏中」');
      expect(find.text(loc.player_source_casting), findsNothing);
    });
  });

  group('PlayerSwitcherSheet · 远端行与刷新', () {
    testWidgets('点远端行：切换成功 -> 关窗', (WidgetTester tester) async {
      await _pumpSheet(tester, peers: <PeerInfo>[_peer('ok1', '可切换的音箱')]);
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const ValueKey<String>('sheet-peer-ok1')));
      await _settle(tester);

      expect(_fake().switchCalls, 1);
      expect(find.byType(MusicFlowBottomSheet), findsNothing,
          reason: 'switchTo 成功 -> pop');
    });

    testWidgets('点远端行：切换失败 -> 留在窗里并提示',
        (WidgetTester tester) async {
      await _pumpSheet(
        tester,
        peers: <PeerInfo>[_peer('bad1', '切不动的音箱')],
        switchOk: false,
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const ValueKey<String>('sheet-peer-bad1')));
      await _settle(tester);

      expect(find.byType(MusicFlowBottomSheet), findsOneWidget,
          reason: 'switchTo 失败时弹窗不关');
      expect(find.text(loc.player_cast_failed('切不动的音箱')), findsOneWidget);
    });

    testWidgets('加载中 -> 「刷新」行置灰并转圈',
        (WidgetTester tester) async {
      await _pumpSheet(tester, peers: const <PeerInfo>[], loadingPeers: true);

      expect(find.text(loc.player_refresh_players), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'trailing 转圈');
      expect(
        tester
            .widget<MusicFlowActionRow>(_actionRow(loc.player_refresh_players))
            .onPressed,
        isNull,
        reason: 'loadingPeers 时不许再点',
      );
      // 收尾：把「加载中」时挂起的那个 50ms loadPeers 定时器放掉，
      // 否则 testTeardown 的 `!timersPending` 不变式会直接判失败。
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(loc.player_loading_peers), findsNothing);
    });

    testWidgets('空闲时点「刷新」-> 重新拉一次设备列表',
        (WidgetTester tester) async {
      await _pumpSheet(tester, peers: <PeerInfo>[_peer('r3', '主卧音箱')]);
      await tester.pump(const Duration(milliseconds: 200));

      final pressed =
          tester
              .widget<MusicFlowActionRow>(_actionRow(loc.player_refresh_players))
              .onPressed;
      expect(pressed, isNotNull, reason: '空闲态可以再拉一次');
      await tester.tap(_actionRow(loc.player_refresh_players));
      await tester.pump(const Duration(milliseconds: 200));

      expect(_fake().loadCalls, 2, reason: '首帧 1 次 + 手动刷新 1 次');
      expect(find.text('主卧音箱'), findsOneWidget);
    });
  });

  group('PlayerSwitcherSheet · 接续搬移', () {
    testWidgets('接续成功 -> 成功提示 + 关窗', (WidgetTester tester) async {
      final playing = _peer('h1', '接续成功的音箱');
      await _pumpSheet(
        tester,
        peers: <PeerInfo>[playing],
        playingPeer: playing,
      );
      await tester.pump(const Duration(milliseconds: 200));
      // StreamProvider 的值要一帧才落下来，早于这一帧 canPull/canPush 还是 false，
      // 按钮是置灰的，点了等于没点（坑：tap 置灰按钮不报错，只是静默无反应）。
      await tester.pump(const Duration(milliseconds: 50));

      final handoff = _handoffIn(
        find.byKey(const ValueKey<String>('sheet-peer-h1')),
      ).first;
      expect(tester.widget<MusicFlowPressable>(handoff).onPressed, isNotNull,
          reason: '「接续成功的音箱」的接续按钮此刻必须可用');
      await tester.tap(handoff);
      await _settle(tester);

      expect(_fake().pullCalls, 1, reason: '点的是「拉」= 接回本机');
      // toast 是插进 Overlay 的 OverlayEntry，先用类型探针看它到底有没有挂上树。
      expect(find.byType(MusicFlowMessage), findsOneWidget,
          reason: '接续成功 -> 右上角成功 toast');
      expect(find.byType(MusicFlowBottomSheet), findsNothing,
          reason: '成功后关窗');
    });

    testWidgets('接续失败 -> 错误提示 + 留在窗里', (WidgetTester tester) async {
      final playing = _peer('h2', '接续失败的音箱');
      await _pumpSheet(
        tester,
        peers: <PeerInfo>[playing],
        playingPeer: playing,
        pushOk: false,
      );
      await tester.pump(const Duration(milliseconds: 200));
      // StreamProvider 的值要一帧才落下来，早于这一帧 canPull/canPush 还是 false，
      // 按钮是置灰的，点了等于没点（坑：tap 置灰按钮不报错，只是静默无反应）。
      await tester.pump(const Duration(milliseconds: 50));

      final handoff = _handoffIn(
        find.byKey(const ValueKey<String>('sheet-peer-h2')),
      ).last;
      expect(tester.widget<MusicFlowPressable>(handoff).onPressed, isNotNull,
          reason: '「接续失败的音箱」的接续按钮此刻必须可用');
      await tester.tap(handoff);
      await _settle(tester);

      expect(_fake().pushCalls, 1, reason: '点的是「推」= 推到音箱');
      expect(find.byType(MusicFlowMessage), findsOneWidget,
          reason: '接续失败 -> 错误 toast');
      expect(find.byType(MusicFlowBottomSheet), findsOneWidget,
          reason: '失败不动现有播放、也不关窗');
    });
  });
}
