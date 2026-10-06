// b39c —— Route C 补测：`lib/features/search/local_search_providers.dart` 剩余缺口。
//
// 既有 b33b 覆盖了 song/album/artist/playlist 的成功路径；这里补：
//   * 49：本地专辑搜索「空词 / 仓库未就绪」→ 空页。
//   * 55：本地专辑搜索仓库抛错 → 打日志后 rethrow。
//   * 67：本地艺术家搜索空页。
//   * 73：本地艺术家搜索仓库抛错。
//   * 85：本地歌单搜索空页。
//   * 91：本地歌单搜索仓库抛错。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

class _FakeMusicRepository extends Mock implements MusicRepository {}

class _FakePlaylistRepository extends Mock implements PlaylistRepository {}

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

void main() {
  group('空页分支（仓库/库未就绪）', () {
    test('专辑搜索空页（49）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final page = await container.read(localAlbumSearchProvider('hello').future);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });

    test('艺术家搜索空页（67）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final page = await container.read(localArtistSearchProvider('hello').future);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });

    test('歌单搜索空页（85）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final page =
          await container.read(localPlaylistSearchProvider('hello').future);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });
  });

  group('仓库抛错 → 打日志并 rethrow', () {
    test('专辑搜索抛错（55）', () async {
      final repo = _FakeMusicRepository();
      when(() => repo.getAlbumsPage(any(), any(), query: any(named: 'query')))
          .thenThrow(StateError('offline'));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          musicRepositoryProvider.overrideWith((ref) => repo),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(localAlbumSearchProvider('hello').future),
        throwsA(isA<StateError>()),
      );
    });

    test('艺术家搜索抛错（73）', () async {
      final repo = _FakeMusicRepository();
      when(() => repo.getArtistsPage(any(), any(), query: any(named: 'query')))
          .thenThrow(StateError('offline'));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          musicRepositoryProvider.overrideWith((ref) => repo),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(localArtistSearchProvider('hello').future),
        throwsA(isA<StateError>()),
      );
    });

    test('歌单搜索抛错（91）', () async {
      final repo = _FakePlaylistRepository();
      when(() => repo.getPlaylistsPage(any(), any(), query: any(named: 'query')))
          .thenThrow(StateError('offline'));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => repo),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(localPlaylistSearchProvider('hello').future),
        throwsA(isA<StateError>()),
      );
    });
  });
}
