// b58 —— 全屏页「倍速」在投屏/群组目标上的行为（服务端 4.13.0）。
//
// 覆盖：
//   * PeerStatus 解析/回写 speed（/status 新增字段，缺省 1）；
//   * 投屏到设备型目标：倍速按钮显示**远端**档位，选择后下发
//     `/peers/:id/speed`（经 CastPeerController），不改本机播放器；
//   * 投屏到本机实例(local:) 或链路 B（局域网 DLNA 直投）：隐藏倍速按钮
//     —— 这两条链路没有服务端出流入口，留着只会是「点了没反应」；
//   * 本机播放：按钮仍读写本地 playerProvider.playbackSpeed（行为不变）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/player_utility_bar.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_player_notifier.dart';

Song _song() => Song(
      id: 'current',
      title: 'Who are you',
      artist: 'Cesária Évora',
      album: 'Café Atlantico',
      duration: 240,
      bitRate: 320,
    );

class _RecCast extends CastPeerController {
  _RecCast({
    this.casting = false,
    this.peerKind = 'player',
    this.remoteSpeed = 1.5,
  });

  final bool casting;
  final String peerKind;
  final double remoteSpeed;

  final List<double> speeds = <double>[];

  @override
  CastPeerState build() {
    if (!casting) return const CastPeerState();
    return CastPeerState(
      activePeer: PeerInfo(
        peerId: peerKind == 'local' ? 'local:u1' : 'peer-1',
        name: '客厅音箱',
        kind: peerKind,
        available: true,
      ),
      status: PeerStatus(
        state: 'PLAYING',
        active: true,
        speed: remoteSpeed,
      ),
      castQueue: <Map<String, dynamic>>[
        <String, dynamic>{'songId': 'current', 'title': 'x'},
      ],
      castIndex: 0,
    );
  }

  @override
  Future<void> setActivePeerPlaybackSpeed(double speed) async {
    speeds.add(speed);
    state = state.copyWith(status: state.status.copyWith(speed: speed));
  }
}

class _RecDlna extends DlnaCastNotifier {
  _RecDlna({this.casting = false});

  final bool casting;

  @override
  DlnaCastState build() {
    if (casting) {
      return const DlnaCastState(
        isCasting: true,
        currentIndex: 0,
        playMode: 'all',
      );
    }
    return super.build();
  }
}

/// 本机播放器桩：TestPlayerNotifier 的 noSuchMethod 返回 null，
/// `setPlaybackSpeed` 会被异步等待 → type 'Null' is not a subtype of 'Future<void>'。
/// 这里显式实现并记录，供「本机播放仍走本地解码器」这条断言使用。
class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.initial);

  final List<double> speeds = <double>[];

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    speeds.add(speed);
    state = state.copyWith(playbackSpeed: speed);
  }
}

late _RecCast cast;
late _RecDlna dlna;
late _RecPlayer player;

Widget _app({required Song song}) {
  return ProviderScope(
    overrides: <Override>[
      playerProvider.overrideWith(() => player),
      castPeerControllerProvider.overrideWith(() => cast),
      dlnaCastProvider.overrideWith(() => dlna),
      sleepTimerProvider.overrideWith(() => SleepTimerNotifier()),
    ],
    child: MaterialApp(
      navigatorKey: rootNavigatorKey,
      theme: AppTheme.dark(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      locale: const Locale('zh'),
      builder: (context, child) => MusicFlowTapAnchorScope(child: child!),
      home: Scaffold(body: PlayerUtilityBar(currentSong: song)),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required bool castCasting,
  String peerKind = 'player',
  bool dlnaCasting = false,
}) async {
  player = _RecPlayer(PlayerState(currentSong: _song()));
  cast = _RecCast(casting: castCasting, peerKind: peerKind);
  dlna = _RecDlna(casting: dlnaCasting);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(song: _song()));
  await tester.pump();
}

/// 有界推帧：工具条含 Tooltip 等定时/动画，禁 pumpAndSettle。
Future<void> _drain(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    tester.takeException();
  }
}

void main() {
  group('PeerStatus.speed', () {
    test('/status 解析 speed，缺省 1', () {
      expect(PeerStatus.fromJson(<String, dynamic>{'state': 'PLAYING'}).speed, 1);
      expect(
        PeerStatus.fromJson(<String, dynamic>{'state': 'PLAYING', 'speed': 1.5})
            .speed,
        1.5,
      );
    });

    test('copyWith 保留/覆盖 speed', () {
      const s = PeerStatus(state: 'PLAYING', speed: 0.75);
      expect(s.copyWith(active: true).speed, 0.75);
      expect(s.copyWith(speed: 2).speed, 2);
    });
  });

  group('全屏工具条倍速按钮', () {
    testWidgets('本机播放：显示本地档位，点选写本地播放器', (tester) async {
      await _pump(tester, castCasting: false);
      expect(find.text('1.0x'), findsOneWidget);

      await tester.tap(find.text('1.0x'));
      await _drain(tester);
      await tester.tap(find.text('1.25x'));
      await _drain(tester);

      expect(player.state.playbackSpeed, 1.25);
      expect(cast.speeds, isEmpty);
    });

    testWidgets('投屏到设备：显示远端档位，点选下发远端', (tester) async {
      await _pump(tester, castCasting: true);
      expect(find.text('1.5x'), findsOneWidget);

      await tester.tap(find.text('1.5x'));
      await _drain(tester);
      await tester.tap(find.text('1.25x'));
      await _drain(tester);

      expect(cast.speeds, <double>[1.25]);
      // 不改本机解码器倍速：投屏态本机没有声音输出。
      expect(player.state.playbackSpeed, 1.0);
      // 乐观回写：轮询回来之前按钮就显示新档位。
      expect(find.text('1.25x'), findsOneWidget);
    });

    testWidgets('投屏到本机实例(local:)：隐藏倍速按钮', (tester) async {
      await _pump(tester, castCasting: true, peerKind: 'local');
      expect(find.text('1.5x'), findsNothing);
      expect(find.text('1.0x'), findsNothing);
    });

    testWidgets('链路 B（局域网 DLNA 直投）：隐藏倍速按钮', (tester) async {
      await _pump(tester, castCasting: false, dlnaCasting: true);
      expect(find.text('1.0x'), findsNothing);
    });
  });
}
