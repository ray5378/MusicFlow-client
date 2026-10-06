// b39c2 —— Route C 清尾：library 本地页面剩余缺口。
//   * remote_playlist_page.dart:125 —— 歌曲行 onLongPress 闭包 →
//     showSongOptionsSheet（既有 b38c3 只点了行 onTap 123-124，未长按）。
//   * album_list_page.dart:125 —— 聚合搜索本地专辑块 itemBuilder 构造
//     SearchAlbumCard（onImport: () {}）。
//
// 手法：remote_playlist 沿用 b38c3_remote_pages_extra_test 的 SearchRepository
// 子类桩；album_list 沿用 b35c_album_list_page_test 的搜索链路（450ms debounce）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/features/library/pages/remote_playlist_page.dart';
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
  _RecordingPlayer(super.state);

  final List<String> calls = <String>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    calls.add('playQueue:${songs.length}:$startIndex');
    if (songs.isEmpty) return;
    final idx = startIndex.clamp(0, songs.length - 1);
    state = state.copyWith(
      queue: songs,
      currentIndex: idx,
      currentSong: songs[idx],
    );
  }
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

class _FakeSearchRepo extends SearchRepository {
  _FakeSearchRepo() : super(SubsonicApiClient(dio: Dio()));

  List<Song> songs = const <Song>[];

  @override
  Future<List<Song>> getPlaylistSongs(
    String providerId,
    SearchPlaylist pl,
  ) async {
    return songs;
  }
}

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));
}

class _FakeMusicRepository extends MusicRepository {
  _FakeMusicRepository(this.allAlbums) : super(SubsonicApiClient(dio: Dio()));

  final List<Album> allAlbums;

  @override
  Future<({List<Album> items, int total})> getAlbumsPage(
    int page,
    int pageSize, {
    String? query,
  }) async {
    final start = (page - 1) * pageSize;
    return (
      items: allAlbums.skip(start).take(pageSize).toList(),
      total: allAlbums.length,
    );
  }
}

Song _song(String id, String title) => Song(id: id, title: title);

SearchPlaylist _playlist({String id = 'rp-1', String name = '远程歌单'}) =>
    SearchPlaylist(
      id: id,
      source: 'plugin-a',
      name: name,
      creator: '远程用户',
      providerId: 'prov-1',
      platformLabel: '网易云',
      trackCount: '3',
    );

Album _album(String id, String name) => Album(
      id: id,
      name: name,
      artist: '歌手',
      coverArt: null,
      songCount: 5,
      duration: 600,
    );

MusicLibrary _library() => MusicLibrary(
      id: 'lib-1',
      name: '测试库',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    );

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _stubEnv(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('remote_playlist：长按歌曲行 → 弹歌曲操作面板（125）',
      (tester) async {
    final repo = _FakeSearchRepo()
      ..songs = <Song>[_song('rs1', '远程曲一'), _song('rs2', '远程曲二')];
    _stubEnv(tester);
    final container = ProviderContainer(
      overrides: <Override>[
        searchRepositoryProvider.overrideWithValue(repo),
        playerProvider.overrideWith((ref) => _RecordingPlayer(PlayerState())),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: RemotePlaylistPage(playlist: _playlist(), providerId: 'prov-1'),
        ),
      ),
    );
    await settle(tester);

    expect(find.text('远程曲一'), findsOneWidget);

    // 长按歌曲行 → onLongPress 闭包（125）→ showSongOptionsSheet。
    await tester.longPress(find.text('远程曲一'));
    await settle(tester, frames: 14);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget,
        reason: '长按应弹出歌曲操作面板');
    expect(tester.takeException(), isNull);
  });

  testWidgets('album_list：聚合搜索本地专辑块构建 SearchAlbumCard（125）',
      (tester) async {
    final repo = _FakeMusicRepository(<Album>[_album('al1', '寓言')]);
    _stubEnv(tester);
    final library = _library();
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
        musicRepositoryProvider.overrideWithValue(repo),
        playlistRepositoryProvider.overrideWithValue(_FakePlaylistRepository()),
        libraryCountsProvider.overrideWith(
          (ref) async =>
              const LibraryCounts(albumCount: 3, artistCount: 2, songCount: 30),
        ),
        playerProvider.overrideWith((ref) => _RecordingPlayer(PlayerState())),
        castPeerControllerProvider.overrideWith((Ref ref) => _StubCastPeer(ref)),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
        searchResultsProvider.overrideWith(
          (Ref ref, SearchRequest req) async => SearchOutcome(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const AlbumListPage(),
        ),
      ),
    );
    await settle(tester);

    // EntitySearchBar 450ms debounce → 聚合搜索 → 本地专辑块 itemBuilder（125）。
    await tester.enterText(find.byType(TextField).first, '寓言');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);

    expect(find.text('寓言'), findsWidgets,
        reason: '本地专辑卡应渲染（SearchAlbumCard 构造 → 125 执行）');
    expect(tester.takeException(), isNull);
  });
}
