// batch31 C 路 —— `lib/features/library/widgets/album_options_sheet.dart` 补测。
//
// 这个文件基线覆盖率 0.7%（145 行 DA 只有 1 行命中：309 行那个 const 构造），
// 等于**从来没有在测试里被装配过**。两类入口：
//   * `showAlbumOptionsSheet(...)` —— 唯一的公开入口（两个 sheet 类都是私有 `_`）；
//   * `_AlbumOptionsSheet` / `_AddAlbumToPlaylistSheet` 只能经由入口打开。
//
// 踩坑记录（C 路）：
// #C1 `_AlbumOptionsSheet` / `_AddAlbumToPlaylistSheet` 都是**库私有**，测试文件
//     在另一个库里拿不到类型 ⇒ 只能走 `showAlbumOptionsSheet`，用 `unawaited`
//     发起（它的 Future 只在 sheet 被 pop 时才完成，await 会挂死用例）。
// #C2 `showAlbumOptionsSheet` 需要 `WidgetRef` —— 树上先挂一个 `ConsumerWidget`
//     探针把 `ref` / `context` 递出来，再用这两个句柄发起弹窗。
// #C3 `showMusicFlowBottomSheet` 的分流看 `context.musicFlowWindowClass`：
//     宽 520 < 600 ⇒ compact ⇒ 走 `showModalBottomSheet`（带进场动画）；
//     骨架屏 `MusicFlowSkeleton` 是无限动画，`pumpAndSettle` 永远等不到静，
//     统一用有界 `settle()` 推帧。
// #C4 `_closeAndRun` 是「先 pop 再 `Future.microtask` 跑动作」⇒ 动作里的
//     `await`（ensureActiveAddress / repository.getAlbum）要靠多轮 pump 推进，
//     一次 `pump()` 不够。
// #C5 `NetworkErrorNotifier` 有 20s 节流（`_lastShownAt` 是静态量，跨用例残留），
//     失败分支的「有没有弹错误提示」**不可断言**；失败用例一律改为断言
//     「仓库被按预期调用过」这类确定性副作用。
// #C6 成功 toast 走 `ToastNotifier.show` → `rootNavigatorKey.currentState.overlay`，
//     所以测试树必须 `MaterialApp(navigatorKey: rootNavigatorKey)`，否则只写进
//     静态 `_pendingMessage`，树上找不到 `MusicFlowMessage`。
// #C7 `MusicRepository` / `PlaylistRepository` 都是**具体类**（构造只收一个
//     `SubsonicApiClient`），没有接口；假仓库用 `extends` + `super(SubsonicApiClient(dio: Dio()))`
//     造，既不碰网络也能只 override 需要的两个方法。
// #C8 `TestPlayerNotifier` 有 `noSuchMethod => null`，`playQueue` / `addAllToQueue`
//     不显式 override 会**静默返回 null**（调用记录落不下来），必须子类显式实现。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/widgets/album_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
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

final Album kAlbum = Album(
  id: 'al1',
  name: '测试专辑',
  artist: '测试艺术家',
  artistId: 'ar1',
  songCount: 2,
  duration: 120,
);

final List<Song> kSongs = <Song>[
  Song(id: 's1', title: '曲目一', artist: '测试艺术家', albumId: 'al1'),
  Song(id: 's2', title: '曲目二', artist: '测试艺术家', albumId: 'al1'),
];

final List<Playlist> kPlaylists = <Playlist>[
  Playlist(id: 'p1', name: '歌单一', songCount: 3, duration: 100),
  Playlist(id: 'p2', name: '歌单二', songCount: 7, duration: 200),
];

/// 音乐仓库桩：只实现本 sheet 用到的 `getAlbum` / `setAlbumStarred`。
class FakeMusicRepository extends MusicRepository {
  FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));

  AlbumDetail? detail = AlbumDetail(album: kAlbum, songs: kSongs);
  Object? getAlbumError;
  Object? setStarredError;
  int getAlbumCalls = 0;
  final List<bool> starredValues = <bool>[];

  @override
  Future<AlbumDetail?> getAlbum(String albumId) async {
    getAlbumCalls += 1;
    if (getAlbumError != null) throw getAlbumError!;
    return detail;
  }

  @override
  Future<void> setAlbumStarred(String albumId, bool starred) async {
    starredValues.add(starred);
    if (setStarredError != null) throw setStarredError!;
  }
}

/// 歌单仓库桩：只实现 `updatePlaylist`。
class FakePlaylistRepository extends PlaylistRepository {
  FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));

  Object? updateError;
  final List<String> addedPlaylistIds = <String>[];
  final List<List<String>> addedSongIds = <List<String>>[];

  @override
  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    bool? public,
    List<String>? songIdsToAdd,
    List<int>? songIndexesToRemove,
  }) async {
    addedPlaylistIds.add(playlistId);
    addedSongIds.add(songIdsToAdd ?? const <String>[]);
    if (updateError != null) throw updateError!;
  }
}

