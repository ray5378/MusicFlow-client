// b38c3 —— Route C 补测：`lib/features/player/widgets/song_options_sheet.dart` 剩余缺口。
//
// 既有 b33c / b36b 已覆盖收藏、三路「下一首」、isPreview、当前曲隐藏行、无 id 禁用、
// 长按复制、extraActions、二级加入歌单、桌面锚点。
//
// 覆盖点：
//   * 99：歌曲无歌手 → 歌手名回落「未知艺术家」。
//   * 117/118：投屏中（链路 A）点「加入投屏队列」→ castPeerController.enqueueSongs。
//   * 121/122/123：DLNA 直投中（链路 B）点同一行 → dlnaCast.enqueueSongs + 提示。
//
// 跳过并报告：
//   * 403 / 409 / 421 / 437：`_SongOptionRow` 的「禁用态」配色/语义分支。该私有
//     行组件在本文件里所有使用点都至少给了 onPressed 或 onLongPress
//     （歌手/专辑行恒有 onLongPress），`enabled` 恒为 true ⇒ 禁用态不可达。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/song_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

const Size kSheetView = Size(520, 1000);

class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer(super.initial);
}

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref, {PeerInfo? peer}) {
    if (peer != null) {
      state = state.copyWith(activePeer: peer);
    }
  }

  final List<dynamic> enqueueCalls = <dynamic>[];

  @override
  Future<void> enqueueSongs(List<dynamic> songs) async {
    enqueueCalls.addAll(songs);
  }
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref, {bool casting = false}) {
    if (casting) {
      state = DlnaCastState(isCasting: true);
    }
  }

  final List<Song> enqueueCalls = <Song>[];

  @override
  Future<void> enqueueSongs(List<Song> songs) async {
    enqueueCalls.addAll(songs);
  }
}

class _RefProbe extends ConsumerWidget {
  const _RefProbe({required this.onReady});

  final void Function(BuildContext context) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(context);
    return const SizedBox.shrink();
  }
}

Future<void> settle(WidgetTester tester, {int frames = 14}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _actionRow(String title) => find.widgetWithText(MusicFlowPressable, title);

class Harness {
  Harness({
    required this.song,
    PeerInfo? activePeer,
    bool dlnaCasting = false,
  }) : _activePeer = activePeer,
       _dlnaCasting = dlnaCasting;

  final Song song;
  final PeerInfo? _activePeer;
  final bool _dlnaCasting;

  final RecordingPlayer player = RecordingPlayer(PlayerState());
  late StubCastPeer cast;
  late StubDlnaCast dlna;

  ProviderContainer? container;
  AppLocalizations? loc;
  BuildContext? hostContext;

  Widget build() {
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          playerProvider.overrideWith((Ref ref) => player),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => cast = StubCastPeer(ref, peer: _activePeer),
          ),
          dlnaCastProvider.overrideWith(
            (Ref ref) => dlna = StubDlnaCast(ref, casting: _dlnaCasting),
          ),
        ],
      ),
      child: MediaQuery(
        data: const MediaQueryData(size: kSheetView, devicePixelRatio: 1),
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
            body: _RefProbe(onReady: (BuildContext ctx) => hostContext = ctx),
          ),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = kSheetView;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: 4);
  }

  Future<void> open(WidgetTester tester) async {
    unawaited(showSongOptionsSheet(context: hostContext!, song: song));
    await settle(tester, frames: 14);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('歌曲无歌手 → 歌手名回落「未知艺术家」（99）', (tester) async {
    final song = Song(id: 's-na', title: '无歌手', album: '专辑A', albumId: 'al1');
    final h = Harness(song: song);
    await h.pump(tester);
    await h.open(tester);

    expect(_actionRow(h.loc!.song_option_artist(h.loc!.song_option_unknown_artist)),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('投屏中（链路 A）点「加入投屏队列」→ cast enqueueSongs（117/118）',
      (tester) async {
    final song = Song(id: 's-cast', title: '投屏曲', artist: '歌手', artistId: 'ar1');
    final h = Harness(
      song: song,
      activePeer: const PeerInfo(
        peerId: 'dlna:30',
        name: '主卧',
        kind: 'dlna',
        available: true,
      ),
    );
    await h.pump(tester);
    await h.open(tester);

    // 投屏中(enqueued) → 行标题为「加入投屏队列」。
    final row = _actionRow(h.loc!.song_option_enqueue);
    expect(row, findsOneWidget);
    await tester.tap(row);
    await settle(tester, frames: 16);

    expect(h.cast.enqueueCalls, isNotEmpty,
        reason: '链路 A 投屏中应把歌加进后端投屏队列');
    expect(tester.takeException(), isNull);
  });

  testWidgets('DLNA 直投中（链路 B）点「加入投屏队列」→ dlna enqueueSongs（121-123）',
      (tester) async {
    final song = Song(id: 's-dlna', title: '直投曲', artist: '歌手', artistId: 'ar1');
    final h = Harness(song: song, dlnaCasting: true);
    await h.pump(tester);
    await h.open(tester);

    final row = _actionRow(h.loc!.song_option_enqueue);
    expect(row, findsOneWidget);
    await tester.tap(row);
    await settle(tester, frames: 16);

    expect(h.dlna.enqueueCalls, isNotEmpty,
        reason: '链路 B 直投中应把歌加进 DLNA 直投队列');
    expect(tester.takeException(), isNull);
  });
}
