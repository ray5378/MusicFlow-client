// batch32 B 路 —— `lib/features/library/widgets/artist_options_sheet.dart` 补测。
//
// 基线覆盖率 ~0%。沿用 batch31 C 路 SheetHarness 套路：
//   * 私有 sheet 走 showArtistOptionsSheet 入口（需要 context + ref，探针都递出）；
//   * compact 宽度 520 → showModalBottomSheet，settle()/drain() 有界推帧；
//   * NetworkErrorNotifier 20s 节流，失败分支只断言确定性副作用；
//   * 成功 toast 需 MaterialApp(navigatorKey: rootNavigatorKey)；
//   * TestPlayerNotifier 的 noSuchMethod 会吞掉调用记录 → 显式 override。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/widgets/artist_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
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

final Artist kArtist = Artist(
  id: 'ar1',
  name: '测试歌手',
  albumCount: 3,
);

final List<Song> kSongs = <Song>[
  Song(id: 's1', title: '热门一', artist: '测试歌手', albumId: 'al1'),
  Song(id: 's2', title: '热门二', artist: '测试歌手', albumId: 'al1'),
];

/// 音乐仓库桩：只实现 getTopSongs / setArtistStarred。
class FakeMusicRepository extends MusicRepository {
  FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));

  List<Song> topSongs = kSongs;
  Object? getTopSongsError;
  Object? setStarredError;
  int getTopSongsCalls = 0;
  final List<String> starredArtistIds = <String>[];
  final List<bool> starredValues = <bool>[];

  @override
  Future<List<Song>> getTopSongs(String artistName, {int? count}) async {
    getTopSongsCalls += 1;
    if (getTopSongsError != null) throw getTopSongsError!;
    return topSongs;
  }

  @override
  Future<void> setArtistStarred(String artistId, bool starred) async {
    starredArtistIds.add(artistId);
    starredValues.add(starred);
    if (setStarredError != null) throw setStarredError!;
  }
}

/// 播放器桩：显式记录 playQueue / addAllToQueue。
class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<int> playQueueStartIndices = <int>[];
  final List<List<String>> addAllToQueueCalls = <List<String>>[];

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

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref);
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
}

/// 把树里的 WidgetRef / BuildContext 递出来给 showArtistOptionsSheet。
class _RefProbe extends ConsumerWidget {
  const _RefProbe({required this.onReady});

  final void Function(WidgetRef ref, BuildContext context) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(ref, context);
    return const SizedBox.shrink();
  }
}

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// _closeAndRun 是 microtask + 内部 await 链，多轮 pump 推进。
Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

class SheetHarness {
  SheetHarness({
    this.artist,
    this.repository,
    this.addressError,
  }) : player = RecordingPlayer();

  final Artist? artist;
  final FakeMusicRepository? repository;
  final Object? addressError;

  final RecordingPlayer player;

  ProviderContainer? container;
  AppLocalizations? loc;
  WidgetRef? hostRef;
  BuildContext? hostContext;

