// batch32 C 路 —— `lib/features/discover/pages/discover_page.dart` 播放辅助与宽屏头部补测。
//
// 分工（与既有 discover_page_test.dart / discover_page_cov_test.dart）：
//   * discover_page_test 打的是主页面骨架/清单驱动/编辑页/下拉刷新；
//   * discover_page_cov_test 打的是四个分区 widget 的渲染矩阵；
//   * 本文件打剩余缺口：
//     - `playLocalPlaylistById` 全分支（仓库缺 → 空歌单 → 成功含封面缓存与
//       queueOrigin 标记）；
//     - `_openRecommendPlaylist` 全分支（providerId 缺 → 已入库反查命中 → 反查
//       未命中走导入 → 导入失败 toast）；
//     - `_playRecommendPlaylist`（封面播放：未入库先导入再整队播 / 导入返回
//       空 id 不播）；
//     - `RecentPlaylistsSection` 的 ref.listen → offlineCacheDaemon 封面缓存；
//     - 宽屏(≥compact 断点)头部：`_HomeSearchEntry` 渲染与点击进搜索页、
//       Windows 平台标题为空时 header 收缩为 SizedBox.shrink。
//
// 踩坑记录（C 路约定）：
//   * NetworkErrorNotifier 有 20s 静态节流 → 失败分支一律只断言确定性副作用
//     （仓库被调过 / 播放器没被调），不断言提示 UI（#C5 同款）。
//   * showMusicFlowToast 走 rootOverlay，无节流，可以断言文本。
//   * 导入失败 toast 的文案带原始异常消息（Exception: 前缀被剥掉）→ 用
//     textContaining('boom') 断言最稳。
//   * 全页 pump 需要 mock SharedPreferences（homeSectionLayoutProvider 读
//     LocalStorage）+ override ensureActiveAddress / connectivityMonitor，
//     避免 200ms 探测定时器把用例挂住。

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/discover/pages/discover_page.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';
import 'package:musicflow_client/features/discover/widgets/category_nav_bar.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../player/test_player_notifier.dart';

class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer() : super(PlayerState());

  final List<List<String>> queues = <List<String>>[];
  final List<int> startIndices = <int>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    queues.add(songs.map((Song s) => s.id).toList());
    startIndices.add(startIndex);
  }
}

class FakePlaylistRepository extends PlaylistRepository {
  FakePlaylistRepository() : super(SubsonicApiClient(dio: Dio()));

  List<Song> songs = <Song>[];
  final List<String> getAllCalls = <String>[];

  @override
  Future<List<Song>> getAllPlaylistSongs(String playlistId) async {
    getAllCalls.add(playlistId);
    return songs;
  }
}

class FakeRecommendRepository extends RecommendRepository {
  FakeRecommendRepository() : super(SubsonicApiClient(dio: Dio()));

  String? importedId;
  String importResult = 'imported-1';
  Object? importError;
  final List<String> findCalls = <String>[];
  final List<Map<String, dynamic>> importInfos = <Map<String, dynamic>>[];

  @override
  Future<String?> findImportedPlaylistId(
    String providerId,
    String remoteId,
  ) async {
    findCalls.add(remoteId);
    return importedId;
  }

  @override
  Future<String> importRecommendPlaylist(
    String providerId,
    Map<String, dynamic> info,
  ) async {
    importInfos.add(info);
    if (importError != null) throw importError!;
    return importResult;
  }
}

class RecordingDaemon extends OfflineCacheDaemon {
  RecordingDaemon(super.ref);

  final List<String> covers = <String>[];

  @override
  Future<void> cachePlaylistCover(String coverKey, {String? playlistName}) async {
    covers.add(coverKey);
  }
}

