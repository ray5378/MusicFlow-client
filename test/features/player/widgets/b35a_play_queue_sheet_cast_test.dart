// b35a —— play_queue_sheet.dart 队列弹窗「装配层」补测（Route A 尾部攻坚）。
//
// batch32 已覆盖视图层（PlayQueueSheetView / CastQueueSheetView 直接渲染）；
// 本文件打剩下的 PlayQueueSheet 装配层闭包与视图内部残余分支：
//   * 链路 A 投屏态：点行 → jumpTo、直接调 ReorderableListView.onReorder →
//     reorderQueue 下发（拖拽手势时序脆，沿用 b32c 的直调技巧）；
//   * 链路 B（局域网 DLNA 直投）态：点行 → playAt、onReorder → reorderQueue；
//   * 本机队列：长按行 → showSongOptionsSheet（onOpenSongActions 装配闭包）
//     → 「移出队列」→ removeFromQueue；
//   * onClose 为空时投屏队列头部关闭按钮走 Navigator.maybePop；
//   * CastQueueSheetView 内部：非空队列 + currentIndex=-1 的 initState else
//     分支（直接放行封面）；didUpdateWidget 换 currentIndex 重新居中；
//   * PlayQueueSheetView 本机列表同款 initState else 分支。
//
// 发现的疑似缺陷只注释记录，不改产品代码（见 _RecCast 下方说明）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

import '../test_player_notifier.dart';

AppLocalizations? _loc;

final List<Song> kSongs = <Song>[
  Song(id: 'q1', title: '本机曲一', artist: '艺人'),
  Song(id: 'q2', title: '本机曲二', artist: '艺人'),
  Song(id: 'q3', title: '本机曲三', artist: '艺人'),
];

List<Map<String, dynamic>> castQueue() => const <Map<String, dynamic>>[
  <String, dynamic>{'songId': 'c1', 'title': '投屏曲一', 'artist': '艺人'},
  <String, dynamic>{'songId': 'c2', 'title': '投屏曲二', 'artist': '艺人'},
  <String, dynamic>{'songId': 'c3', 'title': '投屏曲三', 'artist': '艺人'},
];

/// 链路 A 投屏控制桩：可配置队列快照 + 记录队列操作。
class _RecCast extends CastPeerController {
  _RecCast(super.ref);

  final List<int> jumps = <int>[];
  final List<int> removes = <int>[];
  final List<String> reorders = <String>[];
  int clearCalls = 0;

  void apply({
    required List<Map<String, dynamic>> queue,
    required int index,
    String playMode = 'all',
  }) {
    state = state.copyWith(
      activePeer: const PeerInfo(
        peerId: 'peer-1',
        name: '客厅音箱',
        kind: 'player',
        available: true,
      ),
      castQueue: queue,
      castIndex: index,
      playMode: playMode,
    );
  }

  @override
  Future<void> jumpTo(int index) async {
    jumps.add(index);
  }

  @override
  Future<void> removeQueueItem(int index) async {
    removes.add(index);
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    reorders.add('$from>$to');
  }

  @override
  Future<void> clearCastQueue() async {
    clearCalls += 1;
  }
}

/// 链路 B 直投控制桩。
class _RecDlna extends DlnaCastNotifier {
  _RecDlna(super.ref, {bool casting = false}) {
    if (casting) {
      state = const DlnaCastState(
        isCasting: true,
        currentIndex: 0,
        playMode: 'all',
      );
    }
  }

  final List<int> playAts = <int>[];
  final List<int> removes = <int>[];
  final List<String> reorders = <String>[];
  int stopCalls = 0;

  @override
  Future<void> playAt(int index) async {
    playAts.add(index);
  }

  @override
  Future<void> removeQueueItem(int index) async {
    removes.add(index);
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    reorders.add('$from>$to');
  }

  @override
  Future<void> stopCast() async {
    stopCalls += 1;
  }
}

/// 本机队列「移出队列」路径需要的歌单仓库桩（song options sheet 内部读取）。
class _B35aFakePlaylistRepository extends PlaylistRepository {
  _B35aFakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));

  @override
  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    bool? public,
    List<String>? songIdsToAdd,
    List<int>? songIndexesToRemove,
  }) async {}

  @override
  Future<List<Playlist>> getPlaylists({int? size}) async => const <Playlist>[];
}

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Host extends StatefulWidget {
  const _Host({super.key, required this.child});

  final Widget child;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  BuildContext? hostContext;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (BuildContext context) {
          hostContext = context;
          return widget.child;
        },
      ),
    );
  }
}

