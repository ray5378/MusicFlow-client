import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

class _FakePlaylistRepository extends Mock implements PlaylistRepository {}

class _FakeMetadataCache extends Mock implements MetadataCacheRepository {}

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

Playlist _pl(String id, {DateTime? changed, int songCount = 0}) => Playlist(
      id: id,
      name: 'PL $id',
      songCount: songCount,
      duration: 0,
      changed: changed,
    );

List<Override> _commonOverrides({
  required _FakePlaylistRepository repo,
  required _FakeMetadataCache cache,
}) =>
    <Override>[
      activeLibraryProvider.overrideWithValue(_lib()),
      activeAddressProvider.overrideWith((ref) => _addr()),
      playlistRepositoryProvider.overrideWith((ref) => repo),
      metadataCacheRepositoryProvider.overrideWith((ref) => cache),
    ];

void main() {
  setUpAll(() {
    registerFallbackValue(_pl("fb"));
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  group('recentPlaylistsProvider', () {
    test('成功: 按 changed 倒序并取前 20', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(() => repo.getPlaylists()).thenAnswer((_) async {
        final list = <Playlist>[];
        for (var i = 0; i < 25; i++) {
          list.add(_pl('p$i', changed: DateTime(2024, 1, i + 1)));
        }
        return list;
      });
      when(() => cache.cachePlaylists(any(), any())).thenAnswer((_) async {});
      when(() => cache.getPlaylists(any()))
          .thenAnswer((_) async => null);

      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);

      final result = await container.read(recentPlaylistsProvider.future);
      expect(result.length, 20);
      // 第一个应是 changed 最大的(2024-01-25)。
      expect(result.first.id, 'p24');
      // 倒序: 第二个比第一个早。
      expect(
        result[0].changed!.isAfter(result[1].changed!),
        isTrue,
      );
    });

    test('仓库为 null + 缓存命中 → 缓存兜底返回排序结果', () async {
      final cache = _FakeMetadataCache();
      final cached = <Playlist>[
        _pl('c1', changed: DateTime(2024, 3, 1)),
        _pl('c2', changed: DateTime(2024, 5, 1)),
      ];
      when(() => cache.getPlaylists(any())).thenAnswer((_) async => cached);

      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => null),
          metadataCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(recentPlaylistsProvider.future);
      expect(result.map((p) => p.id).toList(), <String>['c2', 'c1']);
    });

    test('仓库为 null + 缓存未命中 → 返回空列表', () async {
      final cache = _FakeMetadataCache();
      when(() => cache.getPlaylists(any())).thenAnswer((_) async => null);

      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => null),
          metadataCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(recentPlaylistsProvider.future);
      expect(result, isEmpty);
    });

    test('冷启动: 活跃库未就绪但 lastLibraryId 命中缓存 → 缓存兜底', () async {
      final cache = _FakeMetadataCache();
      when(() => cache.getLastLibraryId()).thenAnswer((_) async => 'lib-x');
      when(() => cache.getPlaylists('lib-x')).thenAnswer(
        (_) async => <Playlist>[_pl('k1', changed: DateTime(2024, 6, 1))],
      );

      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWith((ref) => null),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => null),
          metadataCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(recentPlaylistsProvider.future);
      expect(result.single.id, 'k1');
    });
  });

  group('playlistsProvider', () {
    test('成功: 返回全部歌单', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(() => repo.getPlaylists())
          .thenAnswer((_) async => <Playlist>[_pl('a'), _pl('b')]);
      when(() => cache.cachePlaylists(any(), any())).thenAnswer((_) async {});
      when(() => cache.getPlaylists(any())).thenAnswer((_) async => null);

      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);

      final result = await container.read(playlistsProvider.future);
      expect(result.map((p) => p.id).toList(), <String>['a', 'b']);
    });

    test('仓库为 null + 缓存命中 → 缓存兜底', () async {
      final cache = _FakeMetadataCache();
      when(() => cache.getPlaylists(any()))
          .thenAnswer((_) async => <Playlist>[_pl('c')]);

      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => null),
          metadataCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(playlistsProvider.future);
      expect(result.single.id, 'c');
    });
  });

  group('favoritePlaylistsProvider', () {
    test('成功: 多页累加直到 total', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(
        () => repo.getPlaylistsPage(
          any(),
          any(),
          favoriteOnly: any(named: 'favoriteOnly'),
        ),
      ).thenAnswer((invocation) {
        final page = invocation.positionalArguments[0] as int;
        if (page == 1) {
          return Future.value((
            items: List.generate(100, (i) => _pl('p${(page - 1) * 100 + i}')),
            total: 250,
          ));
        }
        if (page == 2) {
          return Future.value((
            items: List.generate(100, (i) => _pl('p${(page - 1) * 100 + i}')),
            total: 250,
          ));
        }
        return Future.value((
          items: List.generate(50, (i) => _pl('p${(page - 1) * 100 + i}')),
          total: 250,
        ));
      });

      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);

      final result = await container.read(favoritePlaylistsProvider.future);
      expect(result.length, 250);
    });

    test('单页即满: 立即返回', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(
        () => repo.getPlaylistsPage(
          any(),
          any(),
          favoriteOnly: any(named: 'favoriteOnly'),
        ),
      ).thenAnswer(
        (_) async => (
          items: <Playlist>[_pl('x')],
          total: 1,
        ),
      );
      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);
      final result = await container.read(favoritePlaylistsProvider.future);
      expect(result.length, 1);
      expect(container.read(favoritePlaylistsLoadFailedProvider), isFalse);
    });

    test('仓库为 null → 空列表', () async {
      final cache = _FakeMetadataCache();
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => null),
          metadataCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);
      final result = await container.read(favoritePlaylistsProvider.future);
      expect(result, isEmpty);
    });

    test('加载失败 → 空列表并置失败标记', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(
        () => repo.getPlaylistsPage(
          any(),
          any(),
          favoriteOnly: any(named: 'favoriteOnly'),
        ),
      ).thenThrow(StateError('x'));
      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);
      final result = await container.read(favoritePlaylistsProvider.future);
      expect(result, isEmpty);
      expect(container.read(favoritePlaylistsLoadFailedProvider), isTrue);
    });
  });

  group('playlistDetailProvider', () {
    test('成功: 返回详情并写入缓存', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      final detail = _pl('d1', songCount: 5);
      when(() => repo.getPlaylist('d1')).thenAnswer((_) async => detail);
      when(() => cache.cachePlaylistDetail(any(), any()))
          .thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);

      final result =
          await container.read(playlistDetailProvider('d1').future);
      expect(result?.id, 'd1');
      expect(container.read(playlistDetailLoadFailedProvider('d1')), isFalse);
    });

    test('仓库为 null → null', () async {
      final cache = _FakeMetadataCache();
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          playlistRepositoryProvider.overrideWith((ref) => null),
          metadataCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);
      final result =
          await container.read(playlistDetailProvider('d1').future);
      expect(result, isNull);
    });

    test('远程返回 null → null(无缓存)', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(() => repo.getPlaylist('d1')).thenAnswer((_) async => null);
      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);
      final result =
          await container.read(playlistDetailProvider('d1').future);
      expect(result, isNull);
    });

    test('远程失败 + 缓存命中 → 静默兜底返回缓存', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(() => repo.getPlaylist('d1')).thenThrow(StateError('offline'));
      when(() => cache.getPlaylistDetail(any(), any()))
          .thenAnswer((_) async => _pl('cached', songCount: 3));
      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);
      final result =
          await container.read(playlistDetailProvider('d1').future);
      expect(result?.id, 'cached');
      expect(container.read(playlistDetailLoadFailedProvider('d1')), isFalse);
    });

    test('远程失败 + 缓存未命中 → 标记失败并返回 null', () async {
      final repo = _FakePlaylistRepository();
      final cache = _FakeMetadataCache();
      when(() => repo.getPlaylist('d1')).thenThrow(StateError('offline'));
      when(() => cache.getPlaylistDetail(any(), any()))
          .thenAnswer((_) async => null);
      final container = ProviderContainer(
        overrides: _commonOverrides(repo: repo, cache: cache),
      );
      addTearDown(container.dispose);
      final result =
          await container.read(playlistDetailProvider('d1').future);
      expect(result, isNull);
      expect(container.read(playlistDetailLoadFailedProvider('d1')), isTrue);
    });
  });
}
