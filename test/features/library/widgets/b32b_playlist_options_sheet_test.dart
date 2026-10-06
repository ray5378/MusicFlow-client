// batch32 B 路 —— `lib/features/library/widgets/playlist_options_sheet.dart` 补测。
//
// 基线覆盖率 ~0%（私有 sheet 类从未在测试里装配过）。沿用 batch31 C 路的
// SheetHarness 套路（踩坑记录同 b31c_album_options_sheet_test.dart）：
//   #C1 私有 sheet 只能走 showPlaylistOptionsSheet 入口，unawaited 发起；
//   #C2 探针 ConsumerWidget 把 context 递出来；
//   #C3 compact 宽度 520 走 showModalBottomSheet，统一有界 settle() 推帧；
//   #C4 _closeAndRun 先 pop 再 Future.delayed(Duration.zero)，多轮 pump 推进；
//   #C5 NetworkErrorNotifier 20s 节流，失败分支只断言确定性副作用；
//   #C6 成功 toast 需 MaterialApp(navigatorKey: rootNavigatorKey)。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/widgets/playlist_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

import '../../player/test_player_notifier.dart';

const Size kSheetView = Size(520, 1000);

final ServerAddress kAddress = ServerAddress(
  id: 'addr1',
  libraryId: 'lib1',
  label: 'Home',
  url: 'http://127.0.0.1:4533',
  priority: 0,
);

final Playlist kPlaylist = Playlist(
  id: 'p1',
  name: '测试歌单',
  songCount: 3,
  duration: 125,
);

final Playlist kFavoritePlaylist = Playlist(
  id: 'p2',
  name: '已收藏歌单',
  songCount: 2,
  duration: 100,
  favorite: true,
);

final List<Song> kSongs = <Song>[
  Song(id: 's1', title: '曲目一', artist: 'A', albumId: 'al1'),
  Song(id: 's2', title: '曲目二', artist: 'A', albumId: 'al1'),
];

/// 歌单仓库桩：只实现本 sheet 用到的两个方法。
class FakePlaylistRepository extends PlaylistRepository {
  FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));

  List<Song> songs = kSongs;
  Object? getAllSongsError;
  bool favoriteOk = true;
  Object? setFavoriteError;
  int getAllSongsCalls = 0;
  final List<String> favoritePlaylistIds = <String>[];
  final List<bool> favoriteValues = <bool>[];

  @override
  Future<List<Song>> getAllPlaylistSongs(String playlistId) async {
    getAllSongsCalls += 1;
    if (getAllSongsError != null) throw getAllSongsError!;
    return songs;
  }

  @override
  Future<bool> setPlaylistFavorite(String playlistId, bool favorite) async {
    favoritePlaylistIds.add(playlistId);
    favoriteValues.add(favorite);
    if (setFavoriteError != null) throw setFavoriteError!;
    return favoriteOk;
  }
}

/// 播放器桩：显式实现 playQueue 记录调用（见模板 #C8）。
class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<int> playQueueStartIndices = <int>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls.add(songs.map((Song s) => s.id).toList());
    playQueueStartIndices.add(startIndex);
    state = state.copyWith(queue: songs, currentIndex: startIndex);
  }
}

/// 链路 A / B 桩：无投屏设备 → playEffectiveQueue 落到本机 playerProvider。
class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref);
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
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

/// 有界推帧：替代 pumpAndSettle（进场动画/骨架屏等不到静，见 #C3）。
Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 让 _closeAndRun 的 delayed + action 内 await 链跑完（见 #C4）。
Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

class SheetHarness {
  SheetHarness({
    this.playlist,
    this.hasSongs = true,
    this.repository,
  }) : player = RecordingPlayer();

  final Playlist? playlist;
  final bool hasSongs;
  final FakePlaylistRepository? repository;

  final RecordingPlayer player;

  ProviderContainer? container;
  AppLocalizations? loc;
  BuildContext? hostContext;
  Completer<PlaylistOptionsAction?>? lastResult;

