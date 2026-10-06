// b38c3 —— Route C 补测：播放队列面板（play_queue_sheet.dart）剩余缺口。
//   * 170/171：投屏（链路 A）队列行的 onRemove 闭包 → castPeer.removeQueueItem。
//   * 201/202：DLNA 直投（链路 B）队列行的 onRemove 闭包 → dlnaCast.removeQueueItem。
//   * 395：PlayQueueSheetView 关闭按钮在 onClose==null 时的 maybePop 分支。
//   * 758：投屏队列 ReorderableListView 的 proxyDecorator（拖拽上屏才构造 Material）。
//   * 785：投屏队列行 onMorePressed 闭包体（showMoreButton=false，需显式触发）。
//   * 960/961：本机队列行 onMorePressed 闭包体（同上）。
//
// 手法：cast/dlna 控制器用子类桩记录调用；投屏队列行是 provider-free 的
// MusicFlowSongRow，直接取 widget 调 onMorePressed 触发闭包链；拖拽排序用
// ReorderableDelayedDragStartListener 的长按+位移。
//
// 报告为**不可达/防御性死代码**：713、900（两个 _jumpToCurrent 里
// `if (last < 0 || !_controller.hasClients)` 的早退体 _unlockCovers()）——
// 该方法只在 queue 非空且 currentIndex>=0 时经首帧 postFrameCallback 或
// didUpdateWidget 调用，届时 last>=0 且 controller 必已 attach（hasClients==true）；
// queue 转空会让 _AutoCenter*List 被 MusicFlowEmptyState 替换、State 卸载，
// 故守卫恒为假，无可达路径（详见文末）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../test_player_notifier.dart';

const PeerInfo kCastPeer = PeerInfo(
  peerId: 'peer:1',
  name: '客厅音箱',
  kind: 'remote',
  available: true,
);

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> removeQueueItem(int index) async {
    calls.add('removeQueueItem:$index');
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    calls.add('reorderQueue:$from:$to');
  }

  @override
  Future<void> jumpTo(int index) async {
    calls.add('jumpTo:$index');
  }

  @override
  Future<void> clearCastQueue() async {
    calls.add('clearCastQueue');
  }
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> removeQueueItem(int index) async {
    calls.add('removeQueueItem:$index');
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    calls.add('reorderQueue:$from:$to');
  }

  @override
  Future<void> playAt(int index) async {
    calls.add('playAt:$index');
  }

  @override
  Future<void> stopCast() async {
    calls.add('stopCast');
  }
}

Song _song(String id, String title) => Song(id: id, title: title, artist: '歌手');

Map<String, dynamic> _castItem(String id, String title) =>
    <String, dynamic>{'songId': id, 'title': title, 'artist': '歌手'};

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

class _Harness {
  _Harness({
    required this.child,
    this.castState,
    this.dlnaState,
    this.playerState,
  });

  final Widget child;
  final CastPeerState? castState;
  final DlnaCastState? dlnaState;
  final PlayerState? playerState;

  late _StubCastPeer cast;
  late _StubDlnaCast dlna;

  Widget build(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    return ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith(
          (Ref ref) => TestPlayerNotifier(playerState ?? PlayerState()),
        ),
        castPeerControllerProvider.overrideWith((Ref ref) {
          cast = _StubCastPeer(ref)..state = castState ?? const CastPeerState();
          return cast;
        }),
        dlnaCastProvider.overrideWith((Ref ref) {
          dlna = _StubDlnaCast(ref)..state = dlnaState ?? const DlnaCastState();
          return dlna;
        }),
        resolvedCurrentSongMediaVisualsProvider.overrideWith(
          (Ref ref) => MusicFlowMediaVisuals.fallback(),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(body: child),
      ),
    );
  }
}

void main() {
  testWidgets('投屏队列：拖拽排序触发 proxyDecorator（758）+ 行移除（170/171）',
      (tester) async {
    final h = _Harness(
      castState: CastPeerState(
        activePeer: kCastPeer,
        castIndex: 0,
        castQueue: <Map<String, dynamic>>[
          _castItem('c1', '投屏曲一'),
          _castItem('c2', '投屏曲二'),
        ],
      ),
      child: const PlayQueueSheet(panel: true),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('投屏曲一'), findsOneWidget);
    final rows = find.byType(MusicFlowSongRow);
    expect(rows, findsNWidgets(2));

    // 长按拖拽第一行 → ReorderableDelayedDragStartListener 起拖，
    // proxyDecorator（758）构造透明 Material。
    final gesture =
        await tester.startGesture(tester.getCenter(rows.at(0)));
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.cast.calls.where((c) => c.startsWith('reorderQueue')).isNotEmpty,
        isTrue,
        reason: '拖拽落位应经 onReorder 路由到 castPeer.reorderQueue');

    // 行「更多」回调 → 投屏队列 onRemove 闭包（170/171）。
    h.cast.calls.clear();
    tester.widget<MusicFlowSongRow>(rows.at(1)).onMorePressed?.call();
    await settle(tester);
    expect(h.cast.calls, contains('removeQueueItem:1'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('DLNA 直投队列：行移除（201/202）', (tester) async {
    final h = _Harness(
      dlnaState: const DlnaCastState(isCasting: true, currentIndex: 0),
      playerState: PlayerState(
        queue: <Song>[_song('d1', '直投曲一'), _song('d2', '直投曲二')],
        currentIndex: 0,
        currentSong: _song('d1', '直投曲一'),
      ),
      child: const PlayQueueSheet(panel: true),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    final rows = find.byType(MusicFlowSongRow);
    expect(rows, findsNWidgets(2));

    tester.widget<MusicFlowSongRow>(rows.at(1)).onMorePressed?.call();
    await settle(tester);
    expect(h.dlna.calls, contains('removeQueueItem:1'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('本机队列：onClose==null 关闭走 maybePop（395）+ 行更多回调（960/961）',
      (tester) async {
    final opened = <String>[];
    final h = _Harness(
      child: PlayQueueSheetView(
        panel: true,
        playerState: PlayerState(
          queue: <Song>[_song('l1', '本机曲一'), _song('l2', '本机曲二')],
          currentIndex: 0,
          currentSong: _song('l1', '本机曲一'),
        ),
        onSelect: (int i) async {},
        onClear: () async {},
        onOpenSongActions: (BuildContext c, int i, Song s) async {
          opened.add('open:$i');
        },
      ),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    final rows = find.byType(MusicFlowSongRow);
    expect(rows, findsNWidgets(2));

    // 行更多回调 → onOpenSongActions 闭包体（960/961）。
    tester.widget<MusicFlowSongRow>(rows.at(1)).onMorePressed?.call();
    await settle(tester);
    expect(opened, contains('open:1'));

    // onClose==null → 关闭按钮走 Navigator.maybePop（395）。
    await tester.tap(find.byIcon(AppIcons.close).first);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}
