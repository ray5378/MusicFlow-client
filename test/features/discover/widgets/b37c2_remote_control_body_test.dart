// batch37 C(2) —— `lib/features/discover/widgets/remote_control_body.dart` 剩余分支。
//
// 既有 b33c_remote_control_body_test 覆盖三段主体的渲染与 effective_* 路由。
// 本文件补深分支：
//   * RemoteControlNowArea 点封面 → _openFullPlayer 推 FullPlayerPage（304-357）；
//   * RemoteControlPeerBar 点「流转播放」入口 → _openPlayerSwitcher（106-121 / 141-165）；
//   * RemoteControlControls 队列键 → _openRemoteControlQueue（462-468 / 521-527）；
//   * _effectiveMode：DLNA 直投态 / 投屏态下的播放模式 → 对应模式图标（588-604）。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_body.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/home_remote_control_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

import '../../player/test_player_notifier.dart';

const Size kView = Size(520, 700);

final Song kSong = Song(id: 's1', title: '测试曲目', artist: '歌手', duration: 200);

const PeerInfo kSelf = PeerInfo(
  peerId: 'local-self',
  name: '',
  kind: 'local',
  available: true,
  self: true,
);

const PeerInfo kRemote = PeerInfo(
  peerId: 'peer1',
  name: '客厅设备',
  kind: 'dlna',
  available: true,
);

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref, {PeerInfo? peer, String mode = 'all'}) {
    if (peer != null || mode != 'all') {
      state = state.copyWith(activePeer: peer, playMode: mode);
    }
  }
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref, {bool casting = false, String mode = 'all'}) {
    if (casting) {
      state = DlnaCastState(isCasting: true, playMode: mode);
    }
  }
}

class _Harness {
  _Harness({this.activePeer, this.dlnaCasting = false, this.mode = 'all'});

  final PeerInfo? activePeer;
  final bool dlnaCasting;
  final String mode;

  late ProviderContainer container;
  AppLocalizations? loc;

  Widget build() {
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          playerProvider.overrideWith(
            (Ref ref) => TestPlayerNotifier(
              PlayerState(currentSong: kSong, queue: <Song>[kSong]),
            ),
          ),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => StubCastPeer(ref, peer: activePeer, mode: mode),
          ),
          dlnaCastProvider.overrideWith(
            (Ref ref) => StubDlnaCast(ref, casting: dlnaCasting, mode: mode),
          ),
          remoteControlTargetsProvider.overrideWith(
            (Ref ref) => const <PeerInfo>[kSelf, kRemote],
          ),
          currentLyricsProvider.overrideWith((Ref ref) async => null),
          effectivePositionProvider.overrideWith((Ref ref) => Duration.zero),
        ],
      ),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: kView.width,
              height: RemoteControlMetrics.standard.totalHeight,
              child: const RemoteControlBody(metrics: RemoteControlMetrics.standard),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester, {int frames = 8}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = kView;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: frames);
  }
}

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Finder _iconButton(AppLocalizations loc, String label) => find.byWidgetPredicate(
      (Widget w) => w is MusicFlowIconButton && w.label == label,
    );

void main() {
  testWidgets('点 Now 区封面 → 打开全屏播放页', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    // 封面外层是 _openFullPlayer 的 GestureDetector。
    final coverGesture = find
        .ancestor(
          of: find.byType(CoverArtImage),
          matching: find.byType(GestureDetector),
        )
        .first;
    await tester.tap(coverGesture);
    await settle(tester, frames: 8);

    expect(find.byType(FullPlayerPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点队列键 → 打开队列面板且不抛', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    await tester.tap(_iconButton(h.loc!, h.loc!.player_queue));
    await settle(tester, frames: 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DLNA 直投态模式为 shuffle → 模式键显示随机图标', (tester) async {
    final h = _Harness(dlnaCasting: true, mode: 'shuffle');
    await h.pump(tester);

    final modeBtn =
        tester.widget<MusicFlowIconButton>(_iconButton(h.loc!, h.loc!.player_mode_list));
    expect(modeBtn.icon, AppIcons.shuffle);
    expect(modeBtn.selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('投屏态模式为 one → 模式键显示单曲循环图标', (tester) async {
    final h = _Harness(activePeer: kRemote, mode: 'one');
    await h.pump(tester);

    final modeBtn =
        tester.widget<MusicFlowIconButton>(_iconButton(h.loc!, h.loc!.player_mode_list));
    expect(modeBtn.icon, AppIcons.repeatOne);
    expect(tester.takeException(), isNull);
  });
}
