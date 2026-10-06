// b39c2 —— Route C 清尾：remote_control_body.dart 剩余缺口。
//   * 156：_openPlayerSwitcher 的 onTransfer 闭包里 transferQueue 返回 **false**
//     的分支 —— `: loc.player_handoff_failed`（错误提示）。
//     既有 b38c3_remote_control_body_extra_test 走的是 transferOk=true 的成功
//     分支（155），失败分支未覆盖，本文件补。
//
// 手法照抄 b38c3_remote_control_body_extra_test 的流转专页真实拖拽链路：
// 点「流转播放」→ PlayerTransferPage → 把 DLNA 圆拖到本机圆 → onTransfer。
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

  /// 本用例固定 false：流转失败 → 走 player_handoff_failed 分支（156）。
  bool transferOk = false;

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

late AppLocalizations loc;

class _Harness {
  _Harness({required this.child});

  final Widget child;

  late _StubCastPeer cast;

  Widget build(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    return ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith(
          (Ref ref) =>
              TestPlayerNotifier(PlayerState(currentSong: _song('晨光曲'))),
        ),
        castPeerControllerProvider.overrideWith((Ref ref) {
          cast = _StubCastPeer(ref)
            ..state = const CastPeerState(activePeer: kSelf);
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
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: Scaffold(body: child),
      ),
    );
  }
}

void main() {
  testWidgets('流转专页：transferQueue 失败 → 弹 player_handoff_failed（156）',
      (tester) async {
    final h = _Harness(
      child: const SizedBox(
        height: 48,
        child: RemoteControlPeerBar(metrics: RemoteControlMetrics.standard),
      ),
    );
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    // 打开流转专页。
    await tester.tap(find.byIcon(AppIcons.transferInfinity).first);
    await settle(tester, frames: 12);
    expect(find.byType(PlayerTransferPage), findsOneWidget);

    // 拖远端圆到本机圆 → onTransfer(dlna, self) → transferQueue 返回 false。
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
        reason: 'onTransfer 闭包应调用 transferQueue');
    expect(find.text(loc.player_handoff_failed), findsOneWidget,
        reason: 'transferQueue 失败 → 展示失败提示（156）');
    expect(find.text(loc.player_handoff_push_success(kDlnaName)), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
