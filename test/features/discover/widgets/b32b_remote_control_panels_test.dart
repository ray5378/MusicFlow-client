// batch32 B 路 —— `lib/features/discover/widgets/remote_control_panels.dart` 补测。
//
// 基线覆盖率 ~0%。RemoteControlVolumePanel 是公开 ConsumerStatefulWidget，
// 可直接挂树。三条静音链路全覆盖：
//   * 本机降级（G-1）：音量置 0 + 记住原值恢复（playerProvider 无 setMuted）；
//   * 链路 B 直投（dlnaCastProvider.isCasting）→ 真 setMuted；
//   * 链路 A 投屏（castPeerControllerProvider.activePeer）→ 真 setMuted。
// 滑条路径：拖动走 ThrottledVolumeSender（live 下发），松手 onChangeEnd
// 复位节流并落盘提交。
//
// 打桩要点：
//   * DlnaCastNotifier 构造读 dlnaManagerProvider/playerProvider.audioHandler，
//     用真实容器 + TestPlayerNotifier 即可安全构造；casting 态由子类构造
//     后 setState 覆写。
//   * RecordingVolPlayer 显式 override setVolume/setVolumeLive 记录并回写
//     state.volume（TestPlayerNotifier 的 noSuchMethod 会静默吞掉）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/design/components/music_flow_slider.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_panels.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_volume.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

const Size kPanelView = Size(480, 120);

/// 本机播放器桩：记录音量下发并回写 state（effectiveVolume 随之更新）。
class RecordingVolPlayer extends TestPlayerNotifier {
  RecordingVolPlayer({double volume = 0.8}) : super(PlayerState(volume: volume));

  final List<double> setVolumeCalls = <double>[];
  final List<double> setVolumeLiveCalls = <double>[];

  @override
  Future<void> setVolume(double volume) async {
    setVolumeCalls.add(volume);
    state = state.copyWith(volume: volume);
  }

  @override
  void setVolumeLive(double volume) {
    setVolumeLiveCalls.add(volume);
    state = state.copyWith(volume: volume);
  }
}

/// 链路 B 直投桩：可配置 casting 态 + 记录 setMuted。
class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref, {bool casting = false, int volume = 0}) {
    if (casting) {
      state = DlnaCastState(
        isCasting: true,
        status: DlnaDeviceStatus(state: 'PLAYING', volume: volume),
      );
    }
  }

  final List<bool> setMutedCalls = <bool>[];

  @override
  Future<void> setMuted(bool muted) async {
    setMutedCalls.add(muted);
  }
}

/// 链路 A 投屏桩：可配置 activePeer + 记录 setMuted。
class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref, {PeerInfo? peer}) {
    if (peer != null) {
      state = state.copyWith(activePeer: peer);
    }
  }

  final List<bool> setMutedCalls = <bool>[];

  @override
  Future<void> setMuted(bool muted) async {
    setMutedCalls.add(muted);
  }
}

class _PanelHarness {
  _PanelHarness({
    double localVolume = 0.5,
    this.dlnaCasting = false,
    this.dlnaVolume = 0,
    this.activePeer,
    double? playerVolume,
  }) : player = RecordingVolPlayer(volume: playerVolume ?? localVolume);

  final bool dlnaCasting;
  final int dlnaVolume;
  final PeerInfo? activePeer;
  final RecordingVolPlayer player;

  // 在 provider override 闭包里惰性构造（基类构造需要 Ref）。
  StubDlnaCast? _dlna;
  StubCastPeer? _cast;
  StubDlnaCast get dlna => _dlna!;
  StubCastPeer get cast => _cast!;

  ProviderContainer? container;
  AppLocalizations? loc;

