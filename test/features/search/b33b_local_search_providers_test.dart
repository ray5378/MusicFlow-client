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

Artist _artist(String name) =>
    Artist(id: name, name: name);

Album _album(String name) =>
    Album(id: name, name: name, songCount: 0, duration: 0);

Song _song(String id, String title, String artist) => Song(
      id: id,
      title: title,
      artist: artist,
    );

void main() {
  group('buildHotSearchTerms', () {
    test('空收藏 → 空列表', () {
      final terms = buildHotSearchTerms(
        StarredResult(artists: [], albums: [], songs: []),
      );
      expect(terms, isEmpty);
    });

    test('仅艺术家: 取其名, 去重(忽略大小写), 上限 10', () {
      final starred = StarredResult(
        artists: [
          _artist('AB'),
          _artist('ab'), // 与 AB 大小写不同视为重复
          _artist('CD'),
          _artist('Ab'),
        ],
        albums: [],
        songs: [],
      );
      final terms = buildHotSearchTerms(starred);
      expect(terms, contains('AB'));
      expect(terms, contains('CD'));
      expect(terms.length, 2);
    });

    test('仅艺术家(CJK): 相同名称去重', () {
      final starred = StarredResult(
        artists: [_artist('周杰伦'), _artist('周杰伦')],
        albums: [],
        songs: [],
      );
      final terms = buildHotSearchTerms(starred);
      expect(terms, <String>['周杰伦']);
    });

    test('优先级: 艺术家 > 专辑 > 歌曲歌手, 并统一上限 10', () {
      final starred = StarredResult(
        artists: List.generate(8, (i) => _artist('A$i')),
        albums: List.generate(5, (i) => _album('B$i')),
        songs: List.generate(5, (i) => _song('s$i', 't$i', 'C$i')),
      );
      final terms = buildHotSearchTerms(starred);
      // 前 8 个来自艺术家, 接下来 2 个来自专辑(被 limit=10 截断)。
      expect(terms.length, 10);
      expect(terms.take(8).every((t) => t.startsWith('A')), isTrue);
      expect(terms.skip(8).first, startsWith('B'));
      expect(terms.any((t) => t.startsWith('C')), isFalse);
    });

    test('跨类别去重: 专辑名与已加入的艺术家名相同则跳过', () {
      final starred = StarredResult(
        artists: [_artist('重复名')],
        albums: [_album('重复名'), _album('唯一专辑')],
        songs: [],
      );
      final terms = buildHotSearchTerms(starred);
      expect(terms, <String>['重复名', '唯一专辑']);
    });

    test('歌曲歌手贡献到热门词(不与专辑/艺术家重复时)', () {
      final starred = StarredResult(
        artists: [],
        albums: [],
        songs: [_song('1', '歌1', '林俊杰'), _song('2', '歌2', '林俊杰')],
      );
      final terms = buildHotSearchTerms(starred);
      expect(terms, <String>['林俊杰']);
    });
  });

  group('localSongSearchProvider', () {
    test('空关键词直接返回空页(不发请求)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final page =
          await container.read(localSongSearchProvider('   ').future);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });

    test('仓库/库未就绪 → 空页', () async {
      // 默认 activeLibraryProvider 为 null, repository 为 null。
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final page =
          await container.read(localSongSearchProvider('hello').future);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });

    test('成功: 返回仓库分页结果', () async {
      final repo = _FakeMusicRepository();
      when(() => repo.getSongsPage(any(), any(), query: any(named: 'query')))
          .thenAnswer((_) async => (
                items: <Song>[_song('1', 'x', 'y')],
                total: 42,
              ));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          musicRepositoryProvider.overrideWith((ref) => repo),
        ],
      );
      addTearDown(container.dispose);
      final page =
          await container.read(localSongSearchProvider('hello').future);
      expect(page.items.single.id, '1');
      expect(page.total, 42);
    });

    test('仓库抛错 → 向上 rethrow', () async {
      final repo = _FakeMusicRepository();
      when(() => repo.getSongsPage(any(), any(), query: any(named: 'query')))
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
        container.read(localSongSearchProvider('hello').future),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('localAlbumSearchProvider', () {
    test('成功: 返回专辑分页', () async {
      final repo = _FakeMusicRepository();
      when(() => repo.getAlbumsPage(any(), any(), query: any(named: 'query')))
          .thenAnswer((_) async => (
                items: <Album>[_album('al1')],
                total: 7,
              ));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          musicRepositoryProvider.overrideWith((ref) => repo),
        ],
      );
      addTearDown(container.dispose);
      final page =
          await container.read(localAlbumSearchProvider('hi').future);
      expect(page.items.single.id, 'al1');
      expect(page.total, 7);
    });
  });

  group('localArtistSearchProvider', () {
    test('成功: 返回艺术家分页', () async {
      final repo = _FakeMusicRepository();
      when(() => repo.getArtistsPage(any(), any(), query: any(named: 'query')))
          .thenAnswer((_) async => (
                items: <Artist>[_artist('ar1')],
                total: 3,
              ));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          musicRepositoryProvider.overrideWith((ref) => repo),
        ],
      );
      addTearDown(container.dispose);
      final page =
          await container.read(localArtistSearchProvider('hi').future);
      expect(page.items.single.id, 'ar1');
      expect(page.total, 3);
    });
  });

  group('localPlaylistSearchProvider', () {
    test('成功: 返回歌单分页', () async {
      final repo = _FakePlaylistRepository();
      when(() => repo.getPlaylistsPage(any(), any(), query: any(named: 'query')))
          .thenAnswer((_) async => (
                items: <Playlist>[
                  Playlist(id: 'pl1', name: 'pl', songCount: 0, duration: 0),
                ],
                total: 5,
              ));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => repo),
        ],
      );
      addTearDown(container.dispose);
      final page =
          await container.read(localPlaylistSearchProvider('hi').future);
      expect(page.items.single.id, 'pl1');
      expect(page.total, 5);
    });
  });

  group('hotSearchTermsProvider', () {
    test('成功: 由收藏构造热门词', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          starredProvider.overrideWith(
            (ref) async => StarredResult(
              artists: [_artist('周杰伦')],
              albums: [],
              songs: [],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final terms = await container.read(hotSearchTermsProvider.future);
      expect(terms, <String>['周杰伦']);
    });

    test('starred 抛错 → 返回空列表', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          starredProvider.overrideWith(
            (ref) => throw StateError('starred failed'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final terms = await container.read(hotSearchTermsProvider.future);
      expect(terms, isEmpty);
    });
  });
}
