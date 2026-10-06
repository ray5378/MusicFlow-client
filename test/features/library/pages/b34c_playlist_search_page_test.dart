// batch34 C 路 —— `lib/features/library/pages/playlist_search_page.dart` 补测。
// 覆盖点：有数据行渲染 / 空态 / 仓库失败不崩 / 点击行推歌单详情页 /
// 长按弹歌单操作弹窗 / 标题计数。
// 结构与 b34c_album_list_page_test 同构（harness 说明见该文件 #A1-A3）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
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
  _FakeMusicRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository({
    this.playlists = const <Playlist>[],
    this.tracks = const <Song>[],
  }) : super(SubsonicApiClient(dio: Dio()));

  final List<Playlist> playlists;
  final List<Song> tracks;
  int playlistsPageCalls = 0;
  Object? pageError;

  @override
  Future<({List<Playlist> items, int total})> getPlaylistsPage(
    int page,
    int pageSize, {
    String query = '',
    bool favoriteOnly = false,
  }) async {
    playlistsPageCalls += 1;
    if (pageError != null) throw pageError!;
    return (items: playlists, total: playlists.length);
  }

  @override
  Future<Playlist?> getPlaylistMeta(String playlistId) async {
    for (final p in playlists) {
      if (p.id == playlistId) return p;
    }
    return null;
  }

  @override
  Future<({List<Song> items, int total})> getPlaylistTracksPage(
    String playlistId,
    int page,
    int pageSize,
  ) async {
    return (items: tracks, total: tracks.length);
  }
}

Playlist _playlist(String id, String name) => Playlist(
      id: id,
      name: name,
      songCount: 8,
      duration: 1200,
      coverArt: null,
    );

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

late AppLocalizations loc;

Widget _build({
  required WidgetTester tester,
  _FakePlaylistRepository? playlistRepository,
  Playlist? playlistDetail,
}) {  final library = MusicLibrary(
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
      musicRepositoryProvider.overrideWithValue(_FakeMusicRepository()),
      playlistRepositoryProvider.overrideWithValue(playlistRepository),
      libraryCountsProvider.overrideWith(
        (ref) async =>
            const LibraryCounts(playlistCount: 4, artistCount: 2, songCount: 30),
      ),
      playerProvider.overrideWith((ref) => _RecordingPlayer()),
      castPeerControllerProvider.overrideWith(
        (Ref ref) => _StubCastPeer(ref),
      ),
      dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      if (playlistDetail != null)
        playlistDetailProvider.overrideWith(
          (ref, String playlistId) async => playlistDetail,
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
  testWidgets('有数据：歌单行渲染 + 标题计数副标题', (tester) async {
    final repo = _FakePlaylistRepository(
      playlists: <Playlist>[
        _playlist('p1', '夜跑歌单'),
        _playlist('p2', '通勤歌单'),
      ],
    );
    await tester.pumpWidget(_build(tester: tester, playlistRepository: repo));
    await settle(tester);

    expect(find.text('夜跑歌单'), findsOneWidget);
    expect(find.text('通勤歌单'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-row-p1')), findsOneWidget);
    expect(find.textContaining('4'), findsWidgets,
        reason: '标题下方应显示 playlistsLabel（4 个歌单）');
    expect(repo.playlistsPageCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库未就绪（null）→ 空态文案', (tester) async {
    await tester.pumpWidget(_build(tester: tester));
    await settle(tester);

    expect(find.text(loc.library_empty_playlists), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库分页失败 → 不崩溃，仓库被调用过（确定性副作用断言）', (tester) async {
    final repo = _FakePlaylistRepository()
      ..pageError = StateError('network down');
    await tester.pumpWidget(_build(tester: tester, playlistRepository: repo));
    await settle(tester);

    expect(repo.playlistsPageCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击歌单行 → 推入歌单详情页并渲染歌曲', (tester) async {
    final repo = _FakePlaylistRepository(
      playlists: <Playlist>[_playlist('p1', '夜跑歌单')],
      tracks: <Song>[Song(id: 's1', title: '夜曲', artist: '周杰伦')],
    );
    await tester.pumpWidget(_build(
      tester: tester,
      playlistRepository: repo,
      playlistDetail: Playlist(
        id: 'p1',
        name: '夜跑歌单',
        songCount: 1,
        duration: 200,
        songs: <Song>[Song(id: 's1', title: '夜曲', artist: '周杰伦')],
      ),
    ));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('playlist-row-p1')));
    await settle(tester, frames: 14);

    expect(find.text('夜曲'), findsWidgets, reason: '详情页应渲染歌单歌曲');
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按歌单行 → 弹出歌单操作弹窗', (tester) async {
    final repo = _FakePlaylistRepository(
      playlists: <Playlist>[_playlist('p1', '夜跑歌单')],
    );
    await tester.pumpWidget(_build(tester: tester, playlistRepository: repo));
    await settle(tester);

    await tester.longPress(find.byKey(const ValueKey('playlist-row-p1')));
    await settle(tester, frames: 14);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