  Widget build() {
    final container = ProviderContainer(
      overrides: <Override>[
        playerProvider.overrideWith((Ref ref) => player),
        dlnaCastProvider.overrideWith(
          (Ref ref) => _dlna = StubDlnaCast(
            ref,
            casting: dlnaCasting,
            volume: dlnaVolume,
          ),
        ),
        castPeerControllerProvider.overrideWith(
          (Ref ref) => _cast = StubCastPeer(ref, peer: activePeer),
        ),
      ],
    );
    this.container = container;
    return UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(size: kPanelView, devicePixelRatio: 1),
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
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: kPanelView.width,
                height: 56,
                child: const RemoteControlVolumePanel(
                  metrics: RemoteControlMetrics.standard,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = kPanelView;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  double get effectiveVolume => container!.read(effectiveVolumeProvider);
}

Finder muteButton() => find.byType(MusicFlowIconButton);

Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('RemoteControlVolumePanel · 装配', () {
    testWidgets('本机音量 50% -> 百分比文案 + 非静音图标态', (WidgetTester tester) async {
      final h = _PanelHarness(localVolume: 0.5);
      await h.pump(tester);

      expect(find.text(h.loc!.home_remote_volume_percent('50')), findsOneWidget);
      final button = tester.widget<MusicFlowIconButton>(muteButton());
      expect(button.selected, isFalse, reason: '音量 > 0 非静音态');
      expect(h.effectiveVolume, closeTo(0.5, 1e-9));
      expect(tester.takeException(), isNull);
    });

    testWidgets('音量 0 -> 静音图标态 + 0% 文案', (WidgetTester tester) async {
      final h = _PanelHarness(localVolume: 0.0);
      await h.pump(tester);

      expect(find.text(h.loc!.home_remote_volume_percent('0')), findsOneWidget);
      final button = tester.widget<MusicFlowIconButton>(muteButton());
      expect(button.selected, isTrue, reason: '音量 0 即静音态');
      expect(tester.takeException(), isNull);
    });

    testWidgets('DLNA 直投且设备回报 42 -> 显示设备音量 42%', (
      WidgetTester tester,
    ) async {
      final h = _PanelHarness(dlnaCasting: true, dlnaVolume: 42);
      await h.pump(tester);

      expect(
        find.text(h.loc!.home_remote_volume_percent('42')),
        findsOneWidget,
        reason: '投屏优先用设备回报音量',
      );
      expect(h.effectiveVolume, closeTo(0.42, 1e-9));
      expect(tester.takeException(), isNull);
    });
  });

  group('RemoteControlVolumePanel · 静音三链路', () {
    testWidgets('本机：点静音 -> 音量置 0 并记住原值', (WidgetTester tester) async {
      final h = _PanelHarness(localVolume: 0.5);
      await h.pump(tester);

      await tester.tap(muteButton());
      await settle(tester);

      expect(h.player.setVolumeCalls, <double>[0]);
      expect(h.effectiveVolume, 0);
      expect(
        find.text(h.loc!.home_remote_volume_percent('0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('本机：静音后再点 -> 恢复静音前音量', (WidgetTester tester) async {
      final h = _PanelHarness(localVolume: 0.5);
      await h.pump(tester);

      await tester.tap(muteButton());
      await settle(tester);
      await tester.tap(muteButton());
      await settle(tester);

      expect(h.player.setVolumeCalls.last, closeTo(0.5, 1e-9),
          reason: '恢复记忆的静音前音量');
      expect(h.effectiveVolume, closeTo(0.5, 1e-9));
      expect(tester.takeException(), isNull);
    });

    testWidgets('本机：无记忆值时取消静音回退 0.3', (WidgetTester tester) async {
      final h = _PanelHarness(localVolume: 0.0);
      await h.pump(tester);

      await tester.tap(muteButton());
      await settle(tester);

      expect(h.player.setVolumeCalls, <double>[0.3],
          reason: '_localVolumeBeforeMute 为 null -> 回退 0.3');
      expect(tester.takeException(), isNull);
    });

    testWidgets('DLNA 直投：点静音走真 setMuted(true)，本机音量不动', (
      WidgetTester tester,
    ) async {
      final h = _PanelHarness(localVolume: 0.8, dlnaCasting: true, dlnaVolume: 42);
      await h.pump(tester);

      await tester.tap(muteButton());
      await settle(tester);

      expect(h.dlna.setMutedCalls, <bool>[true], reason: 'current>0 -> true');
      expect(h.player.setVolumeCalls, isEmpty, reason: '不写本机音量');
      expect(tester.takeException(), isNull);
    });

    testWidgets('DLNA 直投：有效音量为 0 -> 点静音走 setMuted(false)', (
      WidgetTester tester,
    ) async {
      final h = _PanelHarness(
        localVolume: 0.0,
        dlnaCasting: true,
        dlnaVolume: 0,
      );
      await h.pump(tester);

      await tester.tap(muteButton());
      await settle(tester);

      expect(h.dlna.setMutedCalls, <bool>[false]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('投屏 peer：点静音走链路 A setMuted(true)', (
      WidgetTester tester,
    ) async {
      final h = _PanelHarness(
        localVolume: 0.6,
        activePeer: const PeerInfo(
          peerId: 'peer1',
          name: '客厅设备',
          kind: 'dlna',
          available: true,
        ),
      );
      await h.pump(tester);

      await tester.tap(muteButton());
      await settle(tester);

      expect(h.cast.setMutedCalls, <bool>[true]);
      expect(h.dlna.setMutedCalls, isEmpty, reason: '直投未激活不走链路 B');
      expect(h.player.setVolumeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('RemoteControlVolumePanel · 滑条下发', () {
    testWidgets('拖动滑条 -> live 下发多次，松手提交最终值', (
      WidgetTester tester,
    ) async {
      final h = _PanelHarness(localVolume: 0.2);
      await h.pump(tester);

      final rect = tester.getRect(find.byType(MusicFlowSlider));
      final gesture = await tester.startGesture(rect.centerLeft);
      await tester.pump();
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      await gesture.up();
      await settle(tester, frames: 10);

      expect(h.player.setVolumeLiveCalls, isNotEmpty,
          reason: '拖动经节流器 live 下发');
      expect(h.player.setVolumeCalls, hasLength(1),
          reason: '松手 onChangeEnd 复位节流并提交一次最终值');
      // 起点 localPosition=0 会先被 onTapDown 归零，再按 (dx-11)/(w-22) 计算。
      final expected = ((120 - 11) / (rect.width - 22)).clamp(0.0, 1.0);
      expect(h.player.setVolumeCalls.single, closeTo(expected, 0.03));
      expect(h.effectiveVolume, closeTo(expected, 0.03));
      expect(tester.takeException(), isNull);
    });

    testWidgets('面板内部点击被 opaque GestureDetector 吞掉，不冒泡', (
      WidgetTester tester,
    ) async {
      var outsideTaps = 0;
      final container = ProviderContainer(
        overrides: <Override>[
          playerProvider.overrideWith((Ref ref) => RecordingVolPlayer()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            theme: AppTheme.light(),
            home: Scaffold(
              body: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => outsideTaps++,
                child: const SizedBox(
                  width: 480,
                  height: 56,
                  child: RemoteControlVolumePanel(
                    metrics: RemoteControlMetrics.standard,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(MusicFlowSlider).first,
          warnIfMissed: false);
      await settle(tester);

      expect(outsideTaps, 0,
          reason: '面板自吞命中：点面板内部不得触发外层「点空白关闭」');
      expect(tester.takeException(), isNull);
    });
  });
}
