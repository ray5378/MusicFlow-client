import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/local_dlna_cast_sheet.dart';
import 'package:musicflow_client/providers/dlna_provider.dart';
import 'package:musicflow_client/providers/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/palette_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';

import 'test_player_notifier.dart';

/// 不触网假 notifier：渲染链路 B 面板无需走 SSDP/SOAP/中继。
class _FakeCastNotifier extends DlnaCastNotifier {
  _FakeCastNotifier(Ref ref, DlnaCastState initial) : super(ref) {
    state = initial;
  }

  @override
  Future<bool> startCast(
    DlnaDevice device,
    List<DlnaCastTrack> tracks, {
    int startIndex = 0,
  }) async {
    state = state.copyWith(
      isCasting: true,
      currentDevice: device,
      queue: List.unmodifiable(tracks),
      currentIndex: startIndex,
    );
    return true;
  }

  @override
  Future<void> stopCast() async {
    state = state.copyWith(
      clearDevice: true,
      isCasting: false,
      queue: const [],
      currentIndex: -1,
    );
  }

  @override
  Future<void> next() async {
    if (state.currentIndex + 1 < state.queue.length) {
      state = state.copyWith(currentIndex: state.currentIndex + 1);
    }
  }

  @override
  Future<void> previous() async {
    if (state.currentIndex - 1 >= 0) {
      state = state.copyWith(currentIndex: state.currentIndex - 1);
    }
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(status: state.status.copyWith(state: 'PAUSED'));
  }

  @override
  Future<void> resume() async {
    state = state.copyWith(status: state.status.copyWith(state: 'PLAYING'));
  }
}

class _FakeDevicesNotifier extends DlnaDevicesNotifier {
  _FakeDevicesNotifier(Ref ref, DlnaDevicesState initial) : super(ref) {
    state = initial;
  }

  @override
  Future<void> scan() async {
    // 触发面板 initState 的自动扫描时静默跳过：测试环境不建真实套接字。
  }

  void emit(DlnaDevicesState next) => state = next;
}

DlnaDevice _device(String id, String name) => DlnaDevice(
      id: id,
      name: name,
      location: 'http://192.168.1.10:8000/desc.xml',
      lastSeen: DateTime(2024, 1, 1),
      avTransportUrl: 'http://192.168.1.10:8000/AVTransport/control',
      renderingControlUrl: 'http://192.168.1.10:8000/RenderingControl/control',
    );

DlnaCastTrack _track(String songId, String title, String artist) =>
    DlnaCastTrack(songId: songId, title: title, artist: artist);

Widget _app({
  required DlnaCastState cast,
  required DlnaDevicesState devices,
  PlayerState? player,
  bool fullPlayer = false,
  // 直投 http 基地址：默认给一个可用值保持既有设备列表行为；
  // 「无 http 地址」用例显式传 null 验证提示与投流拦截。
  String? castHttpBase = 'http://192.168.1.5:4533',
}) {
  return ProviderScope(
    overrides: [
      if (player != null)
        playerProvider.overrideWith((ref) => TestPlayerNotifier(player)),
      currentSongPaletteProvider.overrideWith((ref) async => null),
      resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
        MusicFlowMediaVisuals.fallback(),
      ),
      currentLyricsProvider.overrideWith((ref) async => null),
      dlnaCastHttpBaseProvider.overrideWithValue(castHttpBase),
      dlnaCastProvider.overrideWith((ref) => _FakeCastNotifier(ref, cast)),
      dlnaDevicesProvider.overrideWith((ref) => _FakeDevicesNotifier(ref, devices)),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: fullPlayer
          ? const FullPlayerPage()
          : const Scaffold(body: SafeArea(child: LocalDlnaCastSheet())),
    ),
  );
}

