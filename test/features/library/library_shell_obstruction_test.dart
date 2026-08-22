import 'package:azlistview/azlistview.dart';
import 'package:dio/dio.dart';
import 'package:musicflow_client/core/design/echo_design.dart';
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
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/music_provider.dart';
import 'package:musicflow_client/providers/playlist_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _obstruction = 120.0;
final _expectedBottomSpace = EchoSpacing.standard.xxl + _obstruction;

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
  songs: <Song>[_song],
);

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
        ...overrides,
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: EchoShellObstructionScope(bottom: _obstruction, child: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectSpacer(WidgetTester tester, String key) {
  final spacer = tester.widget<SizedBox>(find.byKey(ValueKey<String>(key)));
  expect(spacer.height, _expectedBottomSpace);
  expect(tester.takeException(), isNull);
}

void _expectAzCollection(WidgetTester tester, String key) {
  final list = tester.widget<AzListView>(find.byKey(ValueKey<String>(key)));
  final decoration = list.indexBarOptions.decoration! as BoxDecoration;
  expect(list.padding, EdgeInsets.only(bottom: _expectedBottomSpace));
  expect(list.indexBarWidth, 24);
  expect(list.indexBarHeight, isNull);
  expect(decoration.color!.a, 0);
  expect(find.byType(EchoAzIndexReveal), findsOneWidget);
  expect(tester.takeException(), isNull);
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

    _expectSpacer(tester, 'album-detail-bottom-spacer');
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

    _expectSpacer(tester, 'artist-detail-bottom-spacer');
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
      ],
    );

    _expectSpacer(tester, 'playlist-detail-bottom-spacer');
  });

  testWidgets('album collection adds the shell obstruction to list padding', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: const AlbumListPage(),
      overrides: <Override>[
        allAlbumsProvider.overrideWith((ref) async => <Album>[_album]),
      ],
    );

    _expectAzCollection(tester, 'album-list-scroll');
  });

  testWidgets('artist collection uses the shared auto-hiding A-Z rail', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: const ArtistListPage(),
      overrides: <Override>[
        allArtistsProvider.overrideWith((ref) async => <Artist>[_artist]),
      ],
    );

    _expectAzCollection(tester, 'artist-list-scroll');
  });

  testWidgets('song collection uses the shared auto-hiding A-Z rail', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: const SongListPage(),
      overrides: <Override>[
        allSongsProvider.overrideWith((ref) async => <Song>[_song]),
      ],
    );

    _expectAzCollection(tester, 'song-list-alphabetical-scroll');
  });
}
