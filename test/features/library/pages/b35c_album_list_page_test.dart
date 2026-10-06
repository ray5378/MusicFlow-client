// batch35 C 路 —— `lib/features/library/pages/album_list_page.dart` 补测
//（batch34 b34c_album_list_page_test 已覆盖：有数据网格/空态/仓库失败/点击详情/
//  长按弹窗/正在播放遮罩；本文件补剩余）：
//   * 聚合搜索分支：EntitySearchBar 输入（450ms debounce）→ AggregateSearchResults
//     渲染本地块（getAlbumsPage(1,12,query) 携带关键词）；
//   * 搜索本地结果卡播放 → _playLocalAlbum → albumDetailProvider → playQueue；
//   * 搜索详情返回 null → 不发起播放；
//   * 分页加载：total>pageSize 时视口窗口推进触发第 2 页拉取；
//   * 清空搜索恢复网格；
//   * 搜索且仓库未就绪 → 本地块空文案。
//
// 踩坑记录：
// #P1 fetcher 收到的是 1-based page（_fetchPage 传 page+1），切片按 (page-1)*pageSize。
// #P2 搜索分支依赖 searchResultsProvider（远程聚合结果），override 成空结果隔离网络。
// #P3 EntitySearchBar 有 450ms debounce Timer，输入后需 pump ≥450ms。
// #P4 [D-054] 标记的「详情拉取失败成为 unhandled async error」分支按任务要求绕开，
//     只测 detail==null 的安全路径。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remixicon/remixicon.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/library_stats_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<List<String>> playQueueCalls = <List<String>>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    playQueueCalls.add(songs.map((Song s) => s.id).toList());
    state = state.copyWith(
      queue: songs,
      currentIndex: startIndex,
      currentSong: songs.isEmpty ? null : songs[startIndex],
    );
  }
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository(this.allAlbums) : super(SubsonicApiClient(dio: Dio()));

  final List<Album> allAlbums;
  final List<String> pageCalls = <String>[]; // 'page:query'

  @override
  Future<({List<Album> items, int total})> getAlbumsPage(
    int page,
    int pageSize, {
    String? query,
  }) async {
    pageCalls.add('$page:${query ?? ''}');
    final start = (page - 1) * pageSize;
    return (
      items: allAlbums.skip(start).take(pageSize).toList(),
      total: allAlbums.length,
    );
  }
}

Album _album(String id, String name) => Album(
      id: id,
      name: name,
      artist: '歌手',
      coverArt: null,
      songCount: 5,
      duration: 600,
    );

late AppLocalizations loc;

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _build({
  required WidgetTester tester,
  _FakeMusicRepository? musicRepository,
  _RecordingPlayer? player,
  AlbumDetail? Function(String albumId)? albumDetail,
}) {
  final library = MusicLibrary(
    id: 'lib-1',
    name: '测试库',
    createdAt: DateTime(2026, 10, 1),
    updatedAt: DateTime(2026, 10, 1),
  );
  final client = SubsonicApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
  )..setLibrary(library);
  final container = ProviderContainer(
    overrides: <Override>[
      subsonicApiClientProvider.overrideWithValue(client),
      activeLibraryProvider.overrideWithValue(library),
      activeAddressProvider.overrideWith(
        (ref) => ServerAddress(
          id: 'addr',
          libraryId: 'lib-1',
          label: '测试',
          url: 'http://127.0.0.1:4533',
          priority: 0,
          status: ServerAddressStatus.unknown,
        ),
      ),
      musicRepositoryProvider.overrideWithValue(musicRepository),
      playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
      libraryCountsProvider.overrideWith(
        (ref) async =>
            const LibraryCounts(albumCount: 3, artistCount: 2, songCount: 30),
      ),
      playerProvider.overrideWith((ref) => player ?? _RecordingPlayer()),
      castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
      dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      if (albumDetail != null)
        albumDetailProvider.overrideWith(
          (Ref ref, String albumId) async => albumDetail(albumId),
        ),
      searchResultsProvider.overrideWith(
        (Ref ref, SearchRequest req) async => SearchOutcome(),
      ),
    ],
  );
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: const AlbumListPage(),
    ),
  );
}

void main() {
  testWidgets('搜索分支：输入关键词后进入聚合搜索并携带关键词拉取本地结果', (tester) async {
    final repo = _FakeMusicRepository(<Album>[_album('al1', '寓言')]);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '寓言');
    // debounce 450ms + 结果加载。
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    expect(
      repo.pageCalls,
      contains('1:寓言'),
      reason: '搜索本地块应以 pageSize=12、page=1 携带关键词拉取',
    );
    expect(find.text('寓言'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索本地结果卡播放 → 拉专辑详情后播放队列', (tester) async {
    final repo = _FakeMusicRepository(<Album>[_album('al1', '寓言')]);
    final player = _RecordingPlayer();
    await tester.pumpWidget(
      _build(
        tester: tester,
        musicRepository: repo,
        player: player,
        albumDetail: (albumId) => AlbumDetail(
          album: _album(albumId, '寓言'),
          songs: <Song>[Song(id: 'song-1', title: '歌一')],
        ),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '寓言');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    // 本地结果卡右下角的播放按钮。
    await tester.tap(find.byIcon(Remix.play_circle_fill).first);
    await settle(tester);

    expect(player.playQueueCalls, isNotEmpty);
    expect(player.playQueueCalls.first, <String>['song-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索详情为 null → 不发起播放', (tester) async {
    final repo = _FakeMusicRepository(<Album>[_album('al1', '寓言')]);
    final player = _RecordingPlayer();
    await tester.pumpWidget(
      _build(
        tester: tester,
        musicRepository: repo,
        player: player,
        albumDetail: (_) => null,
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '寓言');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    await tester.tap(find.byIcon(Remix.play_circle_fill).first);
    await settle(tester);

    expect(player.playQueueCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分页加载：fetcher 收到 1-based 页码与默认 pageSize=200', (tester) async {
    final albums = <Album>[
      for (var i = 0; i < 260; i++) _album('al-$i', '专辑 $i'),
    ];
    final repo = _FakeMusicRepository(albums);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    // 1-based 页码 + 默认 pageSize=200（首屏只拉第 1 页 200 条）。
    expect(repo.pageCalls.first, '1:');
    expect(find.text('专辑 0'), findsOneWidget);
    expect(find.text('专辑 199'), findsNothing, reason: '虚拟滚动只渲染视口内条目');
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空搜索 → 恢复专辑网格', (tester) async {
    final repo = _FakeMusicRepository(<Album>[_album('al1', '寓言')]);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '寓言');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(repo.pageCalls, contains('1:寓言'));

    // 搜索条清空按钮（onQueryChanged('') 立即触发 reload）。
    await tester.tap(find.byIcon(AppIcons.close));
    await settle(tester);

    expect(find.text('寓言'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索且仓库未就绪 → 本地块显示无匹配空文案', (tester) async {
    await tester.pumpWidget(_build(tester: tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '不匹配');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    expect(find.text(loc.library_local_no_match_albums), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
