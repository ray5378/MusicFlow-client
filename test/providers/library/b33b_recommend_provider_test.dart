import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';

import '../../helpers/mocks.dart';

class _FakeRecommendRepository extends Mock implements RecommendRepository {}

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

Playlist _playlist(String id, int songCount) => Playlist(
      id: id,
      name: 'PL $id',
      songCount: songCount,
      duration: 0,
    );

HomeCard _card(String id, int songCount) => HomeCard(
      playlistId: id,
      name: 'Card $id',
      playlistName: 'Card $id',
      position: 0,
      isCombo: false,
      songCount: songCount,
    );

List<Override> _baseOverrides({
  required _FakeRecommendRepository repo,
}) =>
    <Override>[
      activeLibraryProvider.overrideWithValue(_lib()),
      activeAddressProvider.overrideWith((ref) => _addr()),
      recommendRepositoryProvider.overrideWith((ref) => repo),
    ];

void main() {
  group('homeSectionsProvider', () {
    test('成功: 返回分区清单', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeSections())
          .thenAnswer((_) async => <HomeSection>[
                HomeSection(key: 'k', title: 't', sortOrder: 1, visible: true),
              ]);
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final sections = await container.read(homeSectionsProvider.future);
      expect(sections.single.key, 'k');
    });

    test('仓库为 null → 空清单', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          recommendRepositoryProvider.overrideWith((ref) => null),
        ],
      );
      addTearDown(container.dispose);
      final sections = await container.read(homeSectionsProvider.future);
      expect(sections, isEmpty);
    });

    test('加载失败 → 回落空清单', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeSections()).thenThrow(StateError('x'));
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final sections = await container.read(homeSectionsProvider.future);
      expect(sections, isEmpty);
    });
  });

  group('homeCardsProvider', () {
    test('成功: 返回卡片并清失败标记', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeCards())
          .thenAnswer((_) async => <HomeCard>[_card('c1', 50)]);
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final cards = await container.read(homeCardsProvider.future);
      expect(cards.single.playlistId, 'c1');
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });

    test('加载失败 → 空卡片并置失败标记', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeCards()).thenThrow(StateError('x'));
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final cards = await container.read(homeCardsProvider.future);
      expect(cards, isEmpty);
      expect(container.read(homeCardsLoadFailedProvider), isTrue);
    });

    test('仓库为 null → 空卡片', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          recommendRepositoryProvider.overrideWith((ref) => null),
        ],
      );
      addTearDown(container.dispose);
      final cards = await container.read(homeCardsProvider.future);
      expect(cards, isEmpty);
    });
  });

  group('recommendChannelsProvider', () {
    test('成功: 返回平台推荐结果', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getRecommend()).thenAnswer(
        (_) async => RecommendResult(
          providerId: 'prov-1',
          channels: <RecommendChannel>[],
        ),
      );
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final result = await container.read(recommendChannelsProvider.future);
      expect(result.providerId, 'prov-1');
      expect(container.read(recommendChannelsLoadFailedProvider), isFalse);
    });

    test('加载失败 → 空结果并置失败标记', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getRecommend()).thenThrow(StateError('x'));
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final result = await container.read(recommendChannelsProvider.future);
      expect(result.providerId, '');
      expect(result.channels, isEmpty);
      expect(container.read(recommendChannelsLoadFailedProvider), isTrue);
    });

    test('仓库为 null → 空结果', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          recommendRepositoryProvider.overrideWith((ref) => null),
        ],
      );
      addTearDown(container.dispose);
      final result = await container.read(recommendChannelsProvider.future);
      expect(result.providerId, '');
    });
  });

  group('recommendProviderIdProvider', () {
    test('由 recommendChannelsProvider 暴露 providerId', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getRecommend()).thenAnswer(
        (_) async => RecommendResult(
          providerId: 'prov-x',
          channels: <RecommendChannel>[],
        ),
      );
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      await container.read(recommendChannelsProvider.future);
      final id = container.read(recommendProviderIdProvider).value;
      expect(id, 'prov-x');
    });
  });

  group('homePlaylistCountProvider', () {
    test('成功: 返回服务端配置的歌单数', () async {
      final api = MockSubsonicApiClient();
      when(() => api.getRaw(any()))
          .thenAnswer((_) async => <String, dynamic>{'count': 12});
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          subsonicApiClientProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(homePlaylistCountProvider.future), 12);
    });

    test('请求失败 → 回落默认 8', () async {
      final api = MockSubsonicApiClient();
      when(() => api.getRaw(any())).thenThrow(StateError('x'));
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          activeAddressProvider.overrideWith((ref) => _addr()),
          subsonicApiClientProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(homePlaylistCountProvider.future), 8);
    });
  });

  group('homeRecommendSectionProvider', () {
    test('固定卡 >30 首入选, 随机补位排除固定卡与 <30 首, 补足到 homeCount', () async {
      final repo = _FakeRecommendRepository();
      // 固定卡: cA(50 首, 入选) / cB(10 首, 门槛以下排除)。
      when(() => repo.getHomeCards()).thenAnswer(
        (_) async => <HomeCard>[_card('cA', 50), _card('cB', 10)],
      );

      final plRepo = _FakePlaylistRepository();
      // 本地随机池: p1/p2(>=30 入选) / p3(<30 排除)。
      when(() => plRepo.getPlaylistsPage(any(), any(),
          query: any(named: 'query'))).thenAnswer(
        (_) async => (
          items: <Playlist>[
            _playlist('p1', 40),
            _playlist('p2', 40),
            _playlist('p3', 20),
          ],
          total: 3,
        ),
      );

      final container = ProviderContainer(
        overrides: <Override>[
          ..._baseOverrides(repo: repo),
          playlistRepositoryProvider.overrideWith((ref) => plRepo),
          // homeCount 默认 8; needed = 8 - 1 = 7, 但池里只有 2 张可用 → 取 2。
          homePlaylistCountProvider.overrideWith((ref) async => 8),
        ],
      );
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.fixed.map((c) => c.playlistId).toList(), <String>['cA']);
      expect(section.random.length, 2);
      expect(
        section.random.map((p) => p.id).toList(),
        containsAll(<String>['p1', 'p2']),
      );
      expect(section.random.any((p) => p.id == 'p3'), isFalse);
    });

    test('固定卡已满足 homeCount → 随机补位为空', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeCards()).thenAnswer(
        (_) async => <HomeCard>[_card('cA', 50), _card('cB', 50)],
      );
      final plRepo = _FakePlaylistRepository();
      when(() => plRepo.getPlaylistsPage(any(), any(),
          query: any(named: 'query'))).thenAnswer(
        (_) async => (
          items: <Playlist>[_playlist('p1', 40)],
          total: 1,
        ),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          ..._baseOverrides(repo: repo),
          playlistRepositoryProvider.overrideWith((ref) => plRepo),
          homePlaylistCountProvider.overrideWith((ref) async => 2),
        ],
      );
      addTearDown(container.dispose);
      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.fixed.length, 2);
      expect(section.random, isEmpty);
    });

    test('仓库为 null → 固定与随机均为空', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          recommendRepositoryProvider.overrideWith((ref) => null),
          playlistRepositoryProvider.overrideWith((ref) => _FakePlaylistRepository()),
          homePlaylistCountProvider.overrideWith((ref) async => 8),
        ],
      );
      addTearDown(container.dispose);
      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.isEmpty, isTrue);
    });
  });

  group('localRecommendChannelsProvider', () {
    test('成功: 返回本地推荐频道', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getLocalRecommend()).thenAnswer(
        (_) async => <LocalRecommendChannel>[
          LocalRecommendChannel(
            source: 'netease',
            name: '网易云',
            count: 3,
            playlists: <LocalRecommendPlaylist>[],
          ),
        ],
      );
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final channels =
          await container.read(localRecommendChannelsProvider.future);
      expect(channels.single.source, 'netease');
      expect(container.read(localRecommendChannelsLoadFailedProvider), isFalse);
    });

    test('加载失败 → 空并置失败标记', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getLocalRecommend()).thenThrow(StateError('x'));
      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      final channels =
          await container.read(localRecommendChannelsProvider.future);
      expect(channels, isEmpty);
      expect(container.read(localRecommendChannelsLoadFailedProvider), isTrue);
    });
  });
}