AppLocalizations? _loc;

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 推进 playLocalPlaylistById 的 await 链（仓库取歌 → playEffectiveQueue）。
Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> pumpSection(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.devicePixelRatio = 1;
  // compact 宽度：封面播放按钮桌面端 hover 才显示，compact 常驻（可点）。
  tester.view.physicalSize = const Size(500, 1400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (BuildContext context, Widget? child) {
          _loc = AppLocalizations.of(context);
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  await settle(tester);
}

Playlist _pl(String name, {String? coverArt}) => Playlist(
  id: 'playlist-${name.hashCode}',
  name: name,
  songCount: 5,
  duration: 300,
  coverArt: coverArt,
);

RecommendPlaylist _rp(String id, String name, {bool imported = false}) =>
    RecommendPlaylist(
      id: id,
      source: 'netease',
      name: name,
      creator: '官方',
      trackCount: '10',
      link: '',
      imported: imported,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('playLocalPlaylistById · 最近歌单卡片播放', () {
    testWidgets('成功链路：仓库取歌 → 整队随机起播 → queueOrigin 标记歌单 → 封面写缓存', (
      tester,
    ) async {
      final plRepo = FakePlaylistRepository()
        ..songs = <Song>[
          Song(id: 'p1s1', title: '歌一', artist: 'A'),
          Song(id: 'p1s2', title: '歌二', artist: 'A'),
        ];
      final player = RecordingPlayer();
      RecordingDaemon? daemon;
      await pumpSection(
        tester,
        const RecentPlaylistsSection(),
        overrides: <Override>[
          recentPlaylistsProvider.overrideWith(
            (Ref ref) async => <Playlist>[_pl('最近歌单', coverArt: 'cover-rp1')],
          ),
          playlistRepositoryProvider.overrideWithValue(plRepo),
          offlineCacheDaemonProvider.overrideWith((Ref ref) {
            daemon = RecordingDaemon(ref);
            return daemon!;
          }),
          playerProvider.overrideWith((Ref ref) => player),
        ],
      );

      // ref.listen 在数据到达时也写一次封面缓存。
      expect(daemon!.covers, contains('cover-rp1'));

      await tester.tap(find.bySemanticsLabel('播放歌单'));
      await drain(tester);

      expect(player.queues, <List<String>>[
        <String>['p1s1', 'p1s2'],
      ]);
      final BuildContext ctx = tester.element(
        find.byType(RecentPlaylistsSection),
      );
      final QueueOrigin? origin = ProviderScope.containerOf(
        ctx,
      ).read(queueOriginProvider);
      expect(origin, isNotNull);
      expect(origin!.kind, QueueOriginKind.playlist);
      expect(origin.id, _pl('最近歌单', coverArt: 'cover-rp1').id);
      // 播放路径也写了一次封面缓存（listen + play 双路）。
      expect(daemon!.covers.where((String c) => c == 'cover-rp1').length,
          greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库为 null → 不产生播放（NetworkError 节流只断言副作用）', (tester) async {
      final player = RecordingPlayer();
      await pumpSection(
        tester,
        const RecentPlaylistsSection(),
        overrides: <Override>[
          recentPlaylistsProvider.overrideWith(
            (Ref ref) async => <Playlist>[_pl('无库歌单')],
          ),
          playerProvider.overrideWith((Ref ref) => player),
        ],
      );

      await tester.tap(find.bySemanticsLabel('播放歌单'));
      await drain(tester);

      expect(player.queues, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仓库返回空歌单 → 调过仓库但不播放', (tester) async {
      final plRepo = FakePlaylistRepository()..songs = const <Song>[];
      final player = RecordingPlayer();
      await pumpSection(
        tester,
        const RecentPlaylistsSection(),
        overrides: <Override>[
          recentPlaylistsProvider.overrideWith(
            (Ref ref) async => <Playlist>[_pl('空歌单')],
          ),
          playlistRepositoryProvider.overrideWithValue(plRepo),
          playerProvider.overrideWith((Ref ref) => player),
        ],
      );

      await tester.tap(find.bySemanticsLabel('播放歌单'));
      await drain(tester);

      expect(plRepo.getAllCalls, isNotEmpty);
      expect(player.queues, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点歌单卡本体 → 打开歌单详情页', (tester) async {
      await pumpSection(
        tester,
        const RecentPlaylistsSection(),
        overrides: <Override>[
          recentPlaylistsProvider.overrideWith(
            (Ref ref) async => <Playlist>[_pl('跳转歌单')],
          ),
        ],
      );

      await tester.tap(find.text('跳转歌单'));
      await settle(tester);

      expect(find.byType(PlaylistDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('_openRecommendPlaylist · 插件推荐卡片点击', () {
    testWidgets('providerId 为空 → toast「推荐服务不可用」且不跳转', (tester) async {
      await pumpSection(
        tester,
        const PlatformRecommendSection(),
        overrides: <Override>[
          recommendChannelsProvider.overrideWith(
            (Ref ref) async => RecommendResult(
              providerId: '',
              channels: <RecommendChannel>[
                RecommendChannel(
                  source: 'netease',
                  name: '频道',
                  count: 1,
                  playlists: <RecommendPlaylist>[_rp('r1', '无主歌单')],
                ),
              ],
            ),
          ),
          recommendProviderIdProvider.overrideWithValue(
            AsyncValue<String>.data(''),
          ),
        ],
      );

      await tester.tap(find.text('无主歌单'));
      await tester.pump();
      await tester.pump();

      expect(find.text(_loc!.discover_recommend_service_unavailable),
          findsOneWidget);
      expect(find.byType(PlaylistDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已入库且反查命中 → 直接打开本地歌单,不走导入', (tester) async {
      final recRepo = FakeRecommendRepository()..importedId = 'local-9';
      await pumpSection(
        tester,
        const PlatformRecommendSection(),
        overrides: <Override>[
          recommendChannelsProvider.overrideWith(
            (Ref ref) async => RecommendResult(
              providerId: 'netease',
              channels: <RecommendChannel>[
                RecommendChannel(
                  source: 'netease',
                  name: '频道',
                  count: 1,
                  playlists: <RecommendPlaylist>[_rp('remote-1', '已入库歌单', imported: true)],
                ),
              ],
            ),
          ),
          recommendProviderIdProvider.overrideWithValue(
            AsyncValue<String>.data('netease'),
          ),
          recommendRepositoryProvider.overrideWithValue(recRepo),
        ],
      );

      await tester.tap(find.text('已入库歌单'));
      await drain(tester);
      await settle(tester, frames: 6);

      expect(recRepo.findCalls, <String>['remote-1']);
      expect(recRepo.importInfos, isEmpty, reason: '反查命中就不再导入');
      expect(find.byType(PlaylistDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已入库但反查未命中 → 回退导入流程并打开导入歌单', (tester) async {
      final recRepo = FakeRecommendRepository()
        ..importedId = null
        ..importResult = 'imported-7';
      await pumpSection(
        tester,
        const PlatformRecommendSection(),
        overrides: <Override>[
          recommendChannelsProvider.overrideWith(
            (Ref ref) async => RecommendResult(
              providerId: 'netease',
              channels: <RecommendChannel>[
                RecommendChannel(
                  source: 'netease',
                  name: '频道',
                  count: 1,
                  playlists: <RecommendPlaylist>[_rp('remote-1', '回退导入歌单', imported: true)],
                ),
              ],
            ),
          ),
          recommendProviderIdProvider.overrideWithValue(
            AsyncValue<String>.data('netease'),
          ),
          recommendRepositoryProvider.overrideWithValue(recRepo),
        ],
      );

      await tester.tap(find.text('回退导入歌单'));
      await drain(tester);
      await settle(tester, frames: 6);

      expect(recRepo.importInfos, hasLength(1));
      expect(recRepo.importInfos.single['id'], 'remote-1');
      expect(find.byType(PlaylistDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('导入失败 → toast 带异常消息且不跳转', (tester) async {
      final recRepo = FakeRecommendRepository()
        ..importedId = null
        ..importError = Exception('boom');
      await pumpSection(
        tester,
        const PlatformRecommendSection(),
        overrides: <Override>[
          recommendChannelsProvider.overrideWith(
            (Ref ref) async => RecommendResult(
              providerId: 'netease',
              channels: <RecommendChannel>[
                RecommendChannel(
                  source: 'netease',
                  name: '频道',
                  count: 1,
                  playlists: <RecommendPlaylist>[_rp('remote-1', '导入炸了歌单')],
                ),
              ],
            ),
          ),
          recommendProviderIdProvider.overrideWithValue(
            AsyncValue<String>.data('netease'),
          ),
          recommendRepositoryProvider.overrideWithValue(recRepo),
        ],
      );

      await tester.tap(find.text('导入炸了歌单'));
      await drain(tester);
      await tester.pump();
      await tester.pump();

      expect(recRepo.importInfos, hasLength(1));
      expect(find.textContaining('boom'), findsOneWidget);
      expect(find.byType(PlaylistDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('_playRecommendPlaylist · 封面播放按钮', () {
    testWidgets('未入库 → 先导入再按本地歌单整队播放', (tester) async {
      final recRepo = FakeRecommendRepository()
        ..importedId = null
        ..importResult = 'imported-9';
      final plRepo = FakePlaylistRepository()
        ..songs = <Song>[
          Song(id: 'ps1', title: '歌一', artist: 'A'),
          Song(id: 'ps2', title: '歌二', artist: 'A'),
        ];
      final player = RecordingPlayer();
      await pumpSection(
        tester,
        const PlatformRecommendSection(),
        overrides: <Override>[
          recommendChannelsProvider.overrideWith(
            (Ref ref) async => RecommendResult(
              providerId: 'netease',
              channels: <RecommendChannel>[
                RecommendChannel(
                  source: 'netease',
                  name: '频道',
                  count: 1,
                  playlists: <RecommendPlaylist>[_rp('remote-1', '播放推荐歌单')],
                ),
              ],
            ),
          ),
          recommendProviderIdProvider.overrideWithValue(
            AsyncValue<String>.data('netease'),
          ),
          recommendRepositoryProvider.overrideWithValue(recRepo),
          playlistRepositoryProvider.overrideWithValue(plRepo),
          playerProvider.overrideWith((Ref ref) => player),
        ],
      );

      await tester.tap(find.bySemanticsLabel('播放歌单'));
      await drain(tester);

      expect(recRepo.importInfos.single['id'], 'remote-1');
      expect(plRepo.getAllCalls, <String>['imported-9']);
      expect(player.queues, <List<String>>[
        <String>['ps1', 'ps2'],
      ]);
      final BuildContext ctx = tester.element(
        find.byType(PlatformRecommendSection),
      );
      final QueueOrigin? origin = ProviderScope.containerOf(
        ctx,
      ).read(queueOriginProvider);
      expect(origin!.id, 'imported-9');
      expect(tester.takeException(), isNull);
    });

    testWidgets('导入返回空 id → 不播放（NetworkError 节流只断言副作用）', (tester) async {
      final recRepo = FakeRecommendRepository()
        ..importedId = null
        ..importResult = '';
      final player = RecordingPlayer();
      await pumpSection(
        tester,
        const PlatformRecommendSection(),
        overrides: <Override>[
          recommendChannelsProvider.overrideWith(
            (Ref ref) async => RecommendResult(
              providerId: 'netease',
              channels: <RecommendChannel>[
                RecommendChannel(
                  source: 'netease',
                  name: '频道',
                  count: 1,
                  playlists: <RecommendPlaylist>[_rp('remote-1', '空id歌单')],
                ),
              ],
            ),
          ),
          recommendProviderIdProvider.overrideWithValue(
            AsyncValue<String>.data('netease'),
          ),
          recommendRepositoryProvider.overrideWithValue(recRepo),
          playerProvider.overrideWith((Ref ref) => player),
        ],
      );

      await tester.tap(find.bySemanticsLabel('播放歌单'));
      await drain(tester);

      expect(recRepo.importInfos, hasLength(1));
      expect(player.queues, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('DiscoverPage · 宽屏头部与搜索入口', () {
    Future<void> pumpDiscover(
      WidgetTester tester, {
      required Size size,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final connectivity = ConnectivityMonitor(AddressPool(Dio()));
      addTearDown(connectivity.stop);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            connectivityMonitorProvider.overrideWithValue(connectivity),
            ensureActiveAddressProvider.overrideWith(
              (Ref ref) async => ServerAddress(
                id: 'server-1',
                libraryId: 'library-1',
                label: 'Test server',
                url: 'https://example.test',
                priority: 0,
              ),
            ),
            playerProvider.overrideWith((Ref ref) => RecordingPlayer()),
            homeSectionsProvider.overrideWith(
              (Ref ref) async => const <HomeSection>[],
            ),
            randomSongsProvider.overrideWith(
              (Ref ref) async => <Song>[Song(id: 'rs1', title: '随机歌', artist: 'A')],
            ),
            playlistsProvider.overrideWith(
              (Ref ref) async => <Playlist>[_pl('库内歌单')],
            ),
            recentPlaylistsProvider.overrideWith(
              (Ref ref) async => <Playlist>[_pl('最近歌单')],
            ),
            homeCardsProvider.overrideWith((Ref ref) async => <HomeCard>[]),
            homeRecommendSectionProvider.overrideWith(
              (Ref ref) async => const HomeRecommendSection(
                fixed: <HomeCard>[],
                random: <Playlist>[],
              ),
            ),
            recommendChannelsProvider.overrideWith(
              (Ref ref) async => RecommendResult(
                providerId: 'netease',
                channels: const <RecommendChannel>[],
              ),
            ),
            localRecommendChannelsProvider.overrideWith(
              (Ref ref) async => const <LocalRecommendChannel>[],
            ),
            recommendProviderIdProvider.overrideWithValue(
              AsyncValue<String>.data('netease'),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (BuildContext context, Widget? child) {
              _loc = AppLocalizations.of(context);
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(disableAnimations: true),
                child: child!,
              );
            },
            home: const DiscoverPage(),
          ),
        ),
      );
      await tester.pump();
      await settle(tester);
    }

    testWidgets('宽屏渲染搜索条与页头标题,点搜索条进搜索页,无分类导航', (tester) async {
      await pumpDiscover(tester, size: const Size(1200, 900));

      expect(
        find.byKey(const ValueKey<String>('home-search-entry')),
        findsOneWidget,
      );
      // flutter_test 默认 android 平台 → 首页标题是「MusicFlow」。
      expect(find.text('MusicFlow'), findsOneWidget);
      expect(find.byType(CategoryNavBar), findsNothing);

      // 搜索条容器是全宽 Padding，中心点不在实际按钮上 → 点提示文字。
      await tester.tap(find.text(_loc!.search_hint));
      await settle(tester);

      expect(find.byType(SearchPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Windows 平台标题为空 → 宽屏下整个页头收缩,搜索条仍在', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpDiscover(tester, size: const Size(1200, 900));

        expect(find.text('MusicFlow'), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('home-search-entry')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        // foundation 不变量检查先于 tearDown → 必须在用例体内复位。
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
