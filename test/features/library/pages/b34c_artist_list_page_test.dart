// batch34 C 路 —— `lib/features/library/pages/artist_list_page.dart` 补测。
// 覆盖点：有数据行渲染 / 空态 / 仓库失败不崩 / 点击行推歌手详情页 /
// 长按弹歌手操作弹窗 / 标题计数。
// 结构与 b34c_album_list_page_test 同构（harness 说明见该文件 #A1-A3）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
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

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository({this.artists = const <Artist>[]})
      : super(SubsonicApiClient(dio: Dio()));

  final List<Artist> artists;
  int artistsPageCalls = 0;
  Object? pageError;

  @override
  Future<({List<Artist> items, int total})> getArtistsPage(
    int page,
    int pageSize, {
    String? query,
  }) async {
    artistsPageCalls += 1;
    if (pageError != null) throw pageError!;
    return (items: artists, total: artists.length);
  }
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

Artist _artist(String id, String name) => Artist(
      id: id,
      name: name,
      coverArt: null,
      albumCount: 3,
    );

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

late AppLocalizations loc;

Widget _build({
  required WidgetTester tester,
  _FakeMusicRepository? musicRepository,
  ArtistDetail? artistDetail,
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
            const LibraryCounts(artistCount: 2, albumCount: 3, songCount: 30),
      ),
      playerProvider.overrideWith((ref) => _RecordingPlayer()),
      castPeerControllerProvider.overrideWith(
        (Ref ref) => _StubCastPeer(ref),
      ),
      dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      if (artistDetail != null)
        artistDetailProvider.overrideWith(
          (ref, String artistId) async => artistDetail,
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
  testWidgets('有数据：歌手行渲染（名称 + 专辑数）+ 标题计数副标题', (tester) async {
    final repo = _FakeMusicRepository(
      artists: <Artist>[_artist('ar1', '王菲'), _artist('ar2', '陈奕迅')],
    );
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    expect(find.text('王菲'), findsOneWidget);
    expect(find.text('陈奕迅'), findsOneWidget);
    expect(find.byKey(const ValueKey('artist-row-ar1')), findsOneWidget);
    expect(find.textContaining('2'), findsWidgets,
        reason: '标题下方应显示 artistsLabel（2 位艺人）');
    expect(repo.artistsPageCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库未就绪（null）→ 空态文案', (tester) async {
    await tester.pumpWidget(_build(tester: tester));
    await settle(tester);

    expect(find.text(loc.library_empty_artists), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库分页失败 → 不崩溃，仓库被调用过（确定性副作用断言）', (tester) async {
    final repo = _FakeMusicRepository()..pageError = StateError('network down');
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    expect(repo.artistsPageCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击歌手行 → 推入歌手详情页并渲染歌曲', (tester) async {
    final repo = _FakeMusicRepository(artists: <Artist>[_artist('ar1', '王菲')]);
    await tester.pumpWidget(_build(
      tester: tester,
      musicRepository: repo,
      artistDetail: ArtistDetail(
        artist: _artist('ar1', '王菲'),
        albums: <Album>[],
        songs: <Song>[
          Song(id: 's1', title: '旋木', artist: '王菲'),
        ],
      ),
    ));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('artist-row-ar1')));
    await settle(tester, frames: 12);

    expect(find.text('旋木'), findsWidgets, reason: '详情页应渲染歌手歌曲');
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按歌手行 → 弹出歌手操作弹窗', (tester) async {
    final repo = _FakeMusicRepository(artists: <Artist>[_artist('ar1', '王菲')]);
    await tester.pumpWidget(_build(tester: tester, musicRepository: repo));
    await settle(tester);

    await tester.longPress(find.byKey(const ValueKey('artist-row-ar1')));
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(find.text('王菲'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