/// 播放器桩：`TestPlayerNotifier` 的 `noSuchMethod` 会让 `playQueue` /
/// `addAllToQueue` 静默返回 null（见 #C8），这里显式实现来记录调用。
class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<List<String>> addAllToQueueCalls = <List<String>>[];
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

  @override
  void addAllToQueue(List<Song> songs) {
    addAllToQueueCalls.add(songs.map((Song s) => s.id).toList());
    state = state.copyWith(queue: <Song>[...state.queue, ...songs]);
  }
}

/// 链路 A / B 两个 notifier 桩：只保留默认态（无投屏设备），让
/// `playEffectiveQueue` 直接落到本机 `playerProvider`。
class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref);
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
}

/// 把树里的 WidgetRef / BuildContext 递出来给 `showAlbumOptionsSheet`（见 #C2）。
class _RefProbe extends ConsumerWidget {
  const _RefProbe({required this.onReady});

  final void Function(WidgetRef ref, BuildContext context) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(ref, context);
    return const SizedBox.shrink();
  }
}

/// 有界推帧：替代 `pumpAndSettle`（骨架屏/抽屉动画永远等不到静，见 #C3）。
Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 让 `_closeAndRun` 的 microtask + 内部 await 链跑完（见 #C4）。
///
/// 注意：用 `tester.pump(duration)` 推帧来驱动 flutter_test 的 FakeAsync 时钟
/// 与 microtask/timer 队列；**绝不能**用 `Future.delayed(Duration.zero)` —— 在
/// FakeAsync zone 下没有 pump 推进时钟，该 timer 永不触发，会导致用例「did not
/// complete」挂死（本 C 路最初「播放专辑」用例挂死的根因）。
Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// 本文件全部用例的仿真台。
class SheetHarness {
  SheetHarness({
    Album? album,
    this.repository,
    this.playlistRepository,
    this.addressError,
    this.playlists,
    this.playlistsError,
    this.playlistsPending = false,
    this.playlistsLoadFailed = false,
  }) : player = RecordingPlayer() {
    this.album = album ?? kAlbum;
  }

  late final Album album;
  final FakeMusicRepository? repository;
  final FakePlaylistRepository? playlistRepository;
  final Object? addressError;
  final List<Playlist>? playlists;
  final Object? playlistsError;
  final bool playlistsPending;
  final bool playlistsLoadFailed;

  final RecordingPlayer player;
  final Completer<List<Playlist>> pending = Completer<List<Playlist>>();

  ProviderContainer? _container;
  AppLocalizations? loc;
  WidgetRef? hostRef;
  BuildContext? hostContext;

