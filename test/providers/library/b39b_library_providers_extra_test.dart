// b39b —— Route B：library / offline / api provider 剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * playlist_provider.dart:122   recentPlaylists 缓存读取闭包（远程失败兜底）
//   * playlist_provider.dart:139   playlists 无活跃库时回落 getLastLibraryId
//   * playlist_provider.dart:151/155 playlists 仓库/库不可用 → 记日志返回空
//   * playlist_provider.dart:165   playlists 缓存读取闭包
//   * recommend_provider.dart:16/17 recommendRepositoryProvider 有活跃库时建仓
//   * recommend_provider.dart:142  homeRecommendSection 固定卡拉取失败兜底
//   * music_provider.dart:328      searchProvider query 非空且无 repository 时复位失败标记
//   * offline_provider.dart:33     已探测地址 failed → 判离线
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

import '../../helpers/mocks.dart';

class MockPlaylistRepository extends Mock implements PlaylistRepository {}

class MockMetadataCacheRepository extends Mock
    implements MetadataCacheRepository {}

class MockRecommendRepository extends Mock implements RecommendRepository {}

class MockConnectivityMonitor extends Mock implements ConnectivityMonitor {}

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

Playlist _playlist(String id) => Playlist(
      id: id,
      name: '歌单$id',
      songCount: 3,
      duration: 120,
      changed: DateTime(2024, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recentPlaylistsProvider 缓存兜底', () {
    test('远程失败 → cacheRead 读缓存（line 122）', () async {
      final repo = MockPlaylistRepository();
      final cache = MockMetadataCacheRepository();
      // b42:recentPlaylists 已改为服务端分页 size=50,fetch 换签名、
      // 缓存读写换 recent 专用 scope;本用例改为钉「recent 缓存缺失 →
      // 回退旧全量缓存兜底」路径,原意(远程失败回落缓存)不变。
      when(() => repo.getPlaylists(size: 50)).thenThrow(StateError('offline'));
      when(() => cache.cacheRecentPlaylists(any(), any()))
          .thenAnswer((_) async {});
      when(() => cache.getRecentPlaylists('lib-1'))
          .thenAnswer((_) async => null);
      when(() => cache.getPlaylists('lib-1')).thenAnswer(
        (_) async => <Playlist>[_playlist('p1')],
      );

      final container = ProviderContainer(
        overrides: <Override>[
          playlistRepositoryProvider.overrideWithValue(repo),
          metadataCacheRepositoryProvider.overrideWithValue(cache),
          activeLibraryProvider.overrideWithValue(_library()),
          ensureActiveAddressProvider.overrideWith((ref) async => _address()),
        ],
      );
      addTearDown(container.dispose);

      container.listen(recentPlaylistsProvider, (_, _) {});
      final recent = await container.read(recentPlaylistsProvider.future);
      expect(recent.map((p) => p.id), <String>['p1']);
      verify(() => cache.getPlaylists('lib-1')).called(1);
    });
  });

  group('playlistsProvider 分支', () {
    test('无活跃库 → getLastLibraryId 回落（line 139）后仓库缺失 → 返回空（line 151/155）',
        () async {
      final cache = MockMetadataCacheRepository();
      when(() => cache.getLastLibraryId()).thenAnswer((_) async => null);
      when(() => cache.getPlaylists(any())).thenAnswer((_) async => null);

      final container = ProviderContainer(
        overrides: <Override>[
          metadataCacheRepositoryProvider.overrideWithValue(cache),
          activeLibraryProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container.listen(playlistsProvider, (_, _) {});
      final result = await container.read(playlistsProvider.future);
      expect(result, isEmpty);
      verify(() => cache.getLastLibraryId()).called(1);
    });

    test('远程失败 → cacheRead 读缓存（line 165）', () async {
      final repo = MockPlaylistRepository();
      final cache = MockMetadataCacheRepository();
      when(() => repo.getPlaylists()).thenThrow(StateError('offline'));
      when(() => cache.cachePlaylists(any(), any())).thenAnswer((_) async {});
      when(() => cache.getPlaylists('lib-1')).thenAnswer(
        (_) async => <Playlist>[_playlist('p2'), _playlist('p3')],
      );

      final container = ProviderContainer(
        overrides: <Override>[
          playlistRepositoryProvider.overrideWithValue(repo),
          metadataCacheRepositoryProvider.overrideWithValue(cache),
          activeLibraryProvider.overrideWithValue(_library()),
          ensureActiveAddressProvider.overrideWith((ref) async => _address()),
        ],
      );
      addTearDown(container.dispose);

      container.listen(playlistsProvider, (_, _) {});
      final result = await container.read(playlistsProvider.future);
      expect(result.map((p) => p.id), <String>['p2', 'p3']);
      verify(() => cache.getPlaylists('lib-1')).called(1);
    });
  });

  group('recommendRepositoryProvider', () {
    test('有活跃库时构建 RecommendRepository（line 16/17）', () {
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library()),
          subsonicApiClientProvider.overrideWithValue(MockSubsonicApiClient()),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(recommendRepositoryProvider), isNotNull);
    });
  });

  group('homeRecommendSectionProvider', () {
    test('固定卡拉取失败 → catch 兜底（line 142）', () async {
      final repo = MockRecommendRepository();
      when(() => repo.getHomeCards()).thenThrow(StateError('boom'));

      final container = ProviderContainer(
        overrides: <Override>[
          recommendRepositoryProvider.overrideWithValue(repo),
          activeLibraryProvider.overrideWithValue(null),
          ensureActiveAddressProvider.overrideWith((ref) async => _address()),
          homePlaylistCountProvider.overrideWith((ref) async => 8),
        ],
      );
      addTearDown(container.dispose);

      container.listen(homeRecommendSectionProvider, (_, _) {});
      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.fixed, isEmpty);
      expect(section.random, isEmpty);
    });
  });

  group('searchProvider 无 repository', () {
    test('query 非空且无 repository → 复位失败标记并返回空（line 328）', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          musicRepositoryProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      // 预先初始化失败标记 provider，避免 D-036「构建期修改其他 provider」断言。
      container.read(searchLoadFailedProvider('q'));

      final provider = searchProvider('q');
      container.listen(provider, (_, _) {});
      final result = await container.read(provider.future);

      expect(result.isEmpty, isTrue);
      expect(container.read(searchLoadFailedProvider('q')), isFalse);
    });
  });

  group('isOfflineProvider', () {
    test('网络可用但已探测地址 failed → 判离线（line 33）', () {
      final monitor = MockConnectivityMonitor();
      when(() => monitor.currentNetworkType).thenReturn(NetworkType.wifi);

      final container = ProviderContainer(
        overrides: <Override>[
          connectivityMonitorProvider.overrideWithValue(monitor),
          activeAddressProvider.overrideWith(
            (ref) => _address(status: ServerAddressStatus.failed),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(isOfflineProvider), isTrue);
    });
  });
}
