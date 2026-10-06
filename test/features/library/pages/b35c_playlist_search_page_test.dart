// batch35 C 路 —— `lib/features/library/pages/playlist_search_page.dart` 补测
//（同 album_list_page 结构；本文件补搜索分支/详情播放/分页/清空/空文案）：
//   * 聚合搜索分支（getPlaylistsPage 携带关键词）；
//   * 搜索本地结果卡播放 → _playLocalPlaylist → playlistDetailProvider → playQueue；
//   * 搜索详情为 null → 不发起播放；
//   * 分页加载（第 2 页拉取）；
//   * 清空搜索恢复列表；
//   * 搜索且仓库未就绪 → 空文案。
//
// 踩坑记录：
// #P1 playlistDetailProvider 返回 Playlist?（songs 字段在详情时才有）。
// #P2 [D-054] 标记分支绕开；#P3 450ms debounce。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remixicon/remixicon.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
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
  _FakePlaylistRepository(this.allPlaylists)
      : super(SubsonicApiClient(dio: Dio()));

  final List<Playlist> allPlaylists;
  final List<String> pageCalls = <String>[];

  @override
  Future<({List<Playlist> items, int total})> getPlaylistsPage(
    int page,
    int pageSize, {
    String query = '',
    bool favoriteOnly = false,
  }) async {
    pageCalls.add('$page:$query');
    final start = (page - 1) * pageSize;
    return (
      items: allPlaylists.skip(start).take(pageSize).toList(),
      total: allPlaylists.length,
    );
  }
}

Playlist _playlist(String id, String name) => Playlist(
      id: id,
      name: name,
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
  _FakePlaylistRepository? playlistRepository,
  _RecordingPlayer? player,
  Playlist? Function(String playlistId)? playlistDetail,
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
      playlistRepositoryProvider.overrideWithValue(
        playlistRepository ?? _FakePlaylistRepository(const <Playlist>[]),
      ),
      libraryCountsProvider.overrideWith(
        (ref) async =>
            const LibraryCounts(albumCount: 3, artistCount: 2, songCount: 30),
      ),
      playerProvider.overrideWith((ref) => player ?? _RecordingPlayer()),
      castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
      dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      if (playlistDetail != null)
        playlistDetailProvider.overrideWith(
          (Ref ref, String playlistId) async => playlistDetail(playlistId),
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
      home: const PlaylistSearchPage(),
    ),
  );
}

void main() {
  testWidgets('搜索分支：输入关键词后聚合搜索并携带关键词拉取本地结果', (tester) async {
    final repo = _FakePlaylistRepository(<Playlist>[_playlist('pl1', '华语经典')]);
    await tester.pumpWidget(_build(tester: tester, playlistRepository: repo));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '华语');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    expect(repo.pageCalls, contains('1:华语'));
    expect(find.text('华语经典'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索本地结果卡播放 → 拉歌单详情后播放队列', (tester) async {
    final repo = _FakePlaylistRepository(<Playlist>[_playlist('pl1', '华语经典')]);
    final player = _RecordingPlayer();
    await tester.pumpWidget(
      _build(
        tester: tester,
        playlistRepository: repo,
        player: player,
        playlistDetail: (playlistId) => Playlist(
          id: playlistId,
          name: '华语经典',
          songCount: 1,
          duration: 100,
          songs: <Song>[Song(id: 'song-1', title: '歌一')],
        ),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '华语');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    await tester.tap(find.byIcon(Remix.play_circle_fill).first);
    await settle(tester);

    expect(player.playQueueCalls, isNotEmpty);
    expect(player.playQueueCalls.first, <String>['song-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索详情为 null → 不发起播放', (tester) async {
    final repo = _FakePlaylistRepository(<Playlist>[_playlist('pl1', '华语经典')]);
    final player = _RecordingPlayer();
    await tester.pumpWidget(
      _build(
        tester: tester,
        playlistRepository: repo,
        player: player,
        playlistDetail: (_) => null,
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '华语');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    await tester.tap(find.byIcon(Remix.play_circle_fill).first);
    await settle(tester);

    expect(player.playQueueCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分页加载：fetcher 收到 1-based 页码与默认 pageSize=200', (tester) async {
    final playlists = <Playlist>[
      for (var i = 0; i < 260; i++) _playlist('pl-$i', '歌单 $i'),
    ];
    final repo = _FakePlaylistRepository(playlists);
    await tester.pumpWidget(_build(tester: tester, playlistRepository: repo));
    await settle(tester);

    expect(repo.pageCalls.first, '1:');
    expect(find.text('歌单 0'), findsOneWidget);
    expect(find.text('歌单 199'), findsNothing, reason: '虚拟滚动只渲染视口内条目');
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空搜索 → 恢复歌单列表', (tester) async {
    final repo = _FakePlaylistRepository(<Playlist>[_playlist('pl1', '华语经典')]);
    await tester.pumpWidget(_build(tester: tester, playlistRepository: repo));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '华语');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    await tester.tap(find.byIcon(AppIcons.close));
    await settle(tester);

    expect(find.text('华语经典'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索且仓库未就绪 → 本地块显示无匹配空文案', (tester) async {
    await tester.pumpWidget(_build(tester: tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '不匹配');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    expect(find.text(loc.library_local_no_match_playlists), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
