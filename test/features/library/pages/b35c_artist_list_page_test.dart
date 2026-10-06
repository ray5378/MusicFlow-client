// batch35 C 路 —— `lib/features/library/pages/artist_list_page.dart` 补测
//（同 album_list_page 结构；batch34 已覆盖网格/空态/失败路径，本文件补）：
//   * 聚合搜索分支（getArtistsPage 携带关键词）；
//   * 搜索本地结果卡播放 → _playLocalArtist → artistDetailProvider → playQueue；
//   * 搜索详情为 null → 不发起播放；
//   * 分页加载（第 2 页拉取）；
//   * 清空搜索恢复列表；
//   * 搜索且仓库未就绪 → 空文案。
//
// 踩坑记录：
// #P1 fetcher 收到 1-based page；切片按 (page-1)*pageSize。
// #P2 [D-054] 标记的「详情拉取失败 unhandled async error」分支绕开，只测 null 路径。
// #P3 EntitySearchBar 450ms debounce，输入后 pump ≥450ms。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remixicon/remixicon.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
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
  _FakeMusicRepository(this.allArtists) : super(SubsonicApiClient(dio: Dio()));

  final List<Artist> allArtists;
  final List<String> pageCalls = <String>[];

  @override
  Future<({List<Artist> items, int total})> getArtistsPage(
    int page,
    int pageSize, {
    String? query,
  }) async {
    pageCalls.add('$page:${query ?? ''}');
    final start = (page - 1) * pageSize;
    return (
      items: allArtists.skip(start).take(pageSize).toList(),
      total: allArtists.length,
    );
  }
}

Artist _artist(String id, String name) =>
    Artist(id: id, name: name, albumCount: 3);

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
  ArtistDetail? Function(String artistId)? artistDetail,
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
      if (artistDetail != null)
        artistDetailProvider.overrideWith(
          (Ref ref, String artistId) async => artistDetail(artistId),
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
      home: const ArtistListPage(),
    ),
  );
}

void main() {
  testWidgets('搜索分支：输入关键词后聚合搜索并携带关键词拉取本地结果', (tester) async {
    final repo = _FakeMusicRepository(<Artist>[_artist('ar1', '王菲')]);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '王菲');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    expect(repo.pageCalls, contains('1:王菲'));
    expect(find.text('王菲'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索本地结果卡播放 → 拉艺人详情后播放队列', (tester) async {
    final repo = _FakeMusicRepository(<Artist>[_artist('ar1', '王菲')]);
    final player = _RecordingPlayer();
    await tester.pumpWidget(
      _build(
        tester: tester,
        musicRepository: repo,
        player: player,
        artistDetail: (artistId) => ArtistDetail(
          artist: _artist(artistId, '王菲'),
          albums: const <Album>[],
          songs: <Song>[Song(id: 'song-9', title: '歌九')],
        ),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '王菲');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    await tester.tap(find.byIcon(Remix.play_circle_fill).first);
    await settle(tester);

    expect(player.playQueueCalls, isNotEmpty);
    expect(player.playQueueCalls.first, <String>['song-9']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索详情为 null → 不发起播放', (tester) async {
    final repo = _FakeMusicRepository(<Artist>[_artist('ar1', '王菲')]);
    final player = _RecordingPlayer();
    await tester.pumpWidget(
      _build(
        tester: tester,
        musicRepository: repo,
        player: player,
        artistDetail: (_) => null,
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '王菲');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    await tester.tap(find.byIcon(Remix.play_circle_fill).first);
    await settle(tester);

    expect(player.playQueueCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分页加载：fetcher 收到 1-based 页码与默认 pageSize=200', (tester) async {
    final artists = <Artist>[
      for (var i = 0; i < 260; i++) _artist('ar-$i', '艺人 $i'),
    ];
    final repo = _FakeMusicRepository(artists);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    expect(repo.pageCalls.first, '1:');
    expect(find.text('艺人 0'), findsOneWidget);
    expect(find.text('艺人 199'), findsNothing, reason: '虚拟滚动只渲染视口内条目');
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空搜索 → 恢复艺人列表', (tester) async {
    final repo = _FakeMusicRepository(<Artist>[_artist('ar1', '王菲')]);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '王菲');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    await tester.tap(find.byIcon(AppIcons.close));
    await settle(tester);

    expect(find.text('王菲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索且仓库未就绪 → 本地块显示无匹配空文案', (tester) async {
    await tester.pumpWidget(_build(tester: tester));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '不匹配');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    expect(find.text(loc.library_local_no_match_artists), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