void main() {
  const dlnaLocalFilled = AppIcons.dlnaLocalFilled;

  group('LocalDlnaCastSheet 空态', () {
    testWidgets('无设备时展示空态提示与扫描入口', (tester) async {
      await tester.pumpWidget(
        _app(
          cast: const DlnaCastState(),
          devices: const DlnaDevicesState(),
        ),
      );
      await tester.pump(); // 走完 post-frame 的自动扫描（fake no-op）

      expect(find.text('局域网 DLNA 直投'), findsOneWidget);
      expect(find.text('扫描局域网 DLNA 设备'), findsOneWidget);
      expect(
        find.text(
          '未发现可用 DLNA 设备。请确认与音箱/电视处于同一网络后再扫描。',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('无可用 http 地址时不出设备列表，只展示提示（禁止投流）', (tester) async {
      final online = _device('u1', '客厅电视');
      await tester.pumpWidget(
        _app(
          cast: const DlnaCastState(),
          devices: DlnaDevicesState(devices: [online]),
          castHttpBase: null,
        ),
      );
      await tester.pump();

      // 提示出现（ray 指定文案）
      expect(
        find.text('直投功能必须在媒体库中先添加http连接'),
        findsOneWidget,
      );
      // 设备列表不渲染 → 无法发起投流
      expect(find.text('客厅电视'), findsNothing);
      expect(find.text('扫描局域网 DLNA 设备'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('在线设备渲染成可点播行，离线/禁用设备不展示', (tester) async {
      final online = _device('u1', '客厅电视');
      final offline = _device('u2', '卧室音响').copyWith(available: false);
      final disabled = _device('u3', '禁用设备').copyWith(disabled: true);

      await tester.pumpWidget(
        _app(
          cast: const DlnaCastState(),
          devices: DlnaDevicesState(devices: [online, offline, disabled]),
        ),
      );
      await tester.pump();

      expect(find.text('客厅电视'), findsOneWidget);
      expect(find.text('本机局域网发现 · 直投'), findsNWidgets(1));
      expect(find.text('卧室音响'), findsNothing);
      expect(find.text('禁用设备'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('LocalDlnaCastSheet 投屏态', () {
    final device = _device('u1', '客厅电视');
    final tracks = [
      _track('s1', '夜曲', '周杰伦'),
      _track('s2', '晴天', '周杰伦'),
    ];

    testWidgets('展示当前曲目、播放控制与停止入口', (tester) async {
      await tester.pumpWidget(
        _app(
          cast: DlnaCastState(
            currentDevice: device,
            isCasting: true,
            queue: tracks,
            currentIndex: 0,
            status: const DlnaDeviceStatus(state: 'PLAYING'),
          ),
          devices: const DlnaDevicesState(),
        ),
      );
      await tester.pump();

      expect(find.text('正在投屏到「客厅电视」'), findsOneWidget);
      expect(find.text('夜曲 · 周杰伦'), findsOneWidget);
      expect(find.text('停止局域网投屏'), findsOneWidget);
      // 播放中 → 显示暂停图标
      expect(find.byIcon(AppIcons.pause), findsOneWidget);
      expect(find.byIcon(AppIcons.play), findsNothing);
      expect(find.byIcon(dlnaLocalFilled), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「下一首」推进独立投屏队列游标', (tester) async {
      await tester.pumpWidget(
        _app(
          cast: DlnaCastState(
            currentDevice: device,
            isCasting: true,
            queue: tracks,
            currentIndex: 0,
            status: const DlnaDeviceStatus(state: 'PLAYING'),
          ),
          devices: const DlnaDevicesState(),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(AppIcons.next));
      await tester.pump();

      expect(find.text('晴天 · 周杰伦'), findsOneWidget);
      expect(find.text('夜曲 · 周杰伦'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('全屏播放器独立入口', () {
    final song = Song(id: 's1', title: '夜曲', artist: '周杰伦');
    PlayerState playerState() => PlayerState(
          currentSong: song,
          queue: [song],
          currentIndex: 0,
          isPlaying: true,
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 4),
          bufferedPosition: const Duration(minutes: 2),
          loopMode: LoopMode.all,
          currentQuality: AudioQualityLevel.original,
          playbackSource: PlaybackSource.stream,
          currentBitRateKbps: 320,
        );

    testWidgets('展示独立电视图标入口，投屏态高亮并打开直投面板', (tester) async {
      final cast = DlnaCastState(
        currentDevice: _device('u1', '客厅电视'),
        isCasting: true,
        queue: [_track('s1', '夜曲', '周杰伦')],
        currentIndex: 0,
        status: const DlnaDeviceStatus(state: 'PLAYING'),
      );
      await tester.pumpWidget(
        _app(
          cast: cast,
          devices: const DlnaDevicesState(),
          player: playerState(),
          fullPlayer: true,
        ),
      );
      await tester.pump();

      // 独立图标（电视）存在，且与「切换播放器」的信号塔图标共存不冲突。
      expect(find.byIcon(AppIcons.dlnaLocal), findsOneWidget);
      expect(find.byIcon(AppIcons.signalTower), findsOneWidget);

      // 投屏态入口高亮（selected）。
      final pressable = find.ancestor(
        of: find.byIcon(AppIcons.dlnaLocal),
        matching: find.byType(MusicFlowPressable),
      );
      expect(
        tester.widget<MusicFlowPressable>(pressable.first).selected ?? false,
        isTrue,
      );

      await tester.tap(find.byIcon(AppIcons.dlnaLocal));
      // 全屏页自带循环动画，不能用 pumpAndSettle（永不结束），改走有界帧。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('局域网 DLNA 直投'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('投屏态：播放控制细节', () {
    final device = _device('u1', '客厅电视');
    final tracks = [
      _track('s1', '夜曲', '周杰伦'),
      _track('s2', '晴天', '周杰伦'),
    ];

    Widget panel({required int currentIndex, String state = 'PLAYING'}) =>
        _app(
          cast: DlnaCastState(
            currentDevice: device,
            isCasting: true,
            queue: tracks,
            currentIndex: currentIndex,
            status: DlnaDeviceStatus(state: state),
          ),
          devices: const DlnaDevicesState(),
        );

    testWidgets('首曲时「上一首」禁用（点击无效）', (tester) async {
      await tester.pumpWidget(panel(currentIndex: 0));
      await tester.pump();

      await tester.tap(find.byIcon(AppIcons.previous));
      await tester.pump();

      expect(find.text('夜曲 · 周杰伦'), findsOneWidget);
      expect(find.text('晴天 · 周杰伦'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('次曲时「上一首」回退到首曲', (tester) async {
      await tester.pumpWidget(panel(currentIndex: 1));
      await tester.pump();

      await tester.tap(find.byIcon(AppIcons.previous));
      await tester.pump();

      expect(find.text('夜曲 · 周杰伦'), findsOneWidget);
      expect(find.text('晴天 · 周杰伦'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('播放/暂停按钮随状态切换', (tester) async {
      await tester.pumpWidget(panel(currentIndex: 0, state: 'PLAYING'));
      await tester.pump();
      expect(find.byIcon(AppIcons.pause), findsOneWidget);

      await tester.tap(find.byIcon(AppIcons.pause));
      await tester.pump();
      expect(find.byIcon(AppIcons.play), findsOneWidget);
      expect(find.byIcon(AppIcons.pause), findsNothing);

      await tester.tap(find.byIcon(AppIcons.play));
      await tester.pump();
      expect(find.byIcon(AppIcons.pause), findsOneWidget);
      expect(find.byIcon(AppIcons.play), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('停止投屏后回到设备列表', (tester) async {
      await tester.pumpWidget(panel(currentIndex: 0));
      await tester.pump();
      expect(find.text('正在投屏到「客厅电视」'), findsOneWidget);

      await tester.tap(find.text('停止局域网投屏'));
      await tester.pumpAndSettle();

      expect(find.text('正在投屏到「客厅电视」'), findsNothing);
      expect(find.text('扫描局域网 DLNA 设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('投屏面板：从设备行发起点播', () {
    final device = _device('u1', '客厅电视');

    PlayerState queueState(List<Song> queue) => PlayerState(
          currentSong: queue.isEmpty ? null : queue.first,
          queue: queue,
          currentIndex: queue.isEmpty ? -1 : 0,
          isPlaying: true,
          position: Duration.zero,
          duration: Duration.zero,
          bufferedPosition: Duration.zero,
          loopMode: LoopMode.all,
          currentQuality: AudioQualityLevel.original,
          playbackSource: PlaybackSource.stream,
          currentBitRateKbps: 320,
        );

    testWidgets('点击在线设备行进入投屏态', (tester) async {
      final song = Song(id: 's1', title: '夜曲', artist: '周杰伦');
      await tester.pumpWidget(
        _app(
          cast: const DlnaCastState(),
          devices: DlnaDevicesState(devices: [device]),
          player: queueState([song]),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('客厅电视'));
      await tester.pumpAndSettle();

      expect(find.text('正在投屏到「客厅电视」'), findsOneWidget);
      expect(find.text('夜曲 · 周杰伦'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('播放队列为空时点设备不投屏', (tester) async {
      await tester.pumpWidget(
        _app(
          cast: const DlnaCastState(),
          devices: DlnaDevicesState(devices: [device]),
          player: queueState(const []),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('客厅电视'));
      await tester.pumpAndSettle();

      expect(find.text('正在投屏到「客厅电视」'), findsNothing);
      expect(find.text('扫描局域网 DLNA 设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}