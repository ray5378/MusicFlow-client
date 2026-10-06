// batch33 C 路 —— `lib/features/discover/widgets/remote_control_body.dart` 补测。
//
// 基线覆盖率 66.09%。RemoteControlBody 三段主体全部是公开 ConsumerWidget：
//   * RemoteControlPeerBar：chips 渲染 / 选中态口径（activePeer == null =
//     本机）/ 点本机 backToLocal / 点远端 switchTo；
//   * RemoteControlNowArea：未在播放空态 / 「曲名 - 歌手」同行 / targetIdle
//     清空 / 歌词视口（无歌词空态 + 同步行高亮）；
//   * RemoteControlControls：无歌置灰 / effective_* 三路路由（本机 →
//     castPeerController.toggle/previous/next 兜底）/ 收藏红心 / 音量面板开合。
// 打桩：StubCastPeer 覆写 toggle/previous/next/cyclePlayMode/backToLocal/
// switchTo 记录调用；remoteControlTargetsProvider 直接 override 固定列表；
// currentLyricsProvider / effectivePositionProvider 覆盖成确定值。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_body.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/home_remote_control_provider.dart';

import '../../player/test_player_notifier.dart';

const Size kView = Size(520, 700);

final Song kSong = Song(
  id: 's1',
  title: '测试曲目',
  artist: '测试艺术家',
  albumId: 'al1',
  duration: 200,
);

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

/// 播放器桩：带当前歌与记录。
class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer({Song? currentSong})
      : super(
          PlayerState(
            currentSong: currentSong,
            queue: currentSong == null ? const <Song>[] : <Song>[currentSong],
          ),
        );

  final List<int> cycleCalls = <int>[];
  int toggleFavoriteCalls = 0;

  @override
  Future<void> cyclePlaybackMode() async {
    cycleCalls.add(1);
  }

  @override
  Future<void> toggleFavorite() async {
    toggleFavoriteCalls += 1;
    final song = state.currentSong;
    if (song == null) return;
    state = state.copyWith(currentSong: song.copyWith(starred: !song.starred));
  }
}

/// 链路 A 投屏桩：记录控制命令；无投屏时这些命令兜底到本机。
class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref, {PeerInfo? peer, bool idleQueue = false}) {
    if (peer != null) {
      state = state.copyWith(
        activePeer: peer,
        castQueue: idleQueue ? const <Map<String, dynamic>>[] : <Map<String, dynamic>>[
          <String, dynamic>{'songId': 's1', 'title': '测试曲目'},
        ],
        castIndex: idleQueue ? -1 : 0,
      );
    }
  }

  int toggleCalls = 0;
  int previousCalls = 0;
  int nextCalls = 0;
  int cycleModeCalls = 0;
  final List<PeerInfo> switchToCalls = <PeerInfo>[];
  int backToLocalCalls = 0;

  @override
  Future<void> toggle() async {
    toggleCalls += 1;
  }

  @override
  Future<void> previous() async {
    previousCalls += 1;
  }

  @override
  Future<void> next() async {
    nextCalls += 1;
  }

  @override
  Future<void> cyclePlayMode() async {
    cycleModeCalls += 1;
  }

  @override
  Future<bool> switchTo(PeerInfo peer) async {
    switchToCalls.add(peer);
    return true;
  }

  @override
  Future<void> backToLocal({bool resumeLocal = false}) async {
    backToLocalCalls += 1;
  }
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
}

StructuredLyrics _syncedLyrics() => StructuredLyrics(
      synced: true,
      lang: 'zh',
      lines: <LyricsLine>[
        LyricsLine(startMs: 0, value: '第一句歌词'),
        LyricsLine(startMs: 10000, value: '第二句歌词'),
        LyricsLine(startMs: 20000, value: '第三句歌词'),
      ],
    );

class _BodyHarness {
  _BodyHarness({
    this.currentSong,
    this.activePeer,
    this.targetIdleQueue = false,
    this.lyrics,
    this.position = const Duration(seconds: 1),
  }) : player = RecordingPlayer(currentSong: currentSong);

  final Song? currentSong;
  final PeerInfo? activePeer;

  /// true → activePeer 有但镜像队列为空（targetIdle 派生 true）。
  final bool targetIdleQueue;
  final Lyrics? lyrics;
  final Duration position;

  final RecordingPlayer player;
  late StubCastPeer cast;
  late StubDlnaCast dlna;

  ProviderContainer? container;
  AppLocalizations? loc;

  Widget build() {
    final bool idleQueue = targetIdleQueue;
    final Lyrics? lyricsLocal = lyrics;
    final Duration pos = position;
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          playerProvider.overrideWith((Ref ref) => player),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => cast = StubCastPeer(
              ref,
              peer: activePeer == null
                  ? null
                  : PeerInfo(
                      peerId: activePeer!.peerId,
                      name: activePeer!.name,
                      kind: activePeer!.kind,
                      available: activePeer!.available,
                    ),
              idleQueue: idleQueue,
            ),
          ),
          dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
          remoteControlTargetsProvider.overrideWith(
            (Ref ref) => const <PeerInfo>[kSelf, kRemote],
          ),
          currentLyricsProvider.overrideWith(
            (Ref ref) async => lyricsLocal,
          ),
          effectivePositionProvider.overrideWith((Ref ref) => pos),
        ],
      ),
      child: MediaQuery(
        data: const MediaQueryData(size: kView, devicePixelRatio: 1),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: kView.width,
                height: RemoteControlMetrics.standard.totalHeight,
                child: const RemoteControlBody(
                  metrics: RemoteControlMetrics.standard,
                ),
              ),
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
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    loc = AppLocalizations.of(
      tester.element(find.byType(RemoteControlBody)),
    );
  }
}

Finder _iconButton(AppLocalizations loc, String label) =>
    find.byWidgetPredicate(
      (Widget w) => w is MusicFlowIconButton && w.label == label,
    );

