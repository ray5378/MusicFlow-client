// b38c3 —— Route C 补测：features/player/widgets/local_dlna_cast_sheet.dart 剩余可达缺口。
//   * 282：无设备且「扫描中」→ 展示 loc.dlna_searching（既有用例只打了非扫描态 → 283）。
//   * 174/177：投屏态但 currentIndex 越界（队列播完）→ 展示 loc.dlna_queue_ended，
//     且该「正在投屏到…」行 onPressed 为 no-op（点一下不炸）。
//   * 71-73：设备行点播时 startCast 返回 false → 弹 loc.dlna_cast_failed 错误提示。
//
// 报告为**不可达 / 防御性死代码**：
//   * 42-44：_startCast 里「dlnaCastHttpBaseProvider == null → 弹 kDlnaCastHttpRequiredHint」。
//     但同一 provider 在 _buildContent 已先判：为 null 时**不渲染设备列表**（只出提示），
//     因此不存在「设备行可点却 http base 为 null」的可达状态；该分支只在面板打开后地址
//     被改动时才可能触发，widget 测试无法构造。
//
// 手法沿用既有 local_dlna_cast_sheet_test.dart 的假 notifier（不触网）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/local_dlna_cast_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

import '../test_player_notifier.dart';

late AppLocalizations loc;

class _FakeCastNotifier extends DlnaCastNotifier {
  _FakeCastNotifier(super.ref, DlnaCastState initial, {this.startOk = true}) {
    state = initial;
  }

  final bool startOk;
  final List<String> starts = <String>[];

  @override
  Future<bool> startCast(
    DlnaDevice device,
    List<DlnaCastTrack> tracks, {
    int startIndex = 0,
  }) async {
    starts.add('startCast:${device.id}');
    if (!startOk) return false;
    state = state.copyWith(
      isCasting: true,
      currentDevice: device,
      queue: List<DlnaCastTrack>.unmodifiable(tracks),
      currentIndex: startIndex,
    );
    return true;
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

DlnaCastTrack _track(String songId, String title, String artist) =>
    DlnaCastTrack(songId: songId, title: title, artist: artist);

Widget _app({
  required DlnaCastState cast,
  required DlnaDevicesState devices,
  PlayerState? player,
  bool startOk = true,
}) {
  return ProviderScope(
    overrides: <Override>[
      if (player != null)
        playerProvider.overrideWith((ref) => TestPlayerNotifier(player)),
      currentSongPaletteProvider.overrideWith((ref) async => null),
      resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
        MusicFlowMediaVisuals.fallback(),
      ),
      currentLyricsProvider.overrideWith((ref) async => null),
      dlnaCastHttpBaseProvider.overrideWithValue('http://192.168.1.5:4533'),
      dlnaCastProvider.overrideWith(
        (ref) => _FakeCastNotifier(ref, cast, startOk: startOk),
      ),
      dlnaDevicesProvider.overrideWith((ref) => _FakeDevicesNotifier(ref, devices)),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: const Scaffold(body: SafeArea(child: LocalDlnaCastSheet())),
    ),
  );
}

PlayerState _queueState(List<Song> queue) => PlayerState(
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

void main() {
  testWidgets('无设备且扫描中 → 展示「搜索中」文案（282）', (tester) async {
    await tester.pumpWidget(
      _app(
        cast: const DlnaCastState(),
        devices: const DlnaDevicesState(isScanning: true),
      ),
    );
    await tester.pump();

    expect(find.text(loc.dlna_searching), findsOneWidget);
    expect(find.text(loc.dlna_no_device), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('投屏态队列播完 → 展示队列结束文案，且头部行可点不炸（174/177）',
      (tester) async {
    final device = _device('u1', '客厅电视');
    await tester.pumpWidget(
      _app(
        cast: DlnaCastState(
          currentDevice: device,
          isCasting: true,
          queue: <DlnaCastTrack>[_track('s1', '夜曲', '周杰伦')],
          // 越界 → currentTrack == null。
          currentIndex: -1,
          status: const DlnaDeviceStatus(state: 'STOPPED'),
        ),
        devices: const DlnaDevicesState(),
      ),
    );
    await tester.pump();

    expect(find.text(loc.player_casting_to(device.name)), findsOneWidget);
    expect(find.text(loc.dlna_queue_ended), findsOneWidget);

    // 头部行 onPressed: () {}（no-op）——点一下只应无异常。
    await tester.tap(find.text(loc.player_casting_to(device.name)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('设备行点播但 startCast 失败 → 弹失败提示（71-73）', (tester) async {
    final device = _device('u1', '客厅电视');
    final song = Song(id: 's1', title: '夜曲', artist: '周杰伦');
    await tester.pumpWidget(
      _app(
        cast: const DlnaCastState(),
        devices: DlnaDevicesState(devices: <DlnaDevice>[device]),
        player: _queueState(<Song>[song]),
        startOk: false,
      ),
    );
    await tester.pump();

    expect(find.text(device.name), findsOneWidget);
    await tester.tap(find.text(device.name));
    await tester.pump();
    await tester.pump();

    expect(find.text(loc.dlna_cast_failed(device.name)), findsOneWidget,
        reason: 'startCast 返回 false → 展示失败提示');
    // 未进入投屏态。
    expect(find.text(loc.player_casting_to(device.name)), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
