// b38c3 —— Route C 补测：features/player/widgets/mini_player.dart 剩余可达缺口。
//   * 672-673：_handleProgressDragCancel 的方法入口 + `if (!_scrubbing) return` 守卫
//     （拖拽尚未被接受就被指针取消 → onHorizontalDragCancel 回调）。
//   * 76：MiniPlayer.build 里 onSeek 闭包体 → seekEffectivePlayback。
//   * 81-92：MiniPlayer.build 里 onTransfer 闭包体（点投屏按钮 → 流转专页 → 完成一次流转）。
//
// 报告为**不可达 / 死代码**（见文末注释）：
//   * 646 + 674-677：`_handleProgressDragUpdate` 的 `_scrubSongId != widget.songId` 分支，
//     以及 `_handleProgressDragCancel` 的 setState 主体。
//     ① `_MiniPlayerProgressSurface` 的 key 恒为 `ValueKey(songId)` ⇒ 切歌即换 key，
//        State 被重建、`_scrubbing` 归零，644 行先早退，645 行永不成立；
//     ② 想在「已接受（_scrubbing==true）」后走 Cancel，需要 onHorizontalDragCancel，
//        但 Flutter 的 DragGestureRecognizer 对 PointerCancelEvent 走
//        `_giveUpPointer → didStopTrackingLastPointer`：accepted 态调 `_checkEnd`
//        （onEnd），只有 possible 态才调 `_checkCancel`（onCancel）——而 possible 态下
//        `_scrubbing` 必为 false，只会命中 673 行守卫。故 674-677 无路径可达。
//   * 857：_MiniPlayerTrack 的 `else title`（`useHero == false`）—— 唯一调用点恒传 true。
//
// 手法：MiniPlayerView 是 `@visibleForTesting` 纯控件，直接挂树打手势；
// 真 MiniPlayer 的 onSeek 闭包用 `tester.widget<MiniPlayerView>(...).onSeek` 显式触发
// （闭包体在 MiniPlayer.build 里构造，但生产路径永不调用它 —— progressLayer 恒非空，
//  MiniPlayerView 内部走 `progressLayer ?? …` 的左侧，onSeek 字段被短路）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/mini_player.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
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

/// 记录调用并可控返回值的链路 A 桩。
class MiniCastPeer extends CastPeerController {
  MiniCastPeer(super.ref);

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

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
  }
}

class MiniDlnaCast extends DlnaCastNotifier {
  MiniDlnaCast(super.ref);
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder bubbleText() => find.byWidgetPredicate(
      (Widget w) =>
          w is Text && RegExp(r'^\d+:\d\d$').hasMatch((w.data ?? '').trim()),
    );

Finder ringGesture(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(GestureDetector))
    .at(0);

Finder coverDragHandle(String peerId) => find.byWidgetPredicate(
      (Widget w) => w is Draggable<PeerInfo> && w.data?.peerId == peerId,
    );

Song _song(String title) => Song(id: 's1', title: title, artist: '歌手');

void main() {
  testWidgets('拖拽未接受即被取消：_handleProgressDragCancel 守卫早退（672-673）',
      (tester) async {
    final seeks = <Duration>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 500);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlayerView(
                // 无封面 → 不走网络图，避免 pending Timer。
                playerState: PlayerState(
                  currentSong: _song('晨光曲'),
                  duration: const Duration(minutes: 3),
                  position: const Duration(seconds: 30),
                ),
                onOpenPlayer: () {},
                onTogglePlayPause: () async {},
                onSeek: (Duration d) async => seeks.add(d),
                onSwitchPlayer: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    final rect = tester.getRect(
      find.byKey(const Key('mini-player-scrubber')),
    );
    // 位移量为 0（未越过 touch slop）→ 拖拽识别器停在 possible 态，
    // 此时取消会走 `_checkCancel` → onHorizontalDragCancel → 守卫早退。
    final g = await tester.startGesture(rect.center);
    await g.cancel();
    await settle(tester);

    expect(bubbleText(), findsNothing, reason: '未起会话，无气泡');
    expect(seeks, isEmpty, reason: '未起会话，不下发 seek');
    expect(tester.takeException(), isNull);
  });

  testWidgets('MiniPlayer.onSeek 闭包 → seekEffectivePlayback（76）', (tester) async {
    late MiniCastPeer cast;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 500);
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
            cast = MiniCastPeer(ref)..state = const CastPeerState();
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

    // MiniPlayer.build 里传给 MiniPlayerView 的就是第 76 行的闭包；生产路径
    // 因 progressLayer 恒非空而不会调用它，这里显式触发以覆盖该闭包体。
    final view = tester.widget<MiniPlayerView>(find.byType(MiniPlayerView));
    await view.onSeek(const Duration(seconds: 5));
    await settle(tester);

    expect(cast.calls, contains('seek:5000'),
        reason: 'onSeek 闭包应路由到 seekEffectivePlayback');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点投屏按钮 → 流转专页完成一次流转（onTransfer 闭包 81-92）',
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
              ..state = const CastPeerState(activePeer: kSelf);
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

    // 手机端简略版只有「播放/暂停 + 投屏」两个控件，投屏按钮唯一。
    await tester.tap(find.byIcon(AppIcons.transferInfinity).first);
    await settle(tester, frames: 12);
    expect(find.byType(PlayerTransferPage), findsOneWidget,
        reason: '点投屏按钮应打开「流转播放」专用页');

    // 拖远端圆到本机圆 → 页面回调 widget.onTransfer(dlna, self)。
    final start = tester.getCenter(coverDragHandle(kDlna.peerId));
    final g = await tester.startGesture(start);
    await g.moveBy(const Offset(50, 18));
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveTo(tester.getCenter(ringGesture(kSelfName)));
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pump(const Duration(milliseconds: 120));
    await settle(tester, frames: 12);

    expect(cast.calls, contains('transferQueue:dlna:30->local:u1'),
        reason: 'MiniPlayer 的 onTransfer 闭包应调用 transferQueue');
    expect(cast.calls, contains('backToLocal:true'),
        reason: '目标为本机 → 继续走 backToLocal(续播)');
    expect(tester.takeException(), isNull);
  });
}
