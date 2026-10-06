import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/library_stats_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

class _FakeMusicRepository extends Mock implements MusicRepository {}

ServerAddress _addr() => ServerAddress(
      id: 'a1',
      libraryId: 'lib-1',
      label: 'Home',
      url: 'https://example.test',
      priority: 0,
    );

MusicLibrary _lib() => MusicLibrary(
      id: 'lib-1',
      name: 'Test',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

ProviderContainer _container({
  required _FakeMusicRepository repo,
  List<Playlist> playlists = const <Playlist>[],
}) {
  return ProviderContainer(
    overrides: <Override>[
      activeLibraryProvider.overrideWithValue(_lib()),
      activeAddressProvider.overrideWith((ref) => _addr()),
      musicRepositoryProvider.overrideWith((ref) => repo),
      playlistsProvider.overrideWith((ref) async => playlists),
    ],
  );
}

void main() {
  test('LibraryCounts.isEmpty: 全 null 为 true, 部分非 null 为 false', () {
    expect(const LibraryCounts().isEmpty, isTrue);
    expect(const LibraryCounts(artistCount: 1).isEmpty, isFalse);
    expect(
      const LibraryCounts(albumCount: 0, songCount: 0).isEmpty,
      isFalse,
    );
  });

  test('LibraryCounts.format: 维度数量决定 · 分隔符个数', () {
    final full = LibraryCounts(
      artistCount: 8,
      albumCount: 30,
      songCount: 2105,
      playlistCount: 12,
    );
    expect('·'.allMatches(full.format()).length, 3);

    // 单维度:无分隔符,但包含对应数值。
    final single = LibraryCounts(songCount: 5);
    final s = single.format();
    expect('·'.allMatches(s).length, 0);
    expect(s, contains('5'));
  });

  test('LibraryCounts 标签: 仅非 null 维度返回 label', () {
    final partial = LibraryCounts(albumCount: 3);
    expect(partial.artistsLabel, isNull);
    expect(partial.albumsLabel, isNotNull);
    expect(partial.songsLabel, isNull);
    expect(partial.playlistsLabel, isNull);

    final full = LibraryCounts(
      artistCount: 1,
      albumCount: 2,
      songCount: 3,
      playlistCount: 4,
    );
    expect(full.artistsLabel, isNotNull);
    expect(full.albumsLabel, isNotNull);
    expect(full.songsLabel, isNotNull);
    expect(full.playlistsLabel, isNotNull);
  });

  test('libraryCountsProvider: 各维度成功返回计数', () async {
    final repo = _FakeMusicRepository();
    when(() => repo.getArtistsPage(any(), any()))
        .thenAnswer((_) async => (items: <Artist>[], total: 5));
    when(() => repo.getAlbumsPage(any(), any()))
        .thenAnswer((_) async => (items: <Album>[], total: 3));
    when(() => repo.getSongsPage(any(), any()))
        .thenAnswer((_) async => (items: <Song>[], total: 100));
    final container = _container(
      repo: repo,
      playlists: <Playlist>[
        Playlist(id: 'p', name: 'x', songCount: 0, duration: 0),
      ],
    );
    addTearDown(container.dispose);

    final counts = await container.read(libraryCountsProvider.future);
    expect(counts.artistCount, 5);
    expect(counts.albumCount, 3);
    expect(counts.songCount, 100);
    expect(counts.playlistCount, 1);
  });

  test('libraryCountsProvider: 单维度失败 → 该维度 null, 其余不受影响', () async {
    final repo = _FakeMusicRepository();
    when(() => repo.getArtistsPage(any(), any())).thenThrow(StateError('x'));
    when(() => repo.getAlbumsPage(any(), any()))
        .thenAnswer((_) async => (items: <Album>[], total: 3));
    when(() => repo.getSongsPage(any(), any()))
        .thenAnswer((_) async => (items: <Song>[], total: 100));
    final container = _container(repo: repo, playlists: const <Playlist>[]);
    addTearDown(container.dispose);

    final counts = await container.read(libraryCountsProvider.future);
    expect(counts.artistCount, isNull);
    expect(counts.albumCount, 3);
    expect(counts.songCount, 100);
    expect(counts.playlistCount, 0);
  });

  test('libraryCountsProvider: musicRepository 为 null → 返回空计数', () async {
    final container = ProviderContainer(
      overrides: <Override>[
        activeLibraryProvider.overrideWithValue(_lib()),
        activeAddressProvider.overrideWith((ref) => _addr()),
        musicRepositoryProvider.overrideWith((ref) => null),
        playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
      ],
    );
    addTearDown(container.dispose);

    final counts = await container.read(libraryCountsProvider.future);
    expect(counts.isEmpty, isTrue);
  });

  test('libraryCountsProvider: playlistsProvider 抛错 → playlistCount 为 null', () async {
    final repo = _FakeMusicRepository();
    when(() => repo.getArtistsPage(any(), any()))
        .thenAnswer((_) async => (items: <Artist>[], total: 5));
    when(() => repo.getAlbumsPage(any(), any()))
        .thenAnswer((_) async => (items: <Album>[], total: 3));
    when(() => repo.getSongsPage(any(), any()))
        .thenAnswer((_) async => (items: <Song>[], total: 100));
    final container = ProviderContainer(
      overrides: <Override>[
        activeLibraryProvider.overrideWithValue(_lib()),
        activeAddressProvider.overrideWith((ref) => _addr()),
        musicRepositoryProvider.overrideWith((ref) => repo),
        playlistsProvider.overrideWith((ref) => throw StateError('db')),
      ],
    );
    addTearDown(container.dispose);

    final counts = await container.read(libraryCountsProvider.future);
    expect(counts.artistCount, 5);
    expect(counts.playlistCount, isNull);
  });
}
