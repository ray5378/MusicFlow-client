import 'package:dio/dio.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/music_provider.dart';
import 'package:musicflow_client/providers/playlist_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';


const _obstruction = 120.0;

final _song = Song(
  id: 'song-1',
  title: 'Song',
  artist: 'Artist',
  artistId: 'artist-1',
  album: 'Album',
  albumId: 'album-1',
  duration: 180,
);

final _album = Album(
  id: 'album-1',
  name: 'Album',
  artist: 'Artist',
  artistId: 'artist-1',
  songCount: 1,
  duration: 180,
);

final _artist = Artist(id: 'artist-1', name: 'Artist', albumCount: 1);

final _playlist = Playlist(
  id: 'playlist-1',
  name: 'Playlist',
  songCount: 1,
  duration: 180,
);

/// 歌单详情页走窗口化分页仓库接口,测试需提供可用的仓库实现才能渲染正文。
class _FakePlaylistRepository extends Fake implements PlaylistRepository {
  @override
  Future<Playlist?> getPlaylistMeta(String playlistId) async => _playlist;

  @override
  Future<({List<Song> items, int total})> getPlaylistTracksPage(
    String playlistId,
    int page,
    int pageSize,
  ) async =>
      (items: <Song>[_song], total: 1);
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required Widget page,
  required List<Override> overrides,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final connectivityMonitor = ConnectivityMonitor(AddressPool(Dio()));
  addTearDown(connectivityMonitor.stop);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(connectivityMonitor),
        // 立即返回假地址,避免 ensureActiveAddress 的 6s 探测轮询挂起计时器。
        ensureActiveAddressProvider.overrideWith((ref) async => const ServerAddress(
              id: 'addr-test',
              libraryId: 'lib-test',
              label: 'test',
              url: 'https://music.test',
              priority: 0,
              status: ServerAddressStatus.ok,
            )),
        ...overrides,
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: MusicFlowShellObstructionScope(bottom: _obstruction, child: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 冲掉 ensureActiveAddress / 搜索防抖等一次性计时器。
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('album detail keeps its base spacer above shell chrome', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: const AlbumDetailPage(albumId: 'album-1'),
      overrides: <Override>[
        albumDetailProvider('album-1').overrideWith(
          (ref) async => AlbumDetail(album: _album, songs: <Song>[_song]),
        ),
      ],
    );

    final spacer =
        tester.widget<SizedBox>(find.byKey(const ValueKey<String>('album-detail-bottom-spacer')));
    expect(spacer.height, MusicFlowSpacing.standard.xxl + _obstruction);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artist detail keeps its base spacer above shell chrome', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: const ArtistDetailPage(artistId: 'artist-1'),
      overrides: <Override>[
        artistDetailProvider('artist-1').overrideWith(
          (ref) async => ArtistDetail(
            artist: _artist,
            albums: <Album>[_album],
            songs: <Song>[_song],
          ),
        ),
        topSongsByArtistProvider(
          'Artist',
        ).overrideWith((ref) async => <Song>[]),
      ],
    );

    final spacer =
        tester.widget<SizedBox>(find.byKey(const ValueKey<String>('artist-detail-bottom-spacer')));
    expect(spacer.height, MusicFlowSpacing.standard.xxl + _obstruction);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist detail keeps its base spacer above shell chrome', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: const PlaylistDetailPage(playlistId: 'playlist-1'),
      overrides: <Override>[
        playlistDetailProvider(
          'playlist-1',
        ).overrideWith((ref) async => _playlist),
        playlistRepositoryProvider.overrideWithValue(
          _FakePlaylistRepository(),
        ),
      ],
    );

    final spacer =
        tester.widget<SizedBox>(find.byKey(const ValueKey<String>('playlist-detail-bottom-spacer')));
    expect(spacer.height, MusicFlowSpacing.standard.xxl + _obstruction);
    expect(tester.takeException(), isNull);
  });

  testWidgets('windowed collections reserve the shell obstruction', (
    tester,
  ) async {
    Future<void> assertPage(Widget page) async {
      await _pumpPage(tester, page: page, overrides: const <Override>[]);
      // 泛型运行时类型不同(Album/Song/...),按 runtimeType 前缀匹配。
      final views = find
          .byWidgetPredicate(
            (w) => w.runtimeType.toString().startsWith('WindowedListView<'),
          )
          .evaluate()
          .toList();
      expect(views, hasLength(1));
      final padding = (views.single.widget as dynamic).padding as EdgeInsets?;
      expect(padding, isNotNull);
      expect(
        padding!.bottom,
        MusicFlowSpacing.standard.xxl + _obstruction,
      );
      expect(tester.takeException(), isNull);
    }

    await assertPage(const AlbumListPage());
    await assertPage(const SongListPage());
    await assertPage(const ArtistListPage());
    await assertPage(const PlaylistSearchPage());

    // 冲掉 EntitySearchBar 的输入防抖计时器,避免测试结束时挂起 Timer。
    await tester.pump(const Duration(milliseconds: 350));
  });
}
