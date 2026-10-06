// b38c3 —— player_switcher.dart 剩余可达分支补测（Route C）。
//
// 两处缺口：
//   * line 61  `PeerCastRow` 的 `selected ? colors.accent.withValues(alpha: 0.1)`：
//     既有用例只挂 selected:false，选中态的 accent 薄染底色从未渲染。
//   * line 286 `_doHandoff` 成功分支里 `push ? loc.player_handoff_push_success :
//     loc.player_handoff_pull_success`：既有用例只跑过「拉成功」与「推失败」，
//     **推成功**的 toast 文案从未走到。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/player_switcher.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

late AppLocalizations loc;
_CastFake? _lastFake;

class _CastFake extends CastPeerController {
  _CastFake(super.ref);

  List<PeerInfo> peers = const <PeerInfo>[];
  bool pushOk = true;
  bool pullOk = true;

  int loadCalls = 0;
  int pushCalls = 0;

  @override
  Future<List<PeerInfo>> loadPeers() async {
    loadCalls += 1;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return peers;
  }

  @override
  Future<bool> pushLocalToPeer(PeerInfo peer) async {
    pushCalls += 1;
    return pushOk;
  }

  @override
  Future<bool> pullPeerToLocal(PeerInfo peer) async {
    return pullOk;
  }
}

PeerInfo _peer(String id, String name) =>
    PeerInfo(peerId: id, name: name, kind: 'dlna', available: true, self: false);

PeerNowPlaying _playing(String title) => PeerNowPlaying(
      isActive: true,
      currentIndex: 0,
      total: 12,
      title: title,
      artist: '周杰伦',
    );

Override _playerOverride(int queueLength) => playerProvider.overrideWith(
      (ref) => TestPlayerNotifier(
        PlayerState(
          queue: List<Song>.generate(
            queueLength,
            (int i) => Song(id: 'q$i', title: 'Q$i'),
          ),
        ),
      ),
    );

_CastFake _fake() {
  final c = _lastFake;
  if (c == null) throw StateError('controller 桩没建出来');
  return c;
}

// ---------------------------------------------------------------------------
// 1) PeerCastRow 选中态底色
// ---------------------------------------------------------------------------

Future<void> _pumpRow(
  WidgetTester tester, {
  required PeerInfo peer,
  required bool selected,
  void Function(MusicFlowColors)? onColors,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      _playerOverride(2),
      castPeerControllerProvider.overrideWith((ref) {
        final c = _CastFake(ref);
        c.peers = <PeerInfo>[peer];
        _lastFake = c;
        return c;
      }),
      peerNowPlayingProvider(peer.peerId)
          .overrideWith((ref) => Stream<PeerNowPlaying?>.value(null)),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (context, child) {
        onColors?.call(context.musicFlowColors);
        return child!;
      },
      home: Scaffold(
        body: MusicFlowTapAnchorScope(
          child: Center(
            child: SizedBox(
              width: 760,
              child: PeerCastRow(
                peer: peer,
                selected: selected,
                onSwitch: () async {},
                onHandoff: (bool _) async {},
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

Ink _rowInk(WidgetTester tester) => tester.widget<Ink>(
      find
          .descendant(
            of: find.byType(PeerCastRow),
            matching: find.byType(Ink),
          )
          .first,
    );

// ---------------------------------------------------------------------------
// 2) PlayerSwitcherSheet 推成功
// ---------------------------------------------------------------------------

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

class _TestOverlay extends StatelessWidget {
  const _TestOverlay();

  @override
  Widget build(BuildContext context) => Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(builder: (BuildContext _) => const _NavigatorHost()),
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
            builder: (BuildContext _) => const MusicFlowTapAnchorScope(
              child: PlayerSwitcherSheet(),
            ),
          );
        },
      );
}

Future<void> _pumpSheet(WidgetTester tester, {required PeerInfo playingPeer}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      _playerOverride(1),
      castPeerControllerProvider.overrideWith((ref) {
        final c = _CastFake(ref)..peers = <PeerInfo>[playingPeer];
        _lastFake = c;
        return c;
      }),
      peerNowPlayingProvider(playingPeer.peerId)
          .overrideWith((ref) => Stream<PeerNowPlaying?>.value(_playing('稻香'))),
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
  // root 建好 -> 回调 push sheet；sheet 建好 -> 挂载 _reload。
  await tester.pump();
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() {
    loc = lookupAppLocalizations(const Locale('zh'));
  });

  group('PeerCastRow 选中态底色', () {
    testWidgets('selected:true → 底色 accent@10%', (tester) async {
      MusicFlowColors? colors;
      await _pumpRow(
        tester,
        peer: _peer('h1', '主卧音箱'),
        selected: true,
        onColors: (MusicFlowColors c) => colors = c,
      );

      final decoration = _rowInk(tester).decoration! as BoxDecoration;
      expect(decoration.color, colors!.accent.withValues(alpha: 0.1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('selected:false → 底色透明', (tester) async {
      await _pumpRow(tester, peer: _peer('h1', '主卧音箱'), selected: false);

      final decoration = _rowInk(tester).decoration! as BoxDecoration;
      expect(decoration.color, Colors.transparent);
      expect(tester.takeException(), isNull);
    });
  });

  group('PlayerSwitcherSheet 推成功', () {
    testWidgets('本机→设备 推成功 → 成功 toast 文案 + 关窗', (tester) async {
      final playing = _peer('h9', '书房音箱');
      await _pumpSheet(tester, playingPeer: playing);
      await tester.pump(const Duration(milliseconds: 200));
      // StreamProvider 的值再一帧才落下，否则推按钮还是置灰的。
      await tester.pump(const Duration(milliseconds: 50));

      final pushButton = find
          .descendant(
            of: find.byKey(const ValueKey<String>('sheet-peer-h9')),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is MusicFlowPressable && w.minimumSize == const Size.square(34),
            ),
          )
          .last;
      expect(
        tester.widget<MusicFlowPressable>(pushButton).onPressed,
        isNotNull,
        reason: '远端在播 + 本机有队列 → 推按钮应可用',
      );

      await tester.tap(pushButton);
      await _settle(tester);

      expect(_fake().pushCalls, 1);
      // 推成功文案（line 286 的 true 侧）。
      final success = find.text(loc.player_handoff_push_success(playing.name));
      expect(success, findsOneWidget);
      expect(find.byType(MusicFlowMessage), findsOneWidget);
      expect(find.byType(MusicFlowBottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
