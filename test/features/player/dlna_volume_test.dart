import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/providers/cast_peer_provider.dart';
import 'package:musicflow_client/providers/dlna_provider.dart';
import 'package:musicflow_client/providers/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/palette_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';

import 'test_player_notifier.dart';

/// 记录 setVolume 下发的假直投 notifier：验证音量条在直投态路由到 DLNA。
class _RecCastNotifier extends DlnaCastNotifier {
  _RecCastNotifier(super.ref, DlnaCastState initial, this.calls) {
    state = initial;
  }

  final List<int> calls;

  @override
  Future<void> setVolume(int volume) async {
    calls.add(volume.clamp(0, 100));
    state = state.copyWith(
      status: state.status.copyWith(volume: volume.clamp(0, 100)),
    );
  }
}

class _FakeDevicesNotifier extends DlnaDevicesNotifier {
  _FakeDevicesNotifier(super.ref, DlnaDevicesState initial) {
    state = initial;
  }

  @override
  Future<void> scan() async {}
}

DlnaDevice _device(String id, String name) => DlnaDevice(
      id: id,
      name: name,
      location: 'http://192.168.1.10:8000/desc.xml',
      lastSeen: DateTime(2024, 1, 1),
      avTransportUrl: 'http://192.168.1.10:8000/AVTransport/control',
      renderingControlUrl: 'http://192.168.1.10:8000/RenderingControl/control',
    );

DlnaCastTrack _track(String id, String title) =>
    DlnaCastTrack(songId: id, title: title, artist: '周杰伦');

void main() {
  final song = Song(id: 's1', title: '夜曲', artist: '周杰伦');
  final device = _device('u1', '客厅电视');
  final tracks = [_track('s1', '夜曲')];

  PlayerState playerState() => PlayerState(
        currentSong: song,
        queue: [song],
        currentIndex: 0,
        isPlaying: false,
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 4),
        bufferedPosition: const Duration(minutes: 2),
        loopMode: LoopMode.all,
        currentQuality: AudioQualityLevel.original,
        playbackSource: PlaybackSource.stream,
        currentBitRateKbps: 320,
        volume: 0.6,
      );

  List<int> calls = [];
  int deviceVolume = 40;

  Widget app() {
    final cast = DlnaCastState(
      currentDevice: device,
      isCasting: true,
      queue: tracks,
      currentIndex: 0,
      status: DlnaDeviceStatus(state: 'PLAYING', volume: deviceVolume),
    );
    return ProviderScope(
      overrides: [
        playerProvider.overrideWith((ref) => TestPlayerNotifier(playerState())),
        castPeerControllerProvider.overrideWith((ref) => CastPeerController(ref)),
        currentSongPaletteProvider.overrideWith((ref) async => null),
        resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
          MusicFlowMediaVisuals.fallback(),
        ),
        currentLyricsProvider.overrideWith((ref) async => null),
        dlnaCastProvider.overrideWith((ref) => _RecCastNotifier(ref, cast, calls)),
        dlnaDevicesProvider.overrideWith(
          (ref) => _FakeDevicesNotifier(ref, const DlnaDevicesState()),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const FullPlayerPage(),
      ),
    );
  }

  setUp(() {
    calls = [];
    deviceVolume = 40;
  });

  testWidgets('直投态拖动音量条路由到 DLNA setVolume，并显示设备音量', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(app());
    // 全屏页自有循环动画，用有界帧推进。
    await tester.pump(const Duration(milliseconds: 300));

    // 音量按钮标签应显示设备回报音量 40%（而非本机 60%）。
    expect(find.byTooltip('音量 40%'), findsOneWidget);

    // 打开音量浮层。
    await tester.tap(find.byTooltip('音量 40%'));
    await tester.pump(const Duration(milliseconds: 300));

    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);

    // 垂直音量条向上拖动增大。
    final rect = tester.getRect(slider);
    await tester.dragFrom(
      Offset(rect.center.dx, rect.center.dy),
      Offset(0, -rect.height * 0.5),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 松手必发最终值 → 直投 notifier.setVolume 被调用，且已增大。
    expect(calls, isNotEmpty);
    expect(calls.last, greaterThan(deviceVolume));
    expect(tester.takeException(), isNull);
  });
}