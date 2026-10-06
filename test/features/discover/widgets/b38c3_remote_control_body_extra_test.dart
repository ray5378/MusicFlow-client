// b38c3 —— Route C 补测：首页「播放控制」块主体剩余缺口。
//   * remote_control_body.dart：
//     107（切换器条首项「流转播放」按钮的 onPressed 闭包）
//     141-156（_openPlayerSwitcher：打开流转专页 + onTransfer 闭包体）
//     466（_openRemoteControlQueue 的桌面分支 → toggleRightQueuePanel → 右侧非模态面板）
//
// 手法：cast 控制器/dlna 用桩；remoteControlTargetsProvider 直接注入 [本机, DLNA]；
// 流转走真实 PlayerTransferPage 拖拽（与 mini_player 同款手势）；右侧面板走
// showRightQueuePanel（根 Overlay 插入 RightQueuePanel），用例尾部复位全局
// _queuePanelOpen，避免跨用例污染。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_body.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/home_remote_control_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

import '../../player/test_player_notifier.dart';

const String kSelfName = '本机';
const String kDlnaName = '主卧';

const PeerInfo kSelf = PeerInfo(
  peerId: 'local:u1',
  name: kSelfName,
  kind: 'local',
  available: true,
  self: true,
  platform: 'android',
);
const PeerInfo kDlna = PeerInfo(
  peerId: 'dlna:30',
  name: kDlnaName,
  kind: 'dlna',
  available: true,
);

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);

  final List<String> calls = <String>[];
  bool transferOk = true;

  @override
  Future<List<PeerInfo>> loadPeers() async {
    calls.add('loadPeers');
    return <PeerInfo>[kSelf, kDlna];
  }

  @override
  Future<bool> transferQueue(PeerInfo from, PeerInfo to) async {
    calls.add('transferQueue:${from.peerId}->${to.peerId}');
    return transferOk;
  }

  @override
  Future<void> backToLocal({bool resumeLocal = false}) async {
    calls.add('backToLocal:$resumeLocal');
  }

  @override
  Future<bool> switchTo(PeerInfo peer) async {
    calls.add('switchTo:${peer.peerId}');
    return true;
  }
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

Song _song(String title) => Song(id: 's1', title: title, artist: '歌手');

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder ringGesture(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(GestureDetector))
    .at(0);

Finder coverDragHandle(String peerId) => find.byWidgetPredicate(
      (Widget w) => w is Draggable<PeerInfo> && w.data?.peerId == peerId,
    );

class _Harness {
  _Harness({required this.child, this.width = 700, this.height = 1200});

  final Widget child;
  final double width;
  final double height;

  late _StubCastPeer cast;

  Widget build(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    return ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith(
          (Ref ref) => TestPlayerNotifier(PlayerState(currentSong: _song('晨光曲'))),
        ),
        castPeerControllerProvider.overrideWith((Ref ref) {
          cast = _StubCastPeer(ref)..state = const CastPeerState(activePeer: kSelf);
          return cast;
        }),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
        effectiveIsPlayingProvider.overrideWith((Ref ref) => false),
        resolvedCurrentSongMediaVisualsProvider.overrideWith(
          (Ref ref) => MusicFlowMediaVisuals.fallback(),
        ),
        peerNowPlayingProvider.overrideWith(
          (Ref ref, String peerId) => const Stream<PeerNowPlaying?>.empty(),
        ),
        remoteControlTargetsProvider
            .overrideWith((Ref ref) => <PeerInfo>[kSelf, kDlna]),
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
  tearDown(closeRightQueuePanel);

  testWidgets('RemoteControlPeerBar：点「流转播放」→ 流转专页完成一次流转（107/141-156）',
      (tester) async {
    final h = _Harness(
      child: const SizedBox(
        height: 48,
        child: RemoteControlPeerBar(metrics: RemoteControlMetrics.standard),
      ),
      height: 1400,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    // 首项「流转播放」按钮（transferInfinity 图标）。
    await tester.tap(find.byIcon(AppIcons.transferInfinity).first);
    await settle(tester, frames: 12);
    expect(find.byType(PlayerTransferPage), findsOneWidget,
        reason: '点流转入口应打开流转专页');

    // 拖远端圆到本机圆 → 页面回调 onTransfer(dlna, self)。
    final start = tester.getCenter(coverDragHandle(kDlna.peerId));
    final g = await tester.startGesture(start);
    await g.moveBy(const Offset(50, 18));
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveTo(tester.getCenter(ringGesture(kSelfName)));
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pump(const Duration(milliseconds: 120));
    await settle(tester, frames: 12);

    expect(h.cast.calls, contains('transferQueue:dlna:30->local:u1'),
        reason: '_openPlayerSwitcher 的 onTransfer 闭包应调用 transferQueue');
    expect(tester.takeException(), isNull);
  });

  testWidgets('RemoteControlControls：桌面端点队列 → 右侧非模态面板（466）', (tester) async {
    final h = _Harness(
      child: const SizedBox(
        height: 64,
        child: RemoteControlControls(metrics: RemoteControlMetrics.standard),
      ),
      width: 700,
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    await tester.tap(find.byIcon(AppIcons.queue).first);
    await settle(tester, frames: 12);

    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsOneWidget,
        reason: '非 compact 窗口下队列按钮应打开右侧非模态面板');
    expect(tester.takeException(), isNull);
  });
}