  Widget build() {
    final container = ProviderContainer(
      overrides: <Override>[
        playlistRepositoryProvider.overrideWith((Ref ref) => repository),
        ensureActiveAddressProvider.overrideWith((Ref ref) async => kAddress),
        playerProvider.overrideWith((Ref ref) => player),
        castPeerControllerProvider.overrideWith((Ref ref) => StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
      ],
    );
    this.container = container;
    return UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(size: kSheetView, devicePixelRatio: 1),
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          builder: (BuildContext context, Widget? child) {
            loc = AppLocalizations.of(context);
            return child!;
          },
          home: Scaffold(
            body: _RefProbe(
              onReady: (BuildContext ctx) => hostContext = ctx,
            ),
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

  /// 发起歌单操作弹窗，记录关闭结果（pop 值）。
  Future<void> open(WidgetTester tester) async {
    final result = Completer<PlaylistOptionsAction?>();
    lastResult = result;
    unawaited(
      showPlaylistOptionsSheet(
        context: hostContext!,
        playlist: playlist ?? kPlaylist,
        hasSongs: hasSongs,
      ).then(result.complete),
    );
    await settle(tester, frames: 14);
  }
}

Finder actionRow(String title) =>
    find.widgetWithText(MusicFlowActionRow, title);

void main() {
  group('playlist_options_sheet · 装配', () {
    testWidgets('五个操作行 + 标题/副标题（有时长）渲染出来', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(repository: FakePlaylistRepository());
      await h.pump(tester);
      await h.open(tester);

      expect(find.text('测试歌单'), findsWidgets, reason: '标题取 playlist.name');
      expect(actionRow(h.loc!.discover_play_playlist), findsOneWidget);
      expect(actionRow(h.loc!.library_favorite_playlist), findsOneWidget);
      expect(actionRow(h.loc!.library_add_to_queue), findsOneWidget);
      expect(actionRow(h.loc!.library_edit_playlist), findsOneWidget);
      expect(actionRow(h.loc!.library_delete_playlist), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('duration=0 -> 副标题只显示歌曲数，不追加「0分」', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        playlist: Playlist(
          id: 'p3',
          name: '无时长歌单',
          songCount: 5,
          duration: 0,
        ),
        repository: FakePlaylistRepository(),
      );
      await h.pump(tester);
      await h.open(tester);

      expect(find.text(h.loc!.discover_track_count('5')), findsWidgets,
          reason: 'duration=0 走纯歌曲数副标题');
      expect(
        find.textContaining(h.loc!.duration_minutes(0)),
        findsNothing,
        reason: '不得出现 0 分时长',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('已收藏歌单 -> 行文案是取消收藏且 selected 置位', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        playlist: kFavoritePlaylist,
        repository: FakePlaylistRepository(),
      );
      await h.pump(tester);
      await h.open(tester);

      final row = actionRow(h.loc!.library_unfavorite_playlist);
      expect(row, findsOneWidget);
      expect(tester.widget<MusicFlowActionRow>(row).selected, isTrue);
      expect(actionRow(h.loc!.library_favorite_playlist), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hasSongs=false -> 播放/加入队列入队行禁用，编辑/删除仍可用', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        playlist: kPlaylist,
        hasSongs: false,
        repository: FakePlaylistRepository(),
      );
      await h.pump(tester);
      await h.open(tester);

      final playRow =
          tester.widget<MusicFlowActionRow>(actionRow(h.loc!.discover_play_playlist));
      expect(playRow.onPressed, isNull, reason: '无歌曲时播放行禁用');
      final queueRow = tester.widget<MusicFlowActionRow>(
          actionRow(h.loc!.library_add_to_queue));
      expect(queueRow.onPressed, isNull, reason: '无歌曲时加入队列行禁用');
      final editRow = tester.widget<MusicFlowActionRow>(
          actionRow(h.loc!.library_edit_playlist));
      expect(editRow.onPressed, isNotNull, reason: '编辑行不受 hasSongs 影响');
      final deleteRow = tester.widget<MusicFlowActionRow>(
          actionRow(h.loc!.library_delete_playlist));
      expect(deleteRow.onPressed, isNotNull);
      expect(
        find.text(h.loc!.library_playlist_no_songs),
        findsWidgets,
        reason: '禁用行带「歌单暂无歌曲」副标题',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('playlist_options_sheet · 播放歌单', () {
    testWidgets('点播放 -> 关弹窗 + 整队起播 + 来源标记 playlist', (
      WidgetTester tester,
    ) async {
      final repo = FakePlaylistRepository();
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.discover_play_playlist));
      await drain(tester);

      expect(repo.getAllSongsCalls, 1);
      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s1', 's2'],
      ]);
      expect(h.player.playQueueStartIndices, <int>[0]);
      expect(h.container!.read(queueOriginProvider), isNotNull);
      expect(h.container!.read(queueOriginProvider)!.kind.name, 'playlist');
      expect(h.container!.read(queueOriginProvider)!.id, 'p1');
      expect(
        find.byType(MusicFlowBottomSheet),
        findsNothing,
        reason: '_closeAndRun 先 pop 再跑动作',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库为 null（无活跃库）-> 不读仓库也不起播', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(repository: null);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.discover_play_playlist));
      await drain(tester);

      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('getAllPlaylistSongs 抛异常 -> 走 catch 分支且不起播', (
      WidgetTester tester,
    ) async {
      final repo = FakePlaylistRepository()
        ..getAllSongsError = StateError('songs boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.discover_play_playlist));
      await drain(tester);

      expect(repo.getAllSongsCalls, 1);
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌曲列表为空 -> 不起播', (WidgetTester tester) async {
      final repo = FakePlaylistRepository()..songs = const <Song>[];
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.discover_play_playlist));
      await drain(tester);

      expect(repo.getAllSongsCalls, 1);
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('playlist_options_sheet · 收藏切换', () {
    testWidgets('未收藏 -> 点收藏写 true 且弹成功提示', (WidgetTester tester) async {
      final repo = FakePlaylistRepository();
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_playlist));
      await drain(tester);

      expect(repo.favoritePlaylistIds, <String>['p1']);
      expect(repo.favoriteValues, <bool>[true]);
      expect(
        find.byType(MusicFlowMessage),
        findsWidgets,
        reason: '成功后 ToastNotifier.show(kind: success)',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('已收藏 -> 点取消收藏写 false', (WidgetTester tester) async {
      final repo = FakePlaylistRepository();
      final h = SheetHarness(
        playlist: kFavoritePlaylist,
        repository: repo,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_unfavorite_playlist));
      await drain(tester);

      expect(repo.favoritePlaylistIds, <String>['p2']);
      expect(repo.favoriteValues, <bool>[false]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setPlaylistFavorite 返回 false -> 不弹成功提示', (
      WidgetTester tester,
    ) async {
      final repo = FakePlaylistRepository()..favoriteOk = false;
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_playlist));
      await drain(tester);

      expect(repo.favoriteValues, <bool>[true]);
      expect(find.byType(MusicFlowMessage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setPlaylistFavorite 抛异常 -> 不崩也不弹成功提示', (
      WidgetTester tester,
    ) async {
      final repo = FakePlaylistRepository()
        ..setFavoriteError = StateError('fav boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_playlist));
      await drain(tester);

      // #C5：失败提示走 NetworkErrorNotifier（20s 节流），只断言请求发起过。
      expect(repo.favoriteValues, <bool>[true]);
      expect(find.byType(MusicFlowMessage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库为 null -> 收藏请求不发起', (WidgetTester tester) async {
      final h = SheetHarness(repository: null);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_playlist));
      await drain(tester);

      expect(find.byType(MusicFlowMessage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('playlist_options_sheet · 弹窗返回值', () {
    testWidgets('加入队列 -> pop(PlaylistOptionsAction.addToQueue)', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(repository: FakePlaylistRepository());
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_queue));
      await drain(tester);

      expect(await h.lastResult!.future, PlaylistOptionsAction.addToQueue);
      expect(find.byType(MusicFlowBottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑 -> pop(PlaylistOptionsAction.edit)', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(repository: FakePlaylistRepository());
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_edit_playlist));
      await drain(tester);

      expect(await h.lastResult!.future, PlaylistOptionsAction.edit);
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除 -> pop(PlaylistOptionsAction.delete)', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(repository: FakePlaylistRepository());
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_delete_playlist));
      await drain(tester);

      expect(await h.lastResult!.future, PlaylistOptionsAction.delete);
      expect(tester.takeException(), isNull);
    });

    testWidgets('播放行直接执行不携带返回值 -> future 完成为 null', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(repository: FakePlaylistRepository());
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.discover_play_playlist));
      await drain(tester);

      expect(await h.lastResult!.future, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