  Widget build() {
    final container = ProviderContainer(
      overrides: <Override>[
        musicRepositoryProvider.overrideWith((Ref ref) => repository),
        ensureActiveAddressProvider.overrideWith((Ref ref) async {
          if (addressError != null) throw addressError!;
          return kAddress;
        }),
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
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    await settle(tester, frames: 4);
  }

  Future<void> open(WidgetTester tester) async {
    unawaited(
      showArtistOptionsSheet(
        context: hostContext!,
        ref: hostRef!,
        artist: artist ?? kArtist,
      ),
    );
    await settle(tester, frames: 14);
  }
}

Finder actionRow(String title) =>
    find.widgetWithText(MusicFlowActionRow, title);

void main() {
  group('artist_options_sheet · 装配', () {
    testWidgets('三个操作行 + 标题/专辑数副标题渲染出来', (WidgetTester tester) async {
      final h = SheetHarness(repository: FakeMusicRepository());
      await h.pump(tester);
      await h.open(tester);

      expect(find.text('测试歌手'), findsWidgets, reason: '标题取 artist.name');
      expect(
        find.text(h.loc!.library_album_count('3')),
        findsWidgets,
        reason: 'albumCount 非空 -> 副标题显示专辑数',
      );
      expect(actionRow(h.loc!.library_play_artist_top), findsOneWidget);
      expect(actionRow(h.loc!.library_favorite_artist), findsOneWidget);
      expect(actionRow(h.loc!.library_add_to_queue), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('albumCount 为 null -> 无副标题', (WidgetTester tester) async {
      final h = SheetHarness(
        artist: Artist(id: 'ar2', name: '无名歌手'),
        repository: FakeMusicRepository(),
      );
      await h.pump(tester);
      await h.open(tester);

      expect(find.text('无名歌手'), findsWidgets);
      expect(find.textContaining(h.loc!.library_album_count('1')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已收藏歌手 -> 行文案是取消收藏且 selected 置位', (
      WidgetTester tester,
    ) async {
      final h = SheetHarness(
        artist: Artist(id: 'ar3', name: '已收藏歌手', starred: true),
        repository: FakeMusicRepository(),
      );
      await h.pump(tester);
      await h.open(tester);

      final row = actionRow(h.loc!.library_unfavorited_artist);
      expect(row, findsOneWidget);
      expect(tester.widget<MusicFlowActionRow>(row).selected, isTrue);
      expect(actionRow(h.loc!.library_favorite_artist), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('artist_options_sheet · 播放热门歌曲', () {
    testWidgets('点播放热门 -> 整队起播 + 来源标记 artist', (
      WidgetTester tester,
    ) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_artist_top));
      await drain(tester);

      expect(repo.getTopSongsCalls, 1);
      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s1', 's2'],
      ]);
      expect(h.player.playQueueStartIndices, <int>[0]);
      expect(h.hostRef!.read(queueOriginProvider), isNotNull);
      expect(h.hostRef!.read(queueOriginProvider)!.kind.name, 'artist');
      expect(h.hostRef!.read(queueOriginProvider)!.id, 'ar1');
      expect(find.byType(MusicFlowBottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库为 null -> 不读热门也不起播', (WidgetTester tester) async {
      final h = SheetHarness(repository: null);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_artist_top));
      await drain(tester);

      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('活跃地址获取失败 -> 不调 getTopSongs 也不起播', (
      WidgetTester tester,
    ) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(
        repository: repo,
        addressError: StateError('no address'),
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_artist_top));
      await drain(tester);

      expect(repo.getTopSongsCalls, 0, reason: 'ensureActiveAddress 先抛');
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('getTopSongs 抛异常 -> 走 catch 分支且不起播', (
      WidgetTester tester,
    ) async {
      final repo = FakeMusicRepository()
        ..getTopSongsError = StateError('top boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_artist_top));
      await drain(tester);

      expect(repo.getTopSongsCalls, 1);
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('热门歌曲为空 -> 不起播', (WidgetTester tester) async {
      final repo = FakeMusicRepository()..topSongs = const <Song>[];
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_play_artist_top));
      await drain(tester);

      expect(repo.getTopSongsCalls, 1);
      expect(h.player.playQueueCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('artist_options_sheet · 收藏切换', () {
    testWidgets('未收藏 -> 点收藏写 true 且弹成功提示', (WidgetTester tester) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_artist));
      await drain(tester);

      expect(repo.starredArtistIds, <String>['ar1']);
      expect(repo.starredValues, <bool>[true]);
      expect(find.byType(MusicFlowMessage), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已收藏 -> 点取消收藏写 false', (WidgetTester tester) async {
      final repo = FakeMusicRepository();
      final h = SheetHarness(
        artist: Artist(id: 'ar3', name: '已收藏歌手', starred: true),
        repository: repo,
      );
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_unfavorited_artist));
      await drain(tester);

      expect(repo.starredArtistIds, <String>['ar3']);
      expect(repo.starredValues, <bool>[false]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setArtistStarred 抛异常 -> 请求发起过且无成功提示', (
      WidgetTester tester,
    ) async {
      final repo = FakeMusicRepository()
        ..setStarredError = StateError('star boom');
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_artist));
      await drain(tester);

      expect(repo.starredValues, <bool>[true]);
      expect(find.byType(MusicFlowMessage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库为 null -> 收藏请求不发起', (WidgetTester tester) async {
      final h = SheetHarness(repository: null);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_favorite_artist));
      await drain(tester);

      expect(find.byType(MusicFlowMessage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('artist_options_sheet · 加入队列', () {
    testWidgets('点加入队列 -> 入队全部热门并弹成功提示', (WidgetTester tester) async {
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

    testWidgets('热门歌曲为空 -> 不入队', (WidgetTester tester) async {
      final repo = FakeMusicRepository()..topSongs = const <Song>[];
      final h = SheetHarness(repository: repo);
      await h.pump(tester);
      await h.open(tester);

      await tester.tap(actionRow(h.loc!.library_add_to_queue));
      await drain(tester);

      expect(h.player.addAllToQueueCalls, isEmpty);
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
}
