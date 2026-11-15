// 批 D-2 · 首页「全量 SWR」接线钉子（规格第 2 节改动 C / D）。
//
// 判据（照抄规格第 4 节）：
//   - 上表每个 provider 有缓存时**首帧 fetch 次数为 0** 且立即有内容；
//   - 无缓存时行为与改造前一致（走远程、只发 1 次）；
//   - `HomeRecommendSection` / `HomeSection` 的 `toJson → fromJson` 等值；
//   - 坏数据不炸；
//   - `homeRecommendSectionProvider` 的两条老业务规则（repo null / 空
//     playlistId 过滤）不许回归。
//
// 为什么「首帧 fetch == 0」是唯一有效的判据：`cacheFirst` 被漏传时，provider
// 依然会走「远程 + 缓存兜底」，行为看起来正常，只有首帧多打了一次远程请求 ——
// 这正好是用户抱怨的「打开时 7~8 成加载不出来」的成因，别处看不出来。

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/recommend_cache_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/fetch_with_cache_fallback.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';

import '../../helpers/mocks.dart';

class _MockRecommendRepository extends Mock implements RecommendRepository {}

class _MockRecommendCache extends Mock implements RecommendCacheRepository {}

MusicLibrary _library() => MusicLibrary(
      id: 'lib-1',
      name: '库',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

ServerAddress _address() => ServerAddress(
      id: 'addr-1',
      libraryId: 'lib-1',
      label: '主线路',
      url: 'http://127.0.0.1:1',
      priority: 0,
      status: ServerAddressStatus.ok,
    );

HomeCard _card(String id) => HomeCard(
      playlistId: id,
      name: 'card-$id',
      playlistName: '歌单$id',
      position: 0,
      isCombo: false,
      songCount: 42,
    );

Playlist _playlist(String id) => Playlist(
      id: id,
      name: 'PL $id',
      songCount: 7,
      duration: 120,
    );

HomeRecommendSection _section() => HomeRecommendSection(
      hourBucket: 498541,
      homeCount: 12,
      degraded: false,
      fixed: <HomeCard>[_card('c1'), _card('c2')],
      random: <Playlist>[_playlist('p1')],
    );

ProviderContainer _container({
  required _MockRecommendRepository repo,
  required _MockRecommendCache cache,
  MockSubsonicApiClient? api,
}) {
  return ProviderContainer(
    overrides: <Override>[
      activeLibraryProvider.overrideWithValue(_library()),
      activeAddressProvider.overrideWith((ref) => _address()),
      ensureActiveAddressProvider.overrideWith((ref) async => _address()),
      recommendRepositoryProvider.overrideWith((ref) => repo),
      recommendCacheRepositoryProvider.overrideWith((ref) => cache),
      if (api != null) subsonicApiClientProvider.overrideWithValue(api),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // mocktail：非原始类型参数的 `any()` 必须先登记一个兜底实例。
    registerFallbackValue(<HomeCard>[]);
    registerFallbackValue(<LocalRecommendChannel>[]);
    registerFallbackValue(<HomeSection>[]);
    registerFallbackValue(<Playlist>[]);
    registerFallbackValue(const HomeRecommendSection.empty());
    registerFallbackValue(RecommendResult(providerId: '', channels: const []));
  });

  setUp(() {
    NetworkErrorNotifier.resetForTest();
    resetRefreshGateForTest();
    refreshClockForTest = DateTime.now;
  });

  tearDown(() {
    NetworkErrorNotifier.resetForTest();
    resetRefreshGateForTest();
  });

  group('有缓存：首帧零远程请求 + 立即有内容（SWR）', () {
    test('homeCardsProvider', () {
      fakeAsync((async) {
        final repo = _MockRecommendRepository();
        final cache = _MockRecommendCache();
        when(() => cache.getHomeCards('lib-1'))
            .thenAnswer((_) async => <HomeCard>[_card('cached')]);
        when(() => repo.getHomeCards())
            .thenAnswer((_) async => <HomeCard>[_card('remote')]);

        final container = _container(repo: repo, cache: cache);
        addTearDown(container.dispose);
        final sub = container.listen(homeCardsProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(container.read(homeCardsProvider).valueOrNull?.single.playlistId,
            'cached');
        verifyNever(() => repo.getHomeCards());
      });
    });

    test('recommendChannelsProvider', () {
      fakeAsync((async) {
        final repo = _MockRecommendRepository();
        final cache = _MockRecommendCache();
        when(() => cache.getRecommendResult('lib-1')).thenAnswer(
          (_) async => RecommendResult(providerId: 'cached-prov', channels: []),
        );
        when(() => repo.getRecommend()).thenAnswer(
          (_) async => RecommendResult(providerId: 'remote-prov', channels: []),
        );

        final container = _container(repo: repo, cache: cache);
        addTearDown(container.dispose);
        final sub = container.listen(recommendChannelsProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(
          container.read(recommendChannelsProvider).valueOrNull?.providerId,
          'cached-prov',
        );
        verifyNever(() => repo.getRecommend());
      });
    });

    test('localRecommendChannelsProvider', () {
      fakeAsync((async) {
        final repo = _MockRecommendRepository();
        final cache = _MockRecommendCache();
        when(() => cache.getLocalRecommendChannels('lib-1')).thenAnswer(
          (_) async => <LocalRecommendChannel>[_channel('cached')],
        );
        when(() => repo.getLocalRecommend()).thenAnswer(
          (_) async => <LocalRecommendChannel>[_channel('remote')],
        );

        final container = _container(repo: repo, cache: cache);
        addTearDown(container.dispose);
        final sub =
            container.listen(localRecommendChannelsProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(
          container
              .read(localRecommendChannelsProvider)
              .valueOrNull
              ?.single
              .source,
          'cached',
        );
        verifyNever(() => repo.getLocalRecommend());
      });
    });

    test('homeRecommendSectionProvider', () {
      fakeAsync((async) {
        final repo = _MockRecommendRepository();
        final cache = _MockRecommendCache();
        when(() => cache.getHomeRecommendSection('lib-1'))
            .thenAnswer((_) async => _section());
        when(() => repo.getHomeRecommendSection())
            .thenAnswer((_) async => const HomeRecommendSection.empty());

        final container = _container(repo: repo, cache: cache);
        addTearDown(container.dispose);
        final sub =
            container.listen(homeRecommendSectionProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(
          container.read(homeRecommendSectionProvider).valueOrNull?.fixed.length,
          2,
        );
        verifyNever(() => repo.getHomeRecommendSection());
      });
    });

    test('homeSectionsProvider', () {
      fakeAsync((async) {
        final repo = _MockRecommendRepository();
        final cache = _MockRecommendCache();
        when(() => cache.getHomeSections('lib-1')).thenAnswer(
          (_) async => <HomeSection>[
            HomeSection(key: 'cached-key', title: 't', sortOrder: 1, visible: true),
          ],
        );
        when(() => repo.getHomeSections())
            .thenAnswer((_) async => <HomeSection>[]);

        final container = _container(repo: repo, cache: cache);
        addTearDown(container.dispose);
        final sub = container.listen(homeSectionsProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(
          container.read(homeSectionsProvider).valueOrNull?.single.key,
          'cached-key',
        );
        verifyNever(() => repo.getHomeSections());
      });
    });

    test('homePlaylistCountProvider', () {
      fakeAsync((async) {
        final repo = _MockRecommendRepository();
        final cache = _MockRecommendCache();
        final api = MockSubsonicApiClient();
        when(() => cache.getHomePlaylistCount('lib-1'))
            .thenAnswer((_) async => 13);
        when(() => api.getRaw(any()))
            .thenAnswer((_) async => <String, dynamic>{'count': 8});

        final container = _container(repo: repo, cache: cache, api: api);
        addTearDown(container.dispose);
        final sub = container.listen(homePlaylistCountProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(container.read(homePlaylistCountProvider).valueOrNull, 13);
        verifyNever(() => api.getRaw(any()));
      });
    });
  });

  group('无缓存：行为与改造前一致（走远程，只发 1 次）', () {
    test('homeCardsProvider 远程成功 → 写缓存', () async {
      final repo = _MockRecommendRepository();
      final cache = _MockRecommendCache();
      when(() => cache.getHomeCards('lib-1')).thenAnswer((_) async => null);
      when(() => repo.getHomeCards())
          .thenAnswer((_) async => <HomeCard>[_card('remote')]);
      when(() => cache.saveHomeCards('lib-1', any())).thenAnswer((_) async {});

      final container = _container(repo: repo, cache: cache);
      addTearDown(container.dispose);

      final cards = await container.read(homeCardsProvider.future);
      expect(cards.single.playlistId, 'remote');
      verify(() => repo.getHomeCards()).called(1);
      verify(() => cache.saveHomeCards('lib-1', any())).called(1);
    });

    test('homeRecommendSectionProvider 远程成功 → 写缓存（含改后的坏卡过滤）',
        () async {
      final repo = _MockRecommendRepository();
      final cache = _MockRecommendCache();
      when(() => cache.getHomeRecommendSection('lib-1'))
          .thenAnswer((_) async => null);
      when(() => repo.getHomeRecommendSection())
          .thenAnswer((_) async => _section());
      when(() => cache.saveHomeRecommendSection('lib-1', any()))
          .thenAnswer((_) async {});

      final container = _container(repo: repo, cache: cache);
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.fixed.length, 2);
      verify(() => repo.getHomeRecommendSection()).called(1);
      verify(() => cache.saveHomeRecommendSection('lib-1', any())).called(1);
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });

    test('空快照不算「有缓存」：远程回空区块不会被当成缓存秒出', () async {
      fakeAsync((async) {
        final repo = _MockRecommendRepository();
        final cache = _MockRecommendCache();
        // 缓存里是一份「空快照」（曾经远程回空时写下的）。
        when(() => cache.getHomeRecommendSection('lib-1'))
            .thenAnswer((_) async => const HomeRecommendSection.empty());
        when(() => repo.getHomeRecommendSection())
            .thenAnswer((_) async => _section());

        final container = _container(repo: repo, cache: cache);
        addTearDown(container.dispose);
        final sub =
            container.listen(homeRecommendSectionProvider, (_, _) {});
        addTearDown(sub.close);

        async.flushMicrotasks();
        expect(
          container.read(homeRecommendSectionProvider).valueOrNull?.fixed.length,
          2,
          reason: '空快照当缓存会让固定卡永远回不来',
        );
        verify(() => repo.getHomeRecommendSection()).called(1);
      });
    });
  });

  group('homeRecommendSectionProvider 老业务规则（不回归）', () {
    test('repo == null → 空区块且不置失败标记', () async {
      final cache = _MockRecommendCache();
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library()),
          ensureActiveAddressProvider.overrideWith((ref) async => _address()),
          recommendRepositoryProvider.overrideWith((ref) => null),
          recommendCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.isEmpty, isTrue);
      expect(container.read(homeCardsLoadFailedProvider), isFalse,
          reason: '仓库未就绪不算加载失败，不该让 UI 出错误态');
      verifyNever(() => cache.getHomeRecommendSection(any()));
    });

    test('地址未就绪 → 空区块且不计入固定卡失败', () async {
      final repo = _MockRecommendRepository();
      final cache = _MockRecommendCache();
      when(() => cache.getHomeRecommendSection('lib-1'))
          .thenAnswer((_) async => null);

      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_library()),
          activeAddressProvider.overrideWith((ref) => _address()),
          ensureActiveAddressProvider.overrideWith(
            (ref) async => throw StateError('no active address'),
          ),
          recommendRepositoryProvider.overrideWith((ref) => repo),
          recommendCacheRepositoryProvider.overrideWith((ref) => cache),
        ],
      );
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.isEmpty, isTrue);
      expect(container.read(homeCardsLoadFailedProvider), isFalse,
          reason: '地址失败不算加载失败（老口径）');
      verifyNever(() => repo.getHomeRecommendSection());
    });

    test('playlistId 为空的坏卡被过滤 + 留痕，degraded 原样透传', () async {
      final repo = _MockRecommendRepository();
      final cache = _MockRecommendCache();
      when(() => cache.getHomeRecommendSection('lib-1'))
          .thenAnswer((_) async => null);
      when(() => repo.getHomeRecommendSection()).thenAnswer(
        (_) async => HomeRecommendSection(
          hourBucket: 1,
          homeCount: 3,
          degraded: true,
          fixed: <HomeCard>[_card('c1'), _card(''), _card('c2')],
          random: <Playlist>[_playlist('p1')],
        ),
      );
      when(() => cache.saveHomeRecommendSection('lib-1', any()))
          .thenAnswer((_) async {});

      Logger.setLoggingEnabled(true);
      Logger.clearBuffer();
      addTearDown(() {
        Logger.setLoggingEnabled(false);
        Logger.clearBuffer();
      });

      final container = _container(repo: repo, cache: cache);
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.fixed.map((c) => c.playlistId).toList(),
          <String>['c1', 'c2']);
      expect(section.degraded, isTrue, reason: '过滤坏卡不改写服务端的 degraded');
      expect(Logger.exportLogs(),
          contains('drop home card without playlistId'));
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });
  });

  group('缓存往返 / 坏数据', () {
    test('HomeRecommendSection toJson → fromJson 严格互逆', () {
      final section = HomeRecommendSection(
        hourBucket: 498541,
        homeCount: 12,
        degraded: true,
        fixed: <HomeCard>[
          HomeCard(
            playlistId: 'c1',
            name: '名字',
            playlistName: '歌单名',
            position: 3,
            isCombo: true,
            songCount: 50,
            coverArt: 'ca-1',
            missing: true,
          ),
        ],
        random: <Playlist>[
          Playlist(
            id: 'p1',
            name: '随机歌单',
            songCount: 7,
            duration: 120,
            coverArt: 'cover-1',
          ),
        ],
      );

      // 走一遍真 JSON 编解码：这才是 drift 里存的东西。
      final json =
          jsonDecode(jsonEncode(section.toJson())) as Map<String, dynamic>;
      final back = HomeRecommendSection.fromJson(json);

      expect(back.hourBucket, 498541);
      expect(back.homeCount, 12);
      expect(back.degraded, isTrue);
      expect(back.fixed.single.playlistId, 'c1');
      expect(back.fixed.single.name, '名字');
      expect(back.fixed.single.playlistName, '歌单名');
      expect(back.fixed.single.position, 3);
      expect(back.fixed.single.isCombo, isTrue);
      expect(back.fixed.single.songCount, 50);
      expect(back.fixed.single.coverArt, 'ca-1');
      expect(back.fixed.single.missing, isTrue);
      expect(back.random.single.id, 'p1');
      expect(back.random.single.name, '随机歌单');
      expect(back.random.single.songCount, 7);
      expect(back.random.single.duration, 120);
      expect(back.random.single.coverArt, 'cover-1');
      // 二次往返必须稳定（否则缓存会逐次漂移）。
      expect(jsonEncode(back.toJson()), jsonEncode(section.toJson()));
    });

    test('HomeSection toJson → fromJson 严格互逆', () {
      const section = HomeSection(
        key: 'home-recommend',
        title: '为你推荐',
        sortOrder: 3,
        visible: false,
      );
      final json =
          jsonDecode(jsonEncode(section.toJson())) as Map<String, dynamic>;
      final back = HomeSection.fromJson(json);
      expect(back.key, 'home-recommend');
      expect(back.title, '为你推荐');
      expect(back.sortOrder, 3);
      expect(back.visible, isFalse);
      expect(jsonEncode(back.toJson()), jsonEncode(section.toJson()));
    });

    test('坏数据不炸：非 Map 条目 / 缺字段 / null 一律降级而不是抛错', () {
      final parsed = HomeRecommendSection.fromJson(<String, dynamic>{
        'hourBucket': null,
        'homeCount': null,
        'degraded': null,
        'fixed': <dynamic>[
          null,
          1,
          'not-a-map',
          <String, dynamic>{'playlistId': 'c1'},
        ],
        'random': <dynamic>[
          null,
          <String, dynamic>{'name': 'no-id'},
        ],
      });
      expect(parsed.hourBucket, 0);
      expect(parsed.homeCount, 0);
      expect(parsed.degraded, isFalse);
      expect(parsed.fixed.single.playlistId, 'c1');
      expect(parsed.fixed.single.name, isEmpty);
      expect(parsed.random.single.id, isEmpty);
      expect(parsed.random.single.name, 'no-id');
    });

    test('完全不是 Map 的载荷也不炸（fromJson 收到空 Map）', () {
      final parsed = HomeRecommendSection.fromJson(<String, dynamic>{});
      expect(parsed.isEmpty, isTrue);
      expect(parsed.hourBucket, 0);
    });
  });
}

LocalRecommendChannel _channel(String source) => LocalRecommendChannel(
      source: source,
      name: '平台$source',
      count: 1,
      playlists: <LocalRecommendPlaylist>[
        LocalRecommendPlaylist(id: 'p-$source', name: '歌单', songCount: 3),
      ],
    );
