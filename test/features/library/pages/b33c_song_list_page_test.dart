// batch33 C 路 —— `lib/features/library/pages/song_list_page.dart` 补测。
//
// 基线覆盖率 38.02%。页面依赖：
//   * `musicRepositoryProvider` → FakeMusicRepository（getSongsPage /
//     getAllSongs 记录调用，可注入错误）；
//   * `libraryCountsProvider` → 固定 LibraryCounts（顶栏计数副标题）；
//   * `playerProvider` → RecordingPlayer（playEffectiveQueue 本机路径走
//     notifier.playQueue）；
//   * `castPeerControllerProvider` / `dlnaCastProvider` → 无投屏桩；
//   * `searchRepositoryProvider` → null（聚合搜索全网块短路返回空，
//     只测本地块）。
// 交互：点行（全量队列起播 / getAllSongs 失败退化单曲）、搜索（EntitySearchBar
// 有 450ms 防抖，用 pump 推时钟）、排序弹窗（sort 参数变化）。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_icon_button.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_stats_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

const Size kView = Size(520, 1200);

final ServerAddress kAddress = ServerAddress(
  id: 'addr1',
  libraryId: 'lib1',
  label: 'Home',
  url: 'http://127.0.0.1:4533',
  priority: 0,
);

final List<Song> kSongs = <Song>[
  Song(id: 's1', title: '曲目一', artist: '艺术家甲', albumId: 'al1'),
  Song(id: 's2', title: '曲目二', artist: '艺术家乙', albumId: 'al1'),
  Song(id: 's3', title: '曲目三', artist: '艺术家丙', albumId: 'al2'),
];

/// 音乐仓库桩：只实现页面用到的 getSongsPage / getAllSongs。
class FakeMusicRepository extends MusicRepository {
  FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));

  List<Song> pageSongs = kSongs;
  int total = kSongs.length;
  String lastSort = '';
  final List<String> queries = <String>[];
  Object? pageError;
  Object? allSongsError;
  int getAllSongsCalls = 0;

  @override
  Future<({List<Song> items, int total})> getSongsPage(
    int page,
    int pageSize, {
    String query = '',
    String sort = '',
  }) async {
    lastSort = sort;
    queries.add(query);
    if (pageError != null) throw pageError!;
    return (items: pageSongs, total: total);
  }

  @override
  Future<List<Song>> getAllSongs({String query = ''}) async {
    getAllSongsCalls += 1;
    if (allSongsError != null) throw allSongsError!;
    return pageSongs;
  }
}

class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];
  final List<int> startIndices = <int>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls.add(songs.map((Song s) => s.id).toList());
    startIndices.add(startIndex);
    state = state.copyWith(
      queue: songs,
      currentIndex: startIndex,
      currentSong: songs.isEmpty
          ? null
          : songs[startIndex.clamp(0, songs.length - 1)],
    );
  }
}

class StubCastPeer extends CastPeerController {
  StubCastPeer(super.ref);
}

class StubDlnaCast extends DlnaCastNotifier {
  StubDlnaCast(super.ref);
}

class _PageHarness {
  _PageHarness({this.repository, List<Song>? songs}) // ignore: unused_element_parameter
      : player = RecordingPlayer() {
    if (repository == null) {
      repo = FakeMusicRepository()..pageSongs = songs ?? kSongs;
    } else {
      repo = repository!;
    }
  }

  FakeMusicRepository? repository;
  late FakeMusicRepository repo;
  final RecordingPlayer player;

  ProviderContainer? container;
  AppLocalizations? loc;

  Widget build() {
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          musicRepositoryProvider.overrideWith((Ref ref) => repo),
          libraryCountsProvider.overrideWith(
            (Ref ref) async => const LibraryCounts(songCount: 3),
          ),
          playerProvider.overrideWith((Ref ref) => player),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => StubCastPeer(ref),
          ),
          dlnaCastProvider.overrideWith((Ref ref) => StubDlnaCast(ref)),
          searchRepositoryProvider.overrideWith((Ref ref) => null),
        ],
      ),
      child: MediaQuery(
        data: const MediaQueryData(size: kView, devicePixelRatio: 1),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(body: SongListPage()),
        ),
      ),
    );
  }

  Future<void> pump(WidgetTester tester, {int frames = 10}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = kView;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => container?.dispose());
    await tester.pumpWidget(build());
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    loc = AppLocalizations.of(tester.element(find.byType(SongListPage)));
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  /// 进入搜索模式：输入关键词并推过 450ms 防抖。
  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 500));
    await drain(tester);
  }
}