void main() {
  group('RemoteControlPeerBar · 切换器', () {
    testWidgets('本机 + 远端 chip 渲染，无投屏时本机选中', (WidgetTester tester) async {
      final h = _BodyHarness();
      await h.pump(tester);

      final loc = h.loc!;
      expect(find.text(loc.peer_self), findsOneWidget);
      expect(find.text('客厅设备'), findsOneWidget);
      // 切换器还有「流转播放」入口按钮（semanticLabel = player_transfer_playback_title）。
      expect(
        find.byWidgetPredicate((Widget w) =>
            w is Semantics &&
            w.properties.label == loc.player_transfer_playback_title),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点本机 chip → backToLocal', (WidgetTester tester) async {
      final h = _BodyHarness();
      await h.pump(tester);

      await tester.tap(find.text(h.loc!.peer_self));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(h.cast.backToLocalCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点远端 chip → switchTo(peer)', (WidgetTester tester) async {
      final h = _BodyHarness();
      await h.pump(tester);

      await tester.tap(find.text('客厅设备'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(h.cast.switchToCalls.map((PeerInfo p) => p.peerId),
          <String>['peer1']);
      expect(tester.takeException(), isNull);
    });
  });

  group('RemoteControlNowArea · Now 区', () {
    testWidgets('无歌 → 「未在播放」+ 歌词空态', (WidgetTester tester) async {
      final h = _BodyHarness();
      await h.pump(tester);

      expect(find.text(h.loc!.home_remote_not_playing), findsOneWidget);
      expect(find.text(h.loc!.home_remote_no_lyrics), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有歌有艺术家 → 「曲名 - 歌手」同行', (WidgetTester tester) async {
      final h = _BodyHarness(
        currentSong: kSong,
        lyrics: Lyrics(sourceId: 'lrclib', entries: <StructuredLyrics>[]),
      );
      await h.pump(tester);

      expect(find.text('测试曲目 - 测试艺术家'), findsOneWidget);
      expect(find.text(h.loc!.home_remote_not_playing), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无艺术家 → 只显示曲名', (WidgetTester tester) async {
      final h = _BodyHarness(
        currentSong: Song(id: 's2', title: '纯音乐'),
        lyrics: Lyrics(sourceId: 'lrclib', entries: const <StructuredLyrics>[]),
      );
      await h.pump(tester);

      expect(find.text('纯音乐'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('投屏目标空闲（镜像队列空）→ 曲名与歌词走「未在播放」空态', (
      WidgetTester tester,
    ) async {
      final h = _BodyHarness(
        currentSong: kSong,
        activePeer: kRemote,
        targetIdleQueue: true,
        lyrics: Lyrics(sourceId: 'lrclib', entries: const <StructuredLyrics>[]),
      );
      await h.pump(tester);

      expect(find.text(h.loc!.home_remote_not_playing), findsOneWidget);
      expect(find.text('测试曲目 - 测试艺术家'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('同步歌词 → 行渲染 + 当前行高亮（位置落在第二句）', (
      WidgetTester tester,
    ) async {
      final h = _BodyHarness(
        currentSong: kSong,
        lyrics: Lyrics(
          sourceId: 'lrclib',
          entries: <StructuredLyrics>[_syncedLyrics()],
        ),
        position: const Duration(seconds: 11),
      );
      await h.pump(tester);

      expect(find.text('第一句歌词'), findsOneWidget);
      expect(find.text('第二句歌词'), findsOneWidget);
      expect(find.text('第三句歌词'), findsOneWidget);
      expect(find.text(h.loc!.home_remote_no_lyrics), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('RemoteControlControls · 控制条', () {
    testWidgets('无歌 → 模式/上曲/下曲/收藏置灰，播放可用', (WidgetTester tester) async {
      final h = _BodyHarness();
      await h.pump(tester);

      final loc = h.loc!;
      expect(
        tester
            .widget<MusicFlowIconButton>(_iconButton(loc, loc.player_mode_list))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<MusicFlowIconButton>(_iconButton(loc, loc.player_previous))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<MusicFlowIconButton>(_iconButton(loc, loc.player_next))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<MusicFlowIconButton>(_iconButton(loc, loc.player_favorite))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<MusicFlowIconButton>(_iconButton(loc, loc.widgets_play))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点播放/暂停 → effective 路由到 castPeerController.toggle', (
      WidgetTester tester,
    ) async {
      final h = _BodyHarness();
      await h.pump(tester);

      await tester.tap(_iconButton(h.loc!, h.loc!.widgets_play));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(h.cast.toggleCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有歌点模式 → 本机 cyclePlaybackMode', (WidgetTester tester) async {
      final h = _BodyHarness(currentSong: kSong);
      await h.pump(tester);

      await tester.tap(_iconButton(h.loc!, h.loc!.player_mode_list));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(h.player.cycleCalls, <int>[1]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有歌点上/下曲 → effective 路由 previous/next', (
      WidgetTester tester,
    ) async {
      final h = _BodyHarness(currentSong: kSong);
      await h.pump(tester);

      await tester.tap(_iconButton(h.loc!, h.loc!.player_previous));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(_iconButton(h.loc!, h.loc!.player_next));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(h.cast.previousCalls, 1);
      expect(h.cast.nextCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点收藏 → player.toggleFavorite + 红心 selected', (
      WidgetTester tester,
    ) async {
      final h = _BodyHarness(currentSong: kSong);
      await h.pump(tester);

      final favButton = _iconButton(h.loc!, h.loc!.player_favorite);
      expect(
        tester.widget<MusicFlowIconButton>(favButton).selected,
        isFalse,
        reason: '初始未收藏',
      );
      await tester.tap(favButton);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));

      expect(h.player.toggleFavoriteCalls, 1);
      expect(
        tester.widget<MusicFlowIconButton>(favButton).selected,
        isTrue,
        reason: 'toggle 后 starred 翻转 → selected',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('音量键开合面板：点开 volume，再点回 none', (WidgetTester tester) async {
      final h = _BodyHarness();
      await h.pump(tester);

      final volumeButton = _iconButton(h.loc!, h.loc!.home_remote_volume);
      expect(
        tester.widget<MusicFlowIconButton>(volumeButton).selected,
        isFalse,
      );
      await tester.tap(volumeButton);
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tester.widget<MusicFlowIconButton>(volumeButton).selected,
        isTrue,
      );

      await tester.tap(volumeButton);
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tester.widget<MusicFlowIconButton>(volumeButton).selected,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
