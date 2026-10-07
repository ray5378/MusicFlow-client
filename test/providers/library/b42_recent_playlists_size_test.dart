// b42 —— recentPlaylistsProvider 服务端分页（size=50）行为钉子。
//
// 钉住：
//   1) fetch 走 repository.getPlaylists(size: 50)，不再全量；
//   2) cacheWrite 写 recent 专用缓存（cacheRecentPlaylists），
//      不再覆盖 playlistsProvider 的全量缓存（cachePlaylists）；
//   3) 远程失败回落 recent 缓存；recent 缓存缺失时回退旧全量缓存。
//
// 产品代码改动见 lib/providers/library/playlist_provider.dart、
// lib/data/repositories/playlist_repository.dart、metadata_cache_repository.dart。

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

class MockPlaylistRepository extends Mock implements PlaylistRepository {}

class MockMetadataCacheRepository extends Mock
    implements MetadataCacheRepository {}

MusicLibrary _library() => MusicLibrary(
      id: 'lib-1',
      name: '库',
      username: 'u',
      password: 'p',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

ServerAddress _address({ServerAddressStatus status = ServerAddressStatus.ok}) =>
    ServerAddress(
      id: 'addr-1',
      libraryId: 'lib-1',
      label: '主线路',
      url: 'http://127.0.0.1:1',
      priority: 0,
      status: status,
    );

Playlist _playlist(String id, {DateTime? changed}) => Playlist(
      id: id,
      name: '歌单$id',
      songCount: 3,
      duration: 120,
      changed: changed ?? DateTime(2024, 1, 1),
    );

ProviderContainer _container({
  required MockPlaylistRepository repo,
  required MockMetadataCacheRepository cache,
}) {
  return ProviderContainer(
    overrides: <Override>[
      playlistRepositoryProvider.overrideWithValue(repo),
      metadataCacheRepositoryProvider.overrideWithValue(cache),
      activeLibraryProvider.overrideWithValue(_library()),
      ensureActiveAddressProvider.overrideWith((ref) async => _address()),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // cacheRecentPlaylists 的 List 参数注册兜底相等性（mocktail 非原始类型）。
    registerFallbackValue(<Playlist>[]);
  });

  test('fetch 传 size=50，缓存写 recent 专用 scope、不动全量缓存', () async {
    final repo = MockPlaylistRepository();
    final cache = MockMetadataCacheRepository();
    when(() => repo.getPlaylists(size: 50)).thenAnswer(
      (_) async => [
        _playlist('p2', changed: DateTime(2024, 3, 1)),
        _playlist('p1', changed: DateTime(2024, 1, 1)),
      ],
    );
    when(() => cache.cacheRecentPlaylists(any(), any()))
        .thenAnswer((_) async {});

    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final result = await container.read(recentPlaylistsProvider.future);
    // 服务端已按 updatedAt 倒序返回,客户端仍按 changed 倒序取前 20。
    expect(result.map((p) => p.id), <String>['p2', 'p1']);

    verify(() => repo.getPlaylists(size: 50)).called(1);
    verify(() => cache.cacheRecentPlaylists('lib-1', any())).called(1);
    // 不再走全量接口、不再覆盖全量缓存。
    verifyNever(() => repo.getPlaylists());
    verifyNever(() => cache.cachePlaylists(any(), any()));
    expect(container.read(recentPlaylistsLoadFailedProvider), isFalse);
  });

  test('远程失败 → 回落 recent 缓存排序取前 20', () async {
    final repo = MockPlaylistRepository();
    final cache = MockMetadataCacheRepository();
    when(() => repo.getPlaylists(size: 50)).thenThrow(StateError('offline'));
    when(() => cache.getRecentPlaylists('lib-1')).thenAnswer((_) async {
      return List.generate(
        25,
        (i) => _playlist('r$i', changed: DateTime(2024, 1, 1).add(Duration(days: i))),
      );
    });

    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final result = await container.read(recentPlaylistsProvider.future);
    expect(result, hasLength(20));
    // 倒序:最新的 r24 在最前。
    expect(result.first.id, 'r24');
    expect(container.read(recentPlaylistsLoadFailedProvider), isFalse);
  });

  test('recent 缓存缺失 → 回退旧全量缓存兜底（老版本升级兼容）', () async {
    final repo = MockPlaylistRepository();
    final cache = MockMetadataCacheRepository();
    when(() => repo.getPlaylists(size: 50)).thenThrow(StateError('offline'));
    when(() => cache.getRecentPlaylists('lib-1'))
        .thenAnswer((_) async => null);
    when(() => cache.getPlaylists('lib-1')).thenAnswer((_) async {
      return List.generate(
        22,
        (i) => _playlist('f$i', changed: DateTime(2024, 1, 1).add(Duration(days: i))),
      );
    });

    final container = _container(repo: repo, cache: cache);
    addTearDown(container.dispose);

    final result = await container.read(recentPlaylistsProvider.future);
    expect(result, hasLength(20));
    expect(result.first.id, 'f21');
  });
}
