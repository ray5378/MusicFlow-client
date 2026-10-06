// b39c —— Route C 补测：player 侧 Hero / mini_player 缺口。
//
// 覆盖点：
//   * player_backdrop.dart:92-95 —— `_reduceMotion` 在「无 MediaQuery 祖先」时
//     走 `WidgetsBinding.instance.platformDispatcher.accessibilityFeatures…
//     .disableAnimations` 的右侧；经由公开的
//     `playerBackgroundFlightShuttleBuilder` 以无 MediaQuery 的 flightContext 触发。
//   * mini_player.dart:92 —— MiniPlayer.build 的 onTransfer 闭包在
//     `transferQueue` 返回 false 时的失败提示分支；直接取
//     `PlayerTransferPage.onTransfer`（公开字段）调用即可。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
import 'package:musicflow_client/features/player/widgets/mini_player.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

import '../test_player_notifier.dart';

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

class _StubFrozenPosition extends FrozenPositionNotifier {
  _StubFrozenPosition(this._read);
  final Duration Function() _read;
  @override
  Duration build() => _read();
}

class _StubFrozenLyricLine extends FrozenLyricLineNotifier {
  _StubFrozenLyricLine(this.value);
  final String? value;
  @override
  String? build() => value;
}

class MiniCastPeer extends CastPeerController {
  MiniCastPeer(super.ref);

  final List<String> calls = <String>[];
  bool transferOk = true;

  @override
  Future<List<PeerInfo>> loadPeers() async => <PeerInfo>[kSelf, kDlna];

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
  Future<bool> switchTo(PeerInfo peer) async => true;
}

class MiniDlnaCast extends DlnaCastNotifier {
  MiniDlnaCast(super.ref);
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Song _song(String title) => Song(id: 's1', title: title, artist: '歌手');

void main() {
  testWidgets('无 MediaQuery 的 flightContext → _reduceMotion 走平台兜底（92-95）',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final visuals = MusicFlowMediaVisuals.fallback();
    late BuildContext flightCtx;

    // 注意：整棵树刻意**不**提供 MediaQuery（无 MaterialApp）⇒
    // MediaQuery.maybeOf(flightContext) 为 null，命中右侧兜底表达式。
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Builder(
              builder: (BuildContext ctx) {
                flightCtx = ctx;
                return Stack(
                  children: <Widget>[
                    Hero(
                      tag: 'from',
                      child: MusicFlowPlayerBackdrop(
                        visuals: visuals,
                        mode: MusicFlowPlayerBackdropMode.mini,
                      ),
                    ),
                    Hero(
                      tag: 'to',
                      child: MusicFlowPlayerBackdrop(
                        visuals: visuals,
                        mode: MusicFlowPlayerBackdropMode.stage,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final fromCtx = tester.element(
      find.byWidgetPredicate((Widget w) => w is Hero && w.tag == 'from'),
    );
    final toCtx = tester.element(
      find.byWidgetPredicate((Widget w) => w is Hero && w.tag == 'to'),
    );

    final shuttle = playerBackgroundFlightShuttleBuilder(
      flightCtx,
      const AlwaysStoppedAnimation<double>(0.25),
      HeroFlightDirection.push,
      fromCtx,
      toCtx,
    );

    expect(shuttle, isA<Widget>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('MiniPlayer onTransfer 失败 → 失败提示分支（mini_player 92）',
      (tester) async {
    late MiniCastPeer cast;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith(
            (Ref ref) => TestPlayerNotifier(
              PlayerState(currentSong: _song('晨光曲')),
            ),
          ),
          castPeerControllerProvider.overrideWith((Ref ref) {
            cast = MiniCastPeer(ref)
              ..state = const CastPeerState(activePeer: kSelf)
              ..transferOk = false;
            return cast;
          }),
          dlnaCastProvider.overrideWith((Ref ref) => MiniDlnaCast(ref)),
          effectiveIsPlayingProvider.overrideWith((Ref ref) => false),
          effectiveDurationProvider.overrideWith(
            (Ref ref) => const Duration(minutes: 3),
          ),
          frozenPositionProvider.overrideWith(
            () => _StubFrozenPosition(() => const Duration(seconds: 30)),
          ),
          frozenLyricLineProvider.overrideWith(
            () => _StubFrozenLyricLine(null),
          ),
          resolvedCurrentSongMediaVisualsProvider.overrideWith(
            (Ref ref) => MusicFlowMediaVisuals.fallback(),
          ),
          peerNowPlayingProvider.overrideWith(
            (Ref ref, String peerId) => const Stream<PeerNowPlaying?>.empty(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlayer(),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    await tester.tap(find.byIcon(AppIcons.transferInfinity).first);
    await settle(tester, frames: 12);
    expect(find.byType(PlayerTransferPage), findsOneWidget);

    // 直接调用公开的 onTransfer（= MiniPlayer.build 里的闭包体）：
    // transferQueue 返回 false ⇒ 命中 mini_player.dart:92 的失败文案分支。
    final page =
        tester.widget<PlayerTransferPage>(find.byType(PlayerTransferPage));
    final ok = await page.onTransfer(kDlna, kSelf);
    await settle(tester, frames: 6);

    expect(ok, isFalse);
    expect(cast.calls, contains('transferQueue:dlna:30->local:u1'));
    expect(tester.takeException(), isNull);
  });
}
