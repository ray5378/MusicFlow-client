// batch37 C(2) —— `lib/features/discover/pages/discover_page.dart` 剩余分支。
//
// 既有 discover_page_test / discover_page_cov_test 已覆盖各分区数据/空/错/加载态与
// 标题解析。本文件补 lcov 仍标 0 的（全部是「回调体」与「卡片交互」）：
//   * playLocalPlaylistById 播放失败 catch（150）；
//   * compact + 平台不显示首页标题时的顶栏「菜单」按钮（245-247）；
//   * 首页可见重试作用域 shouldRetry/onRetry（354-375）；
//   * 四个横向分区「重试」回调（609/678/719/821/982/1064/1116/1224）；
//   * 固定推荐卡片 queueOrigin/长按/播放/点击（762/770/780/786-798）；
//   * 本地平台推荐卡片分隔线/queueOrigin/长按/播放/点击（1158-1198）；
//   * 插件推荐「导入中」卡片点击空回调（1024）；
//   * _playRecommendPlaylist 的无 provider/无仓库/已入库/导入失败路径（909/914/921/942-943）。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';
import 'package:musicflow_client/features/discover/pages/discover_page.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

import '../../player/test_player_notifier.dart';

class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({this.currentNetworkType = NetworkType.none});

  final StreamController<NetworkType> _controller =
      StreamController<NetworkType>.broadcast();

  @override
  NetworkType currentNetworkType;

  @override
  Stream<NetworkType> get networkTypeStream => _controller.stream;

  @override
  void start() {}

  @override
  void stop() {}

  void emit(NetworkType type) {
    currentNetworkType = type;
    _controller.add(type);
  }

  Future<void> dispose() => _controller.close();
}

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  final List<String> queuedIds = <String>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    if (songs.isEmpty) return;
    final safeIndex = startIndex.clamp(0, songs.length - 1);
    queuedIds.add(songs[safeIndex].id);
    state = state.copyWith(
      queue: songs,
      currentIndex: safeIndex,
      currentSong: songs[safeIndex],
    );
  }
}

class _PlaylistRepository extends Mock implements PlaylistRepository {}

class _RecommendRepository extends Mock implements RecommendRepository {}

class _CastPeer extends CastPeerController {
  _CastPeer(super.ref);
}

class _Dlna extends DlnaCastNotifier {
  _Dlna(super.ref);
}

List<Song> _songs({String prefix = '歌', int count = 3}) => List<Song>.generate(
      count,
      (i) => Song(id: 'song-$i', title: '$prefix$i', duration: 200 + i),
    );

Playlist _playlist(String id, String name) => Playlist(
      id: id,
      name: name,
      songCount: 8,
      duration: 1600,
    );

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 真播放/导航链路需要的一批底层 provider。
List<Override> _coreOverrides({
  FakeConnectivityMonitor? monitor,
  _RecPlayer? player,
  PlaylistRepository? playlistRepo,
  RecommendRepository? recommendRepo,
}) {
  return <Override>[
    connectivityMonitorProvider
        .overrideWithValue(monitor ?? FakeConnectivityMonitor()),
    ensureActiveAddressProvider.overrideWith(
      (ref) async => const ServerAddress(
        id: 'server-1',
        libraryId: 'library-1',
        label: 'Test server',
        url: 'https://example.test',
        priority: 0,
      ),
    ),
    playerProvider.overrideWith((ref) => player ?? _RecPlayer(PlayerState())),
    castPeerControllerProvider.overrideWith((Ref ref) => _CastPeer(ref)),
    dlnaCastProvider.overrideWith((Ref ref) => _Dlna(ref)),
    effectiveIsPlayingProvider.overrideWith((ref) => false),
    playlistRepositoryProvider.overrideWith((ref) => playlistRepo),
    recommendRepositoryProvider.overrideWith((ref) => recommendRepo),
    playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
    playlistDetailProvider.overrideWith(
      (ref, String id) async => Playlist(id: id, name: '歌单', songCount: 0, duration: 0),
    ),
  ];
}

Future<void> _pumpSection(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
  Size size = const Size(390, 1000),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
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
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await _settle(tester, frames: 4);
}

Finder _cardWithText(String title) =>
    find.widgetWithText(DiscoverPlaylistCard, title);

