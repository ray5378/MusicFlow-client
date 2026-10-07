// b42 —— 发现页三个推荐类 provider 接入 fetchWithCacheFallback 的行为钉子。
//
// 钉住「远程成功写缓存 / 远程失败回落缓存 / 全失败置失败标记 / 无活跃库回空」
// 四类行为（参考范式：b39b_library_providers_extra_test.dart）。
//
// 产品代码改动见 lib/providers/library/recommend_provider.dart。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/recommend_cache_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';

class MockRecommendRepository extends Mock implements RecommendRepository {}

class MockRecommendCacheRepository extends Mock
    implements RecommendCacheRepository {}

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

HomeCard _card(String id) => HomeCard(
      playlistId: id,
      name: 'card-$id',
      playlistName: '歌单$id',
      position: 0,
      isCombo: false,
      songCount: 42,
    );

LocalRecommendChannel _channel(String source) => LocalRecommendChannel(
      source: source,
      name: '平台$source',
      count: 1,
      playlists: [
        LocalRecommendPlaylist(id: 'p-$source', name: '歌单', songCount: 3),
      ],
    );

ProviderContainer _container({
  required RecommendRepository? repository,
  required MockRecommendCacheRepository cache,
  MusicLibrary? library,
  bool noLibrary = false,
}) {
  return ProviderContainer(
    overrides: <Override>[
      recommendRepositoryProvider.overrideWithValue(repository),
      recommendCacheRepositoryProvider.overrideWithValue(cache),
      activeLibraryProvider.overrideWithValue(noLibrary ? null : (library ?? _library())),
      ensureActiveAddressProvider.overrideWith((ref) async => _address()),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // mocktail 非原始类型参数需要兜底值。
    registerFallbackValue(
      RecommendResult(providerId: '', channels: const []),
    );
    registerFallbackValue(<HomeCard>[]);
    registerFallbackValue(<LocalRecommendChannel>[]);
    registerFallbackValue(<RecommendChannel>[]);
  });

  group('homeCardsProvider 缓存三件套', () {
    test('远程成功 → 写缓存、失败标记复位', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getHomeCards()).thenAnswer((_) async => [_card('c1')]);
      when(() => cache.saveHomeCards(any(), any())).thenAnswer((_) async {});

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final cards = await container.read(homeCardsProvider.future);
      expect(cards.map((c) => c.playlistId), <String>['c1']);
      verify(() => cache.saveHomeCards('lib-1', any())).called(1);
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });

    test('远程失败 → 回落缓存且失败标记复位', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getHomeCards()).thenThrow(StateError('offline'));
      when(() => cache.getHomeCards('lib-1'))
          .thenAnswer((_) async => [_card('cached')]);

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final cards = await container.read(homeCardsProvider.future);
      expect(cards.map((c) => c.playlistId), <String>['cached']);
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });

    test('远程失败 + 缓存未命中 → 空列表 + 失败标记置位', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getHomeCards()).thenThrow(StateError('offline'));
      when(() => cache.getHomeCards('lib-1')).thenAnswer((_) async => null);

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final cards = await container.read(homeCardsProvider.future);
      expect(cards, isEmpty);
      expect(container.read(homeCardsLoadFailedProvider), isTrue);
    });
  });

  group('recommendChannelsProvider 缓存三件套', () {
    test('远程成功 → 写缓存（含 providerId）', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getRecommend()).thenAnswer(
        (_) async => RecommendResult(providerId: 'netease', channels: []),
      );
      when(() => cache.saveRecommendResult(any(), any()))
          .thenAnswer((_) async {});

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final result = await container.read(recommendChannelsProvider.future);
      expect(result.providerId, 'netease');
      verify(() => cache.saveRecommendResult('lib-1', any())).called(1);
      expect(container.read(recommendChannelsLoadFailedProvider), isFalse);
    });

    test('远程失败 → 回落缓存（providerId 保留）', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getRecommend()).thenThrow(StateError('offline'));
      when(() => cache.getRecommendResult('lib-1')).thenAnswer(
        (_) async => RecommendResult(providerId: 'qq', channels: []),
      );

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final result = await container.read(recommendChannelsProvider.future);
      expect(result.providerId, 'qq');
      expect(container.read(recommendChannelsLoadFailedProvider), isFalse);
    });

    test('远程失败 + 缓存未命中 → 空 Result + 失败标记置位', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getRecommend()).thenThrow(StateError('offline'));
      when(() => cache.getRecommendResult('lib-1'))
          .thenAnswer((_) async => null);

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final result = await container.read(recommendChannelsProvider.future);
      expect(result.providerId, '');
      expect(result.channels, isEmpty);
      expect(container.read(recommendChannelsLoadFailedProvider), isTrue);
    });
  });

  group('localRecommendChannelsProvider 缓存三件套', () {
    test('远程成功 → 写缓存', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getLocalRecommend())
          .thenAnswer((_) async => [_channel('netease')]);
      when(() => cache.saveLocalRecommendChannels(any(), any()))
          .thenAnswer((_) async {});

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final channels = await container.read(localRecommendChannelsProvider.future);
      expect(channels.map((c) => c.source), <String>['netease']);
      verify(() => cache.saveLocalRecommendChannels('lib-1', any())).called(1);
      expect(container.read(localRecommendChannelsLoadFailedProvider), isFalse);
    });

    test('远程失败 → 回落缓存', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getLocalRecommend()).thenThrow(StateError('offline'));
      when(() => cache.getLocalRecommendChannels('lib-1'))
          .thenAnswer((_) async => [_channel('qq')]);

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final channels = await container.read(localRecommendChannelsProvider.future);
      expect(channels.map((c) => c.source), <String>['qq']);
      expect(container.read(localRecommendChannelsLoadFailedProvider), isFalse);
    });

    test('远程失败 + 缓存未命中 → 空列表 + 失败标记置位', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();
      when(() => repo.getLocalRecommend()).thenThrow(StateError('offline'));
      when(() => cache.getLocalRecommendChannels('lib-1'))
          .thenAnswer((_) async => null);

      final container = _container(repository: repo, cache: cache);
      addTearDown(container.dispose);

      final channels = await container.read(localRecommendChannelsProvider.future);
      expect(channels, isEmpty);
      expect(container.read(localRecommendChannelsLoadFailedProvider), isTrue);
    });
  });

  group('无活跃库 null 回路（不回归）', () {
    test('activeLibrary 为 null → 返回空、不触达仓库与缓存', () async {
      final repo = MockRecommendRepository();
      final cache = MockRecommendCacheRepository();

      final container = _container(
        repository: repo,
        cache: cache,
        noLibrary: true,
      );
      addTearDown(container.dispose);

      expect(await container.read(homeCardsProvider.future), isEmpty);
      expect(await container.read(localRecommendChannelsProvider.future),
          isEmpty);
      final result = await container.read(recommendChannelsProvider.future);
      expect(result.providerId, '');
      verifyNever(() => repo.getHomeCards());
      verifyNever(() => repo.getRecommend());
      verifyNever(() => repo.getLocalRecommend());
      verifyNever(() => cache.getHomeCards(any()));
    });
  });
}