/// 装配层 harness：直接挂 PlayQueueSheet，桩注入三条链路。
class SheetHarness {
  SheetHarness({
    this.castQueue,
    this.castIndex = 0,
    this.dlnaCasting = false,
    this.playerQueue = const <Song>[],
    this.playerIndex = 0,
    this.onClose,
  });

  final List<Map<String, dynamic>>? castQueue;
  final int castIndex;
  final bool dlnaCasting;
  final List<Song> playerQueue;
  final int playerIndex;
  final VoidCallback? onClose;

// ignore: library_private_types_in_public_api
  late _RecCast cast;
// ignore: library_private_types_in_public_api
  late _RecDlna dlna;
  late TestPlayerNotifier player;
  ProviderContainer? container;
  BuildContext? hostContext;

  Widget build() {
    final playerNotifier = TestPlayerNotifier(
      PlayerState(
        queue: playerQueue,
        currentIndex: playerIndex,
        currentSong: playerQueue.isEmpty ? null : playerQueue[playerIndex],
      ),
    );
    player = playerNotifier;
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          playerProvider.overrideWith((Ref ref) => playerNotifier),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => cast = _RecCast(ref),
          ),
          dlnaCastProvider.overrideWith(
            (Ref ref) => dlna = _RecDlna(ref, casting: dlnaCasting),
          ),
          resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
            MusicFlowMediaVisuals.fallback(),
          ),
          playlistRepositoryProvider.overrideWith(
            (Ref ref) => _B35aFakePlaylistRepository(),
          ),
          ensureActiveAddressProvider.overrideWith(
            (Ref ref) async => const ServerAddress(
              id: 'addr-1',
              libraryId: 'lib-1',
              label: '主线路',
              url: 'https://example.test',
              priority: 0,
            ),
          ),
          playlistsProvider.overrideWith((Ref ref) async => const <Playlist>[]),
          playlistsLoadFailedProvider.overrideWith((Ref ref) => false),
        ],
      ),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) {
          _loc = AppLocalizations.of(context);
          return child!;
        },
        home: _Host(
          key: _hostKey,
          child: PlayQueueSheet(onClose: onClose),
        ),
      ),
    );
  }

  static const Key _hostKey = ValueKey<String>('b35a_sheet_host');

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    // 让桩的 apply 生效：build 里先建桩再改 state。
    if (castQueue != null) {
      cast.apply(queue: castQueue!, index: castIndex);
    }
    await tester.pump();
    await settle(tester);
  }
}