void main() {
  group('song_list_page · 列表装配', () {
    testWidgets('有数据 → 渲染歌曲行 + 顶栏计数副标题', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);

      expect(find.text('曲目一'), findsOneWidget);
      expect(find.text('曲目二'), findsOneWidget);
      expect(find.text('曲目三'), findsOneWidget);
      expect(find.textContaining('3'), findsWidgets,
          reason: 'libraryCountsProvider 的 songsLabel 进顶栏副标题');
      expect(tester.takeException(), isNull);
    });

    testWidgets('空库 → 空态文案', (WidgetTester tester) async {
      final h = _PageHarness();
      h.repo.pageSongs = const <Song>[];
      h.repo.total = 0;
      await h.pump(tester);

      expect(find.text(h.loc!.library_empty_songs), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库分页抛错 → 列表错误可经重试作用域兜底不崩', (WidgetTester tester) async {
      final h = _PageHarness();
      h.repo.pageError = StateError('page boom');
      await h.pump(tester);

      expect(find.text('曲目一'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('song_list_page · 点行起播', () {
    testWidgets('点第 2 行 → 拉全量构建队列从 index 1 起播', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);

      await tester.tap(find.text('曲目二'));
      await h.drain(tester);

      expect(h.repo.getAllSongsCalls, 1, reason: '队列需要完整顺序表');
      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s1', 's2', 's3'],
      ]);
      expect(h.player.startIndices, <int>[1]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('getAllSongs 抛错 → 退化为点击单曲起播', (WidgetTester tester) async {
      final h = _PageHarness();
      h.repo.allSongsError = StateError('all boom');
      await h.pump(tester);

      await tester.tap(find.text('曲目三'));
      await h.drain(tester);

      expect(h.repo.getAllSongsCalls, 1);
      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s3'],
      ]);
      expect(h.player.startIndices, <int>[0]);
      expect(tester.takeException(), isNull);
    });
  });

  group('song_list_page · 搜索模式', () {
    testWidgets('输入关键词 → 本地搜索块渲染匹配行', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);

      await h.search(tester, '曲目');
      await h.drain(tester);

      expect(h.repo.queries, contains('曲目'));
      expect(find.text('曲目一'), findsOneWidget);
      expect(find.text('曲目三'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索结果点行 → 以本地搜索结果为队列起播', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);

      await h.search(tester, '曲目');
      await h.drain(tester);
      await tester.tap(find.text('曲目三'));
      await h.drain(tester);

      expect(h.player.playQueueCalls, <List<String>>[
        <String>['s1', 's2', 's3'],
      ]);
      expect(h.player.startIndices, <int>[2], reason: '点哪首播哪首');
      expect(tester.takeException(), isNull);
    });

    testWidgets('清空搜索词 → 回到完整列表', (WidgetTester tester) async {
      final h = _PageHarness();
      await h.pump(tester);
      await h.search(tester, '曲目');
      await h.drain(tester);

      await h.search(tester, '');
      await h.drain(tester);

      expect(find.text(h.loc!.library_empty_songs), findsNothing);
      expect(find.text('曲目一'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('song_list_page · 排序', () {
    testWidgets('排序弹窗选最近入库 → fetcher 携带 sort=recentAdded 重载', (
      WidgetTester tester,
    ) async {
      final h = _PageHarness();
      await h.pump(tester);
      expect(h.repo.lastSort, '', reason: '默认标题升序，sort 为空串');

      await tester.tap(find.byWidgetPredicate(
        (Widget w) =>
            w is MusicFlowIconButton && w.label == h.loc!.library_song_sort,
      ));
      await h.drain(tester);

      await tester.tap(find.text(h.loc!.song_sort_recent_added));
      await h.drain(tester);

      expect(h.repo.lastSort, 'recentAdded');
      expect(tester.takeException(), isNull);
    });
  });
}
