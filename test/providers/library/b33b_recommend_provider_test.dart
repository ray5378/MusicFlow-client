import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/recommend_cache_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';

import '../../helpers/mocks.dart';

class _FakeRecommendRepository extends Mock implements RecommendRepository {}

class _FakeRecommendCache extends Mock implements RecommendCacheRepository {}

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
      // b42:homeCards/recommendChannels/localRecommend 接入 drift 缓存仓库,
      // 测试里用 mock 隔离(未 stub 的读取返回 null = 缓存未命中)。
      recommendCacheRepositoryProvider.overrideWith((ref) => _FakeRecommendCache()),
    ];

void main() {
  // homeCards 等失败路径会经 NetworkErrorNotifier → ToastNotifier 访问
  // WidgetsBinding,必须先初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

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
          recommendCacheRepositoryProvider.overrideWith(
            (ref) => _FakeRecommendCache(),
          ),
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
          recommendCacheRepositoryProvider.overrideWith(
            (ref) => _FakeRecommendCache(),
          ),
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

  group('homeRecommendSectionProvider（服务端聚合快照 /home/recommend-section）', () {
    HomeRecommendSection sectionOf({
      int hourBucket = 498541,
      int homeCount = 12,
      bool degraded = false,
      required List<HomeCard> fixed,
      required List<Playlist> random,
    }) =>
        HomeRecommendSection(
          hourBucket: hourBucket,
          homeCount: homeCount,
          degraded: degraded,
          fixed: fixed,
          random: random,
        );

    test('10 固定 + 2 随机原样透传：零门槛、不重排、不过滤', () async {
      final repo = _FakeRecommendRepository();
      // 240 实测口径：10 张固定卡（含 3 张 30 首，另有 1 张 10 首的极端值）。
      final fixed = <HomeCard>[
        _card('pl-daily-roam', 4142),
        _card('pl-daily-today', 779),
        _card('pl-daily-local', 500),
        _card('pl-random-songs', 369),
        _card('qq-today', 30),
        _card('netease-today', 30),
        _card('kugou-today', 30),
        _card('netease-history', 574),
        _card('qq-history', 300),
        // 极端值：10 首。旧实现的 `>30` / `<30` 门槛必杀这张，新契约必须保留。
        _card('kugou-history', 10),
      ];
      final random = <Playlist>[_playlist('pl-a', 303), _playlist('pl-b', 12)];
      when(() => repo.getHomeRecommendSection()).thenAnswer(
        (_) async => sectionOf(fixed: fixed, random: random),
      );

      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.fixed.length, 10, reason: '固定卡必须零门槛原样透传');
      expect(
        section.fixed.map((c) => c.playlistId).toList(),
        fixed.map((c) => c.playlistId).toList(),
        reason: '服务端顺序即展示顺序，客户端不得重排',
      );
      expect(
        section.fixed.where((c) => c.songCount == 30).length,
        3,
        reason: '30 首的卡在旧实现的 >30 门槛下会被误杀，现在必须保留',
      );
      expect(section.fixed.any((c) => c.songCount == 10), isTrue,
          reason: '10 首的极端卡也必须原样透传，客户端零门槛');
      final songCounts = section.fixed.map((c) => c.songCount).toList()
        ..sort();
      expect(songCounts.first, 10,
          reason: '客户端不再做任何 songCount 过滤：最小的一张也必须保留');
      expect(
        section.random.map((p) => p.id).toList(),
        <String>['pl-a', 'pl-b'],
        reason: '随机补位由服务端洗好牌，客户端不得再 shuffle',
      );
      expect(section.homeCount, 12);
      expect(section.hourBucket, 498541);
      expect(section.degraded, isFalse);
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
      // 旧链路的两次往返（home-cards + 4 页 playlists）必须彻底消失。
      verifyNever(() => repo.getHomeCards());
    });

    test('请求抛异常 → 空区块 + homeCardsLoadFailedProvider 置 true', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeRecommendSection())
          .thenThrow(StateError('aggregate down'));

      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.isEmpty, isTrue);
      expect(container.read(homeCardsLoadFailedProvider), isTrue,
          reason: '首屏这条链以前永不置位，UI 无法区分「没卡」与「加载失败」');
    });

    test('成功 → 把上一次的失败标记清掉', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeRecommendSection()).thenAnswer(
        (_) async => sectionOf(
          fixed: <HomeCard>[_card('c1', 50)],
          random: <Playlist>[],
        ),
      );

      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);
      container.read(homeCardsLoadFailedProvider.notifier).state = true;

      await container.read(homeRecommendSectionProvider.future);
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });

    test('仓库为 null → 空区块且不置失败标记', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(_lib()),
          recommendRepositoryProvider.overrideWith((ref) => null),
          recommendCacheRepositoryProvider.overrideWith(
            (ref) => _FakeRecommendCache(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.isEmpty, isTrue);
      expect(container.read(homeCardsLoadFailedProvider), isFalse,
          reason: '仓库未就绪不算加载失败，不该让 UI 出错误态');
    });

    test('地址未就绪 → 空区块且不计入固定卡失败', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeRecommendSection()).thenAnswer(
        (_) async => sectionOf(
          fixed: <HomeCard>[_card('c1', 50)],
          random: <Playlist>[],
        ),
      );

      final container = ProviderContainer(
        overrides: <Override>[
          ..._baseOverrides(repo: repo),
          ensureActiveAddressProvider.overrideWith(
            (ref) async => throw StateError('no active address'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.isEmpty, isTrue);
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
      verifyNever(() => repo.getHomeRecommendSection());
    });

    test('playlistId 为空的坏卡被过滤，其余卡顺序不变', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeRecommendSection()).thenAnswer(
        (_) async => sectionOf(
          degraded: true,
          fixed: <HomeCard>[
            _card('c1', 50),
            _card('', 30), // 插件数据缺陷：没有 playlistId
            _card('c2', 10),
          ],
          random: <Playlist>[_playlist('p1', 40)],
        ),
      );

      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(
        section.fixed.map((c) => c.playlistId).toList(),
        <String>['c1', 'c2'],
      );
      expect(section.random.single.id, 'p1');
      expect(section.degraded, isTrue, reason: '过滤坏卡不应改写服务端的 degraded');
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });

    test('HomeCard.fromJson 收到 playlistId:null → 不崩、被 provider 过滤并 warn',
        () async {
      final repo = _FakeRecommendRepository();
      // 走真实反序列化路径，确保硬 cast 已被容错替换。
      final parsed = HomeRecommendSection.fromJson(<String, dynamic>{
        'hourBucket': 498541,
        'homeCount': 12,
        'degraded': true,
        'fixed': <dynamic>[
          <String, dynamic>{'playlistId': 'c1', 'name': '好卡', 'songCount': 50},
          <String, dynamic>{'playlistId': null, 'name': '坏卡', 'songCount': 30},
          <String, dynamic>{'playlistId': 'c2', 'name': '好卡2', 'songCount': 10},
        ],
        'random': <dynamic>[],
      });
      expect(parsed.fixed[1].playlistId, isEmpty, reason: '空串而非 CastError');
      when(() => repo.getHomeRecommendSection())
          .thenAnswer((_) async => parsed);

      Logger.setLoggingEnabled(true);
      Logger.clearBuffer();
      addTearDown(() {
        Logger.setLoggingEnabled(false);
        Logger.clearBuffer();
      });

      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.fixed.map((c) => c.playlistId).toList(),
          <String>['c1', 'c2']);
      expect(
        Logger.exportLogs(),
        contains('drop home card without playlistId'),
        reason: '坏卡被丢弃时必须留痕，不能静默',
      );
      expect(container.read(homeCardsLoadFailedProvider), isFalse);
    });

    test('degraded=true 且固定卡全失效 → 透传空 fixed 供 UI 走错误分支', () async {
      final repo = _FakeRecommendRepository();
      when(() => repo.getHomeRecommendSection()).thenAnswer(
        (_) async => sectionOf(
          degraded: true,
          fixed: <HomeCard>[],
          random: <Playlist>[_playlist('p1', 40)],
        ),
      );

      final container = ProviderContainer(overrides: _baseOverrides(repo: repo));
      addTearDown(container.dispose);

      final section = await container.read(homeRecommendSectionProvider.future);
      expect(section.degraded, isTrue);
      expect(section.fixed, isEmpty);
      expect(section.isEmpty, isFalse,
          reason: '还有随机补位时 isEmpty 为 false —— UI 判定必须靠 degraded');
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