  Widget build() {
    final container = ProviderContainer(
      overrides: <Override>[
        musicRepositoryProvider.overrideWith((Ref ref) => repository),
        playlistRepositoryProvider.overrideWith(
          (Ref ref) => playlistRepository,
        ),
        ensureActiveAddressProvider.overrideWith((Ref ref) async {
          if (addressError != null) throw addressError!;
          return kAddress;
        }),
        playlistsProvider.overrideWith((Ref ref) async {
          if (playlistsPending) return pending.future;
          if (playlistsError != null) throw playlistsError!;
          return playlists ?? kPlaylists;
        }),
        playlistsLoadFailedProvider.overrideWith(
          (Ref ref) => playlistsLoadFailed,
        ),
        playerProvider.overrideWith((Ref ref) => player),
        castPeerControllerProvider.overrideWith((Ref ref) => StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
      ],
    );
    _container = container;
    return UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(size: kSheetView, devicePixelRatio: 1),
        child: MaterialApp(
          // #C6：成功 toast 要塞进根导航器的 overlay 才能被断言到。
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
              onReady: (WidgetRef ref, BuildContext ctx) {
                hostRef = ref;
                hostContext = ctx;
              },
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
    addTearDown(() => _container?.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: 4);
  }

  /// 发起专辑操作弹窗（见 #C1）。
  Future<void> open(WidgetTester tester) async {
    unawaited(
      showAlbumOptionsSheet(
        context: hostContext!,
        ref: hostRef!,
        album: album,
      ),
    );
    await settle(tester, frames: 14);
  }
}

Finder actionRow(String title) =>
    find.widgetWithText(MusicFlowActionRow, title);

void main() {
  group('album_options_sheet · 一级弹窗装配', () {
    testWidgets('四个操作行 + 标题/副标题都渲染出来', (WidgetTester tester) async {
      final h = SheetHarness(repository: FakeMusicRepository());
      await h.pump(tester);
      await h.open(tester);

      expect(find.text('测试专辑'), findsWidgets, reason: '标题取 album.name');
      expect(find.text('测试艺术家'), findsWidgets, reason: '副标题取 album.artist');
      expect(actionRow(h.loc!.library_play_album), findsOneWidget);
      expect(actionRow(h.loc!.library_favorite_album), findsOneWidget);
      expect(actionRow(h.loc!.library_add_to_queue), findsOneWidget);
      expect(actionRow(h.loc!.library_add_to_playlist), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('艺术家名为空白 -> 副标题回退未知艺术家', (WidgetTester tester) async {
      final h = SheetHarness(
        album: Album(
          id: 'al2',
          name: '无名专辑',
          artist: '   ',
          songCount: 1,
          duration: 60,
        ),
        repository: FakeMusicRepository(),
      );
      await h.pump(tester);
      await h.open(tester);

      expect(find.text('无名专辑'), findsWidgets);
      expect(
        find.text(h.loc!.library_unknown_artist),
        findsWidgets,
        reason: 'artist 只有空白 -> trim 后为空 -> 走未知艺术家兜底',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('已收藏专辑 -> 行文案是取消收藏且 selected 置位', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        album: Album(
          id: 'al3',
          name: '收藏过的专辑',
          artist: 'A',
          songCount: 2,
          duration: 120,
          starred: true,
        ),
        repository: FakeMusicRepository(),
      );
      await h.pump(tester);
      await h.open(tester);

      final row = actionRow(h.loc!.library_unfavorited_album);
      expect(row, findsOneWidget);
      expect(tester.widget<MusicFlowActionRow>(row).selected, isTrue);
      expect(actionRow(h.loc!.library_favorite_album), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('album_options_sheet · 播放专辑', () {
    testWidgets('点播放专辑 -> 关弹窗 + 整队起播 + 来源标记为 album', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(repository: FakeMusicRepository());
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_album));
      await drain(tester);

      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s1', 's2'],
      ]);
      expect(h.player.playQueueStartIndices, <int>[0], reason: '整队从头起播');
      expect(
        h.hostRef!.read(queueOriginProvider),
        isNotNull,
        reason: 'playEffectiveQueue 会写入 queueOrigin',
      );
      expect(h.hostRef!.read(queueOriginProvider)!.kind.name, 'album');
      expect(h.hostRef!.read(queueOriginProvider)!.id, 'al1');
      expect(
        find.byType(MusicFlowBottomSheet),
        findsNothing,
        reason: '_closeAndRun 先 pop 再跑动作',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('songCount 为 0 -> 不读仓库也不起播', (WidgetTester tester) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(
        album: Album(id: 'al4', name: '空专辑', artist: 'A', songCount: 0, duration: 0),
        repository: repo,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_album));
      await drain(tester);

      expect(repo.getAlbumCalls, 0, reason: 'songCount<=0 直接短路返回 null');
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库为 null（无活跃库）-> 不起播', (WidgetTester tester) async {
      final h = SheetHarness(repository: null);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_album));
      await drain(tester);

      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('getAlbum 抛异常 -> 走 catch 分支且不起播', (
      WidgetTester tester,
    ) async {
      final repo = FakeMusicRepository()
        ..getAlbumError = StateError('album load boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_album));
      await drain(tester);

      expect(repo.getAlbumCalls, 1, reason: '异常发生在仓库调用里');
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('详情返回空曲目 -> 不起播', (WidgetTester tester) async {
      final repo = FakeMusicRepository()
        ..detail = AlbumDetail(album: kAlbum, songs: const <Song>[]);
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_album));
      await drain(tester);

      expect(repo.getAlbumCalls, 1);
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('album_options_sheet · 收藏切换', () {
    testWidgets('未收藏 -> 点收藏写 true 并弹成功提示', (WidgetTester tester) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_album));
      await drain(tester);

      expect(repo.starredValues, <bool>[true]);
      expect(
        find.byType(MusicFlowMessage),
        findsWidgets,
        reason: '成功后 ToastNotifier.show(kind: success)',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('已收藏 -> 点取消收藏写 false', (WidgetTester tester) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(
        album: Album(
          id: 'al5',
          name: '已收藏',
          artist: 'A',
          songCount: 2,
          duration: 120,
          starred: true,
        ),
        repository: repo,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_unfavorited_album));
      await drain(tester);

      expect(repo.starredValues, <bool>[false]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setAlbumStarred 抛异常 -> 仍发起过调用且不弹成功提示', (
      WidgetTester tester,
    ) async {
      final repo = FakeMusicRepository()
        ..setStarredError = StateError('star boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_album));
      await drain(tester);

      // #C5：失败提示走 NetworkErrorNotifier（有 20s 节流），这里只断言
      // 「请求确实按 !album.starred 发起过」这一确定性副作用。
      expect(repo.starredValues, <bool>[true]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('活跃地址获取失败 -> 不发起收藏请求', (WidgetTester tester) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(
        repository: repo,
        addressError: StateError('no address'),
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_album));
      await drain(tester);

      expect(
        repo.starredValues,
        isEmpty,
        reason: 'await ensureActiveAddressProvider.future 先抛 -> 进 catch',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('album_options_sheet · 加入队列', () {
    testWidgets('点加入队列 -> 入队两首并弹成功提示', (WidgetTester tester) async {
      final h = SheetHarness(repository: FakeMusicRepository());
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_queue));
      await drain(tester);

      expect(h.player.addAllToQueueCalls, <List<String>>[
        <String>['s1', 's2'],
      ]);
      expect(find.byType(MusicFlowMessage), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库为 null -> 不入队', (WidgetTester tester) async {
      final h = SheetHarness(repository: null);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_queue));
      await drain(tester);

      expect(h.player.addAllToQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('album_options_sheet · 二级「添加到歌单」弹窗', () {
    testWidgets('歌单列表渲染两行并带曲目数', (WidgetTester tester) async {
      final h = SheetHarness(repository: FakeMusicRepository());
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(actionRow('歌单一'), findsOneWidget);
      expect(actionRow('歌单二'), findsOneWidget);
      expect(find.text(h.loc!.discover_track_count('3')), findsOneWidget);
      expect(find.text(h.loc!.discover_track_count('7')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌单为空且未失败 -> 空态文案（无重试）', (WidgetTester tester) async {
      final h = SheetHarness(
        repository: FakeMusicRepository(),
        playlists: const <Playlist>[],
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(find.text(h.loc!.library_no_playlists), findsWidgets);
      expect(find.text(h.loc!.library_create_playlist_first), findsWidgets);
      expect(
        find.text(h.loc!.widgets_retry),
        findsNothing,
        reason: '未失败时 actionLabel 为 null',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌单为空且加载失败 -> 带重试的空态', (WidgetTester tester) async {
      final h = SheetHarness(
        repository: FakeMusicRepository(),
        playlists: const <Playlist>[],
        playlistsLoadFailed: true,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(find.text(h.loc!.library_playlists_unavailable), findsWidgets);
      expect(find.text(h.loc!.widgets_retry), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载中 -> 骨架屏占位', (WidgetTester tester) async {
      final h = SheetHarness(
        repository: FakeMusicRepository(),
        playlistsPending: true,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(find.byType(MusicFlowSkeleton), findsWidgets);
      expect(actionRow('歌单一'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载报错 -> 错误态 + 重试项', (WidgetTester tester) async {
      final h = SheetHarness(
        repository: FakeMusicRepository(),
        playlistsError: StateError('playlists boom'),
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(find.text(h.loc!.library_playlist_load_failed), findsWidgets);
      expect(find.text(h.loc!.library_playlist_load_failed_desc), findsWidgets);
      expect(find.text(h.loc!.widgets_retry), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点歌单 -> 带上全部曲目 id 调 updatePlaylist 并弹成功提示', (
      WidgetTester tester,
    ) async {
      final plRepo = FakePlaylistRepository();
      final h = SheetHarness(
        repository: FakeMusicRepository(),
        playlistRepository: plRepo,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      await tester.tap(actionRow('歌单二'));
      await drain(tester);

      expect(plRepo.addedPlaylistIds, <String>['p2']);
      expect(plRepo.addedSongIds, <List<String>>[
        <String>['s1', 's2'],
      ]);
      expect(find.byType(MusicFlowMessage), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌单仓库为 null -> 不调 updatePlaylist', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        repository: FakeMusicRepository(),
        playlistRepository: null,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);
      await tester.tap(actionRow('歌单一'));
      await drain(tester);

      expect(
        find.byType(MusicFlowMessage),
        findsNothing,
        reason: '无仓库直接走「未选媒体库」分支，不会有成功提示',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('updatePlaylist 抛异常 -> 不弹成功提示且不崩', (
      WidgetTester tester,
    ) async {
      final plRepo = FakePlaylistRepository()
        ..updateError = StateError('update boom');
      final h = SheetHarness(
        repository: FakeMusicRepository(),
        playlistRepository: plRepo,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);
      await tester.tap(actionRow('歌单一'));
      await drain(tester);

      expect(plRepo.addedPlaylistIds, <String>['p1'], reason: '请求确实发出过');
      expect(tester.takeException(), isNull);
    });

    testWidgets('曲目加载失败 -> 不打开二级弹窗', (WidgetTester tester) async {
      final repo = FakeMusicRepository()
        ..getAlbumError = StateError('album boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_playlist));
      await settle(tester, frames: 16);
      await drain(tester);

      expect(
        find.byType(MusicFlowBottomSheet),
        findsNothing,
        reason: 'songs 为 null -> 直接 return，不再 show 二级 sheet',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
