// batch37 C(2) —— `lib/features/discover/widgets/remote_control_section.dart` 剩余分支。
//
// 覆盖 section 自身的分叉：
//   * peers 加载中且 targets 为空 → 占满整块骨架（49-53）；
//   * targets 为空（未登录/服务端无 peer）→ 空态 + 点「刷新」invalidate peers（54-67）；
//   * targets 非空 → 挂 RemoteControlBody（68-73）；
//   * alert != none → 告警条覆盖控制条槽（94-95 / 134-178）；
//   * panel == volume → 底部音量覆盖面板（98-113）；
//   * panel != none 时点面板外空白 → 外层 GestureDetector 关闭面板（80-86）。
//
// 打桩：remoteControlPeersProvider / remoteControlTargetsProvider / alert 直接 override；
//        body 的三段子组件所需 player/cast/dlna/lyrics/position 一并 override。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_empty_state.dart';
import 'package:musicflow_client/core/design/components/music_flow_skeleton.dart';
import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_body.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_panels.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_section.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/home_remote_control_provider.dart';

import '../../player/test_player_notifier.dart';

const PeerInfo kSelf = PeerInfo(
  peerId: 'local-self',
  name: '',
  kind: 'local',
  available: true,
  self: true,
);

final Song kSong = Song(id: 's1', title: '测试曲目', artist: '歌手', duration: 200);

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref);
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
}

class _Harness {
  _Harness({this.targets = const <PeerInfo>[], this.peersEmpty = true});

  final List<PeerInfo> targets;
  final bool peersEmpty;

  late final ProviderContainer container;
  AppLocalizations? loc;
  int peersRuns = 0;

  Widget build() {
    final player = TestPlayerNotifier(PlayerState(currentSong: kSong, queue: <Song>[kSong]));
    container = ProviderContainer(
      overrides: <Override>[
        playerProvider.overrideWith((Ref ref) => player),
        castPeerControllerProvider.overrideWith((Ref ref) => StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
        currentLyricsProvider.overrideWith((Ref ref) async => null),
        effectivePositionProvider.overrideWith((Ref ref) => Duration.zero),
        remoteControlTargetsProvider.overrideWith((Ref ref) => targets),
        remoteControlPeersProvider.overrideWith((Ref ref) async {
          peersRuns += 1;
          return peersEmpty ? const <PeerInfo>[] : targets;
        }),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: 520, child: RemoteControlSection()),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester, {int frames = 8}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(520, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(build());
    await settle(tester, frames: frames);
  }
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  testWidgets('peers 加载中且 targets 为空 → 占满整块骨架', (tester) async {
    // 覆盖 peers 为「永不完成」，制造 loading。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: ProviderContainer(
          overrides: <Override>[
            playerProvider.overrideWith((Ref ref) =>
                TestPlayerNotifier(PlayerState(currentSong: kSong, queue: <Song>[kSong]))),
            castPeerControllerProvider.overrideWith((Ref ref) => StubCastPeer(ref)),
            dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
            currentLyricsProvider.overrideWith((Ref ref) async => null),
            effectivePositionProvider.overrideWith((Ref ref) => Duration.zero),
            remoteControlTargetsProvider.overrideWith((Ref ref) => const <PeerInfo>[]),
            remoteControlPeersProvider
                .overrideWith((Ref ref) => Completer<List<PeerInfo>>().future),
          ],
        ),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(width: 520, child: RemoteControlSection()),
            ),
          ),
        ),
      ),
    );
    await settle(tester, frames: 4);
    expect(find.byType(MusicFlowSkeleton), findsWidgets);
    expect(find.byType(RemoteControlBody), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('targets 为空 → 空态；点「刷新」重跑 peers', (tester) async {
    final h = _Harness(targets: const <PeerInfo>[], peersEmpty: true);
    await h.pump(tester);

    expect(find.byType(MusicFlowEmptyState), findsOneWidget);
    final before = h.peersRuns;
    // 直接触发空态动作闭包（onAction → invalidate peers）。
    tester.widget<MusicFlowEmptyState>(find.byType(MusicFlowEmptyState)).onAction!();
    await settle(tester, frames: 4);
    expect(h.peersRuns, greaterThan(before), reason: '刷新应 invalidate peers provider');
    expect(tester.takeException(), isNull);
  });

  testWidgets('targets 非空 → 挂载 RemoteControlBody', (tester) async {
    final h = _Harness(targets: const <PeerInfo>[kSelf], peersEmpty: false);
    await h.pump(tester);
    expect(find.byType(RemoteControlBody), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('alert=unreachable → 覆盖告警条', (tester) async {
    // remoteControlAlertProvider 是只读派生 Provider —— 用 override 版本重建树。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: _alertContainer(RemoteControlAlert.unreachable),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(width: 520, child: RemoteControlSection()),
            ),
          ),
        ),
      ),
    );
    await settle(tester, frames: 6);
    expect(find.byIcon(AppIcons.warning), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel=volume → 底部音量面板；点面板外空白关闭面板', (tester) async {
    final h = _Harness(targets: const <PeerInfo>[kSelf], peersEmpty: false);
    await h.pump(tester);

    h.container.read(remoteControlPanelProvider.notifier).state =
        RemoteControlPanelKind.volume;
    await settle(tester, frames: 4);
    expect(find.byType(RemoteControlVolumePanel), findsOneWidget);

    // 点 section 顶部「切换器与 Now 区之间」的空白 → 外层 GestureDetector 关闭面板。
    final rect = tester.getRect(find.byType(RemoteControlSection));
    await tester.tapAt(rect.topLeft + const Offset(20, 62));
    await settle(tester, frames: 4);
    expect(
      h.container.read(remoteControlPanelProvider),
      RemoteControlPanelKind.none,
      reason: '点面板外空白应关闭面板',
    );
    expect(tester.takeException(), isNull);
  });
}

ProviderContainer _alertContainer(RemoteControlAlert alert) {
  final player =
      TestPlayerNotifier(PlayerState(currentSong: kSong, queue: <Song>[kSong]));
  final c = ProviderContainer(
    overrides: <Override>[
      playerProvider.overrideWith((Ref ref) => player),
      castPeerControllerProvider.overrideWith((Ref ref) => StubCastPeer(ref)),
      dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
      currentLyricsProvider.overrideWith((Ref ref) async => null),
      effectivePositionProvider.overrideWith((Ref ref) => Duration.zero),
      remoteControlTargetsProvider.overrideWith((Ref ref) => const <PeerInfo>[kSelf]),
      remoteControlPeersProvider.overrideWith((Ref ref) async => const <PeerInfo>[kSelf]),
      remoteControlAlertProvider.overrideWith((Ref ref) => alert),
    ],
  );
  addTearDown(c.dispose);
  return c;
}