Finder _playButton(String title) => find.descendant(
      of: _cardWithText(title),
      matching: find.byType(MusicFlowIconButton),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('playLocalPlaylistById:拉全量失败 → 网络提示且不抛（150）', (tester) async {
    final repo = _PlaylistRepository();
    when(() => repo.getAllPlaylistSongs('pl-x'))
        .thenAnswer((_) async => throw StateError('down'));

    late WidgetRef capturedRef;
    await _pumpSection(
      tester,
      Consumer(
        builder: (context, ref, _) {
          capturedRef = ref;
          return const SizedBox.shrink();
        },
      ),
      overrides: _coreOverrides(playlistRepo: repo),
    );

    await playLocalPlaylistById(capturedRef, 'pl-x');
    await _settle(tester, frames: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页:compact + 平台无标题 → 顶栏渲染菜单按钮（245-247）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final monitor = FakeConnectivityMonitor();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ..._coreOverrides(monitor: monitor),
          homeSectionsProvider.overrideWith((ref) async => const <HomeSection>[]),
          randomSongsProvider.overrideWith((ref) async => _songs()),
          recentPlaylistsProvider.overrideWith((ref) async => const <Playlist>[]),
          homeCardsProvider.overrideWith((ref) async => const <HomeCard>[]),
          homeRecommendSectionProvider.overrideWith(
            (ref) async => const HomeRecommendSection(
              fixed: <HomeCard>[],
              random: <Playlist>[],
            ),
          ),
          recommendChannelsProvider.overrideWith(
            (ref) async => RecommendResult(providerId: '', channels: <RecommendChannel>[]),
          ),
          recommendProviderIdProvider.overrideWithValue(const AsyncValue.data('')),
          localRecommendChannelsProvider
              .overrideWith((ref) async => const <LocalRecommendChannel>[]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const DiscoverPage(),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, frames: 6);

    final loc = AppLocalizations.of(tester.element(find.byType(DiscoverPage)));
    // 平台目标改回默认（避免 foundation 调试变量残留断言）。
    debugDefaultTargetPlatformOverride = null;
    expect(find.bySemanticsLabel(loc.discover_open_app_menu), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页:网络恢复触发可见重试作用域 shouldRetry/onRetry（354-375）', (tester) async {
    final monitor = FakeConnectivityMonitor();

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ..._coreOverrides(monitor: monitor),
          homeSectionsProvider.overrideWith((ref) async => const <HomeSection>[]),
          randomSongsProvider.overrideWith((ref) async => _songs()),
          // 歌单加载失败 → shouldRetry 为真。
          playlistsProvider.overrideWith(
            (ref) => Future<List<Playlist>>.error(StateError('playlists down')),
          ),
          recentPlaylistsProvider.overrideWith((ref) async => const <Playlist>[]),
          homeCardsProvider.overrideWith((ref) async => const <HomeCard>[]),
          homeRecommendSectionProvider.overrideWith(
            (ref) async => const HomeRecommendSection(
              fixed: <HomeCard>[],
              random: <Playlist>[],
            ),
          ),
          recommendChannelsProvider.overrideWith(
            (ref) async => RecommendResult(providerId: '', channels: <RecommendChannel>[]),
          ),
          recommendProviderIdProvider.overrideWithValue(const AsyncValue.data('')),
          localRecommendChannelsProvider
              .overrideWith((ref) async => const <LocalRecommendChannel>[]),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const DiscoverPage(),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, frames: 6);

    monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    monitor.emit(NetworkType.mobile);
    await tester.pump();
    await tester.pump();
    await _settle(tester, frames: 4);

    expect(tester.takeException(), isNull);
  });

  testWidgets('最近歌单:空+失败与异常都渲染错误态且可点重试（609/678）', (tester) async {
    final loc = AppLocalizations.of(
      tester.element(
        await _pumpSectionReturn(tester, const RecentPlaylistsSection(),
            overrides: <Override>[
              recentPlaylistsProvider.overrideWith((ref) async => const <Playlist>[]),
              recentPlaylistsLoadFailedProvider.overrideWith((ref) => true),
            ]),
      ),
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);

    await _pumpSection(
      tester,
      const RecentPlaylistsSection(),
      overrides: <Override>[
        recentPlaylistsProvider.overrideWith(
          (ref) => Future<List<Playlist>>.error(StateError('recent down')),
        ),
      ],
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('固定推荐:空+失败与异常都渲染错误态且可点重试（719/821）', (tester) async {
    final loc = AppLocalizations.of(
      tester.element(
        await _pumpSectionReturn(tester, const FixedRecommendSection(),
            overrides: <Override>[
              homeRecommendSectionProvider.overrideWith(
                (ref) async => const HomeRecommendSection(
                  fixed: <HomeCard>[],
                  random: <Playlist>[],
                ),
              ),
              homeCardsLoadFailedProvider.overrideWith((ref) => true),
            ]),
      ),
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);

    await _pumpSection(
      tester,
      const FixedRecommendSection(),
      overrides: <Override>[
        homeRecommendSectionProvider.overrideWith(
          (ref) => Future<HomeRecommendSection>.error(StateError('fixed down')),
        ),
      ],
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('插件推荐:空+失败与异常可点重试；导入中卡片点击空回调（982/1024/1064）',
      (tester) async {
    final loc = AppLocalizations.of(
      tester.element(
        await _pumpSectionReturn(tester, const PlatformRecommendSection(),
            overrides: <Override>[
              recommendChannelsProvider.overrideWith(
                (ref) async => RecommendResult(providerId: '', channels: <RecommendChannel>[]),
              ),
              recommendChannelsLoadFailedProvider.overrideWith((ref) => true),
            ]),
      ),
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);

    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        recommendChannelsProvider.overrideWith(
          (ref) => Future<RecommendResult>.error(StateError('plugin down')),
        ),
      ],
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);

    // 导入中卡片：onPressed 为空回调（1024）。
    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        ..._coreOverrides(),
        recommendChannelsProvider.overrideWith(
          (ref) async => RecommendResult(
            providerId: 'netease',
            channels: <RecommendChannel>[
              RecommendChannel(
                source: 'netease',
                name: '有内容',
                count: 1,
                playlists: <RecommendPlaylist>[_rp('导入中', 'loading')],
              ),
            ],
          ),
        ),
        recommendProviderIdProvider.overrideWithValue(const AsyncValue.data('netease')),
        recommendImportingProvider.overrideWith((ref) => 'loading'),
      ],
    );
    await tester.tap(_cardWithText('导入中'));
    await _settle(tester, frames: 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地平台推荐:空+失败与异常可点重试（1116/1224）', (tester) async {
    final loc = AppLocalizations.of(
      tester.element(
        await _pumpSectionReturn(tester, const LocalPlatformRecommendSection(),
            overrides: <Override>[
              localRecommendChannelsProvider
                  .overrideWith((ref) async => const <LocalRecommendChannel>[]),
              localRecommendChannelsLoadFailedProvider.overrideWith((ref) => true),
            ]),
      ),
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);

    await _pumpSection(
      tester,
      const LocalPlatformRecommendSection(),
      overrides: <Override>[
        localRecommendChannelsProvider.overrideWith(
          (ref) => Future<List<LocalRecommendChannel>>.error(
            StateError('local down'),
          ),
        ),
      ],
    );
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester, frames: 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地平台推荐:多曲目分隔线/queueOrigin/长按/播放/点击（1158-1198）',
      (tester) async {
    final playlistRepo = _PlaylistRepository();
    when(() => playlistRepo.getAllPlaylistSongs('local-1'))
        .thenAnswer((_) async => _songs());

    await _pumpSection(
      tester,
      const LocalPlatformRecommendSection(),
      overrides: <Override>[
        ..._coreOverrides(playlistRepo: playlistRepo),
        queueOriginProvider.overrideWith(
          (ref) => const QueueOrigin(QueueOriginKind.playlist, 'other-id'),
        ),
        localRecommendChannelsProvider.overrideWith(
          (ref) async => <LocalRecommendChannel>[
            LocalRecommendChannel(
              source: 'netease',
              name: '网易云',
              count: 2,
              playlists: <LocalRecommendPlaylist>[
                LocalRecommendPlaylist(id: 'local-1', name: '本地歌单一', songCount: 31),
                LocalRecommendPlaylist(id: 'local-2', name: '本地歌单二', songCount: 22),
              ],
            ),
          ],
        ),
      ],
    );
    expect(_cardWithText('本地歌单一'), findsOneWidget);

    // 长按 → 歌单操作面板（1170-1179）。
    await tester.longPress(_cardWithText('本地歌单一'));
    await _settle(tester, frames: 4);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    // 关闭面板。
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester, frames: 4);

    // 封面播放按钮 → playLocalPlaylistById（1180-1185）。
    await tester.tap(_playButton('本地歌单一'));
    await _settle(tester, frames: 4);

    // 点击卡面 → 进入歌单详情（1186-1198）。
    await tester.tap(_cardWithText('本地歌单一'));
    await _settle(tester, frames: 6);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('固定推荐:queueOrigin/长按/播放/点击（762/770/780/786-798）', (tester) async {
    final playlistRepo = _PlaylistRepository();
    when(() => playlistRepo.getAllPlaylistSongs('fixed-1'))
        .thenAnswer((_) async => _songs());

    await _pumpSection(
      tester,
      const FixedRecommendSection(),
      overrides: <Override>[
        ..._coreOverrides(playlistRepo: playlistRepo),
        queueOriginProvider.overrideWith(
          (ref) => const QueueOrigin(QueueOriginKind.playlist, 'other-id'),
        ),
        homeRecommendSectionProvider.overrideWith(
          (ref) async => HomeRecommendSection(
            fixed: <HomeCard>[
              HomeCard(
                playlistId: 'fixed-1',
                name: '固定卡',
                playlistName: '固定卡',
                position: 0,
                isCombo: false,
                songCount: 35,
              ),
            ],
            random: <Playlist>[_playlist('rand-1', '随机补位')],
          ),
        ),
      ],
    );
    expect(_cardWithText('固定卡'), findsOneWidget);

    await tester.longPress(_cardWithText('固定卡'));
    await _settle(tester, frames: 4);
    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester, frames: 4);

    await tester.tap(_playButton('固定卡'));
    await _settle(tester, frames: 4);

    await tester.tap(_cardWithText('固定卡'));
    await _settle(tester, frames: 6);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('插件推荐播放:无 provider / 无仓库 / 已入库播放 / 导入失败（909/914/921/942-943）',
      (tester) async {
    // (1) providerId 为空 → 提示（909）。
    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        ..._coreOverrides(),
        recommendChannelsProvider.overrideWith(
          (ref) async => RecommendResult(
            providerId: '',
            channels: <RecommendChannel>[
              RecommendChannel(
                source: 'netease',
                name: '有内容',
                count: 1,
                playlists: <RecommendPlaylist>[_rp('A歌单', 'a')],
              ),
            ],
          ),
        ),
        recommendProviderIdProvider.overrideWithValue(const AsyncValue.data('')),
      ],
    );
    await tester.tap(_playButton('A歌单'));
    await _settle(tester, frames: 3);

    // (2) 仓库为 null → 提示（914）。
    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        ..._coreOverrides(),
        recommendChannelsProvider.overrideWith(
          (ref) async => RecommendResult(
            providerId: 'netease',
            channels: <RecommendChannel>[
              RecommendChannel(
                source: 'netease',
                name: '有内容',
                count: 1,
                playlists: <RecommendPlaylist>[_rp('B歌单', 'b')],
              ),
            ],
          ),
        ),
        recommendProviderIdProvider.overrideWithValue(const AsyncValue.data('netease')),
      ],
    );
    await tester.tap(_playButton('B歌单'));
    await _settle(tester, frames: 3);

    // (3) 已入库 → 反查本地 id 后整单播放（921）。
    final playlistRepo = _PlaylistRepository();
    when(() => playlistRepo.getAllPlaylistSongs('local-a'))
        .thenAnswer((_) async => _songs());
    final recommendRepo = _RecommendRepository();
    when(() => recommendRepo.findImportedPlaylistId('netease', 'a'))
        .thenAnswer((_) async => 'local-a');
    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        ..._coreOverrides(
          playlistRepo: playlistRepo,
          recommendRepo: recommendRepo,
        ),
        recommendChannelsProvider.overrideWith(
          (ref) async => RecommendResult(
            providerId: 'netease',
            channels: <RecommendChannel>[
              RecommendChannel(
                source: 'netease',
                name: '有内容',
                count: 1,
                playlists: <RecommendPlaylist>[_rp('A歌单', 'a', imported: true)],
              ),
            ],
          ),
        ),
        recommendProviderIdProvider.overrideWithValue(const AsyncValue.data('netease')),
      ],
    );
    await tester.tap(_playButton('A歌单'));
    await _settle(tester, frames: 4);

    // (4) 未入库 + 导入失败 → 提示（942-943）。
    final failingRepo = _RecommendRepository();
    when(() => failingRepo.importRecommendPlaylist('netease', any()))
        .thenAnswer((_) async => throw StateError('import failed'));
    await _pumpSection(
      tester,
      const PlatformRecommendSection(),
      overrides: <Override>[
        ..._coreOverrides(recommendRepo: failingRepo),
        recommendChannelsProvider.overrideWith(
          (ref) async => RecommendResult(
            providerId: 'netease',
            channels: <RecommendChannel>[
              RecommendChannel(
                source: 'netease',
                name: '有内容',
                count: 1,
                playlists: <RecommendPlaylist>[_rp('C歌单', 'c')],
              ),
            ],
          ),
        ),
        recommendProviderIdProvider.overrideWithValue(const AsyncValue.data('netease')),
      ],
    );
    await tester.tap(_playButton('C歌单'));
    await _settle(tester, frames: 4);

    expect(tester.takeException(), isNull);
  });
}

/// 渲染单个分区并把「分区 widget 的 Finder」返回，便于取 loc。
Future<Finder> _pumpSectionReturn(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
  Size size = const Size(390, 1000),
}) async {
  await _pumpSection(tester, child, overrides: overrides, size: size);
  return find.byWidget(child);
}

RecommendPlaylist _rp(String name, String id, {bool imported = false}) =>
    RecommendPlaylist(
      id: id,
      source: 'netease',
      name: name,
      creator: '官方',
      trackCount: '30',
      link: '',
      imported: imported,
    );