void main() {
  group('PlayQueueSheet · 链路 A 投屏装配层', () {
    testWidgets('投屏态渲染设备队列快照,点行回调 jumpTo 并关闭', (tester) async {
      var closed = false;
      final harness = SheetHarness(
        castQueue: castQueue(),
        castIndex: 1,
        onClose: () => closed = true,
      );
      await harness.pump(tester);

      expect(
        find.text(_loc!.queue_cast_count(3, '客厅音箱')),
        findsOneWidget,
      );
      expect(find.text('投屏曲三'), findsOneWidget);

      await tester.tap(find.text('投屏曲三'));
      await settle(tester, frames: 6);

      expect(harness.cast.jumps, <int>[2]);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onReorder 装配闭包直接下发 reorderQueue(from,to)', (tester) async {
      final harness = SheetHarness(castQueue: castQueue(), castIndex: 1);
      await harness.pump(tester);

      final rlv = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      rlv.onReorder!(0, 2); // ignore: deprecated_member_use
      rlv.onReorder!(1, 1); // ignore: deprecated_member_use

      expect(harness.cast.reorders, <String>['0>2'],
          reason: 'from==to 不应下发');
      expect(tester.takeException(), isNull);
    });

    testWidgets('onClose 为空时投屏队列关闭按钮走 Navigator.maybePop 不崩溃', (
      tester,
    ) async {
      final harness = SheetHarness(castQueue: castQueue(), castIndex: 1);
      await harness.pump(tester);

      await tester.tap(find.byIcon(AppIcons.close));
      await settle(tester, frames: 6);

      expect(find.byType(PlayQueueSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('PlayQueueSheet · 链路 B 直投装配层', () {
    testWidgets('直投态展示本机镜像队列,点行回调 playAt', (tester) async {
      final harness = SheetHarness(
        dlnaCasting: true,
        playerQueue: kSongs,
        playerIndex: 0,
      );
      await harness.pump(tester);

      expect(find.text('本机曲二'), findsOneWidget);

      await tester.tap(find.text('本机曲三'));
      await settle(tester, frames: 6);

      expect(harness.dlna.playAts, <int>[2]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('直投态 onReorder 装配闭包下发 reorderQueue', (tester) async {
      final harness = SheetHarness(
        dlnaCasting: true,
        playerQueue: kSongs,
        playerIndex: 0,
      );
      await harness.pump(tester);

      final rlv = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      rlv.onReorder!(2, 0); // ignore: deprecated_member_use

      expect(harness.dlna.reorders, <String>['2>0']);
      expect(tester.takeException(), isNull);
    });
  });

  group('PlayQueueSheet · 本机队列装配层', () {
    testWidgets('长按行打开歌曲操作面板,「移出队列」下发 removeFromQueue', (tester) async {
      final harness = SheetHarness(playerQueue: kSongs, playerIndex: 0);
      await harness.pump(tester);

      await tester.longPress(find.text('本机曲二'));
      await settle(tester, frames: 14);

      // showSongOptionsSheet 已打开（装配层 onOpenSongActions 闭包生效）。
      expect(find.byType(MusicFlowBottomSheet), findsOneWidget);

      await tester.tap(find.text(_loc!.queue_remove));
      await settle(tester, frames: 8);

      expect(harness.player.removedIndices, <int>[1]);
      expect(tester.takeException(), isNull);
    });
  });

  group('队列列表内部残余分支', () {
    testWidgets('CastQueueSheetView:非空队列 currentIndex=-1 走 initState 放行分支', (
      tester,
    ) async {
      await _pumpView(
        tester,
        CastQueueSheetView(
          queue: kSongs,
          currentIndex: -1,
          deviceName: '无当前设备',
          onSelect: (int index) async {},
          onRemove: (int index) {},
          onReorder: (int from, int to) {},
          onClear: () async {},
        ),
      );

      // 行照常渲染（封面延载 gate 直接放行，不卡占位）。
      expect(find.text('本机曲一'), findsOneWidget);
      expect(find.text('本机曲三'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CastQueueSheetView:currentIndex 变化触发 didUpdateWidget 重新居中', (
      tester,
    ) async {
      final songs = List<Song>.generate(
        60,
        (int i) => Song(id: 'c$i', title: '投屏长曲$i', artist: 'A'),
      );
      await _pumpView(
        tester,
        CastQueueSheetView(
          queue: songs,
          currentIndex: 45,
          deviceName: '长队列设备',
          onSelect: (int index) async {},
          onRemove: (int index) {},
          onReorder: (int from, int to) {},
          onClear: () async {},
        ),
      );
      expect(find.text('投屏长曲45'), findsOneWidget);

      await _pumpView(
        tester,
        CastQueueSheetView(
          queue: songs,
          currentIndex: 10,
          deviceName: '长队列设备',
          onSelect: (int index) async {},
          onRemove: (int index) {},
          onReorder: (int from, int to) {},
          onClear: () async {},
        ),
      );
      await settle(tester, frames: 8);

      expect(find.text('投屏长曲10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('PlayQueueSheetView:非空队列 currentIndex=-1 走 initState 放行分支', (
      tester,
    ) async {
      await _pumpView(
        tester,
        PlayQueueSheetView(
          playerState: PlayerState(queue: kSongs, currentIndex: -1),
          panel: true,
          onSelect: (int index) async {},
          onClear: () async {},
          onOpenSongActions: (
            BuildContext context,
            int index,
            Song song,
          ) async {},
        ),
      );

      expect(find.text('本机曲一'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 视图级 pump（复用 b32c 风格）：ProviderScope + MaterialApp + 有界推帧。
Future<void> _pumpView(WidgetTester tester, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.dark(),
        builder: (BuildContext context, Widget? child) {
          _loc = AppLocalizations.of(context);
          return child!;
        },
        home: Scaffold(body: child),
      ),
    ),
  );
  await settle(tester);
}
