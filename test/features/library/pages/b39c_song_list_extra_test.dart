// b39c —— Route C 补测：`lib/features/library/pages/song_list_page.dart` 剩余缺口。
//
// 覆盖点（均已由既有 b33c 覆盖「成功路径」，这里补异常/退化分支）：
//   * 237：搜索模式下点行时仓库为 null → 退化为单曲起播。
//   * 249：本地搜索结果为空 → 退化为单曲起播。
//   * 255/256：拉搜索结果抛错 → catch 内退化单曲起播。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
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

final List<Song> kSongs = <Song>[
  Song(id: 's1', title: '曲目一', artist: '艺术家甲', albumId: 'al1'),
  Song(id: 's2', title: '曲目二', artist: '艺术家乙', albumId: 'al1'),
  Song(id: 's3', title: '曲目三', artist: '艺术家丙', albumId: 'al2'),
];

enum B39PageMode { items, empty, throwing }

class _RepoHolder {
  MusicRepository? value;
}

/// 可控的搜索分页行为：本地块先渲染（items），随后按需切成 empty / throwing。
class B39Repo extends MusicRepository {
  B39Repo() : super(SubsonicApiClient(dio: Dio()));

  B39PageMode mode = B39PageMode.items;

  @override
  Future<({List<Song> items, int total})> getSongsPage(
    int page,
    int pageSize, {
    String query = '',
    String sort = '',
  }) async {
    if (query.isEmpty) {
      return (items: kSongs, total: kSongs.length);
    }
    switch (mode) {
      case B39PageMode.items:
        return (items: kSongs, total: kSongs.length);
      case B39PageMode.empty:
        return (items: const <Song>[], total: 0);
      case B39PageMode.throwing:
        throw StateError('search boom');
    }
  }

  @override
  Future<List<Song>> getAllSongs({String query = ''}) async => kSongs;
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

class _Harness {
  final _RepoHolder holder = _RepoHolder()..value = B39Repo();
  final RecordingPlayer player = RecordingPlayer();
  ProviderContainer? container;
  AppLocalizations? loc;

  B39Repo get repo => holder.value! as B39Repo;

  Widget build() {
    return UncontrolledProviderScope(
      container: container = ProviderContainer(
        overrides: <Override>[
          musicRepositoryProvider.overrideWith((Ref ref) => holder.value),
          libraryCountsProvider.overrideWith(
            (Ref ref) async => const LibraryCounts(songCount: 3),
          ),
          playerProvider.overrideWith((Ref ref) => player),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => CastPeerController(ref),
          ),
          dlnaCastProvider.overrideWith((Ref ref) => DlnaCastNotifier(ref)),
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

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 500));
    await drain(tester);
  }
}

void main() {
  testWidgets('搜索点行时仓库为 null → 退化单曲起播（237）', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await h.search(tester, '曲目');
    expect(find.text('曲目三'), findsOneWidget);

    // 渲染完成后再把仓库置空（本地块因 cacheKey 未变而保留既有结果）。
    h.holder.value = null;
    h.container!.invalidate(musicRepositoryProvider);
    await h.drain(tester);

    await tester.tap(find.text('曲目三'));
    await h.drain(tester);

    expect(h.player.playQueueCalls, <List<String>>[
      <String>['s3'],
    ]);
    expect(h.player.startIndices, <int>[0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地搜索结果为空 → 退化单曲起播（249）', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await h.search(tester, '曲目');
    expect(find.text('曲目三'), findsOneWidget);

    h.repo.mode = B39PageMode.empty;
    await tester.tap(find.text('曲目三'));
    await h.drain(tester);

    expect(h.player.playQueueCalls, <List<String>>[
      <String>['s3'],
    ]);
    expect(h.player.startIndices, <int>[0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拉搜索结果抛错 → catch 内退化单曲起播（255/256）', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await h.search(tester, '曲目');
    expect(find.text('曲目三'), findsOneWidget);

    h.repo.mode = B39PageMode.throwing;
    await tester.tap(find.text('曲目三'));
    await h.drain(tester);

    expect(h.player.playQueueCalls, <List<String>>[
      <String>['s3'],
    ]);
    expect(h.player.startIndices, <int>[0]);
    expect(tester.takeException(), isNull);
  });
}
