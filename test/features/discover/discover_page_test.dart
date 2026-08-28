import 'dart:async';

import 'package:dio/dio.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/pages/discover_page.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/music_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:musicflow_client/providers/playlist_provider.dart';
import 'package:musicflow_client/providers/recommend_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../player/test_player_notifier.dart';

void main() {
  testWidgets('discover renders the five home sections in order', (
    tester,
  ) async {
    await _pumpDiscover(tester);

    // 分类入口(五项)。
    for (final label in <String>['艺术家', '专辑', '歌曲', '歌单', '喜爱']) {
      expect(find.text(label), findsOneWidget);
    }
    // 区块标题按序出现。
    expect(find.text('随机歌曲'), findsOneWidget);
    expect(find.text('最近更新的歌单'), findsOneWidget);
    expect(find.byType(DiscoverSongTile), findsWidgets);
    expect(find.byType(DiscoverPlaylistCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discover survives 320dp and 200 percent text scaling', (
    tester,
  ) async {
    final songs = _songs(
      titlePrefix: '这是一首标题很长用于验证窄屏排版的歌曲',
      count: 3,
    );
    await _pumpDiscover(
      tester,
      size: const Size(320, 900),
      textScale: 2,
      songs: songs,
    );

    expect(find.text('随机歌曲'), findsOneWidget);
    final playMix = find.bySemanticsLabel('播放随机歌曲');
    expect(playMix, findsOneWidget);
    expect(tester.getSize(playMix).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('song taps and the mix action preserve queue playback', (
    tester,
  ) async {
    final songs = _songs(count: 3);
    final player = _RecordingPlayerNotifier();

    await _pumpDiscover(tester, songs: songs, player: player);

    await tester.tap(find.text(songs[1].title));
    await tester.pump();

    expect(player.queues, hasLength(1));
    expect(
      player.queues.single.map((song) => song.id),
      songs.map((song) => song.id),
    );
    expect(player.startIndices.single, 1);

    await tester.tap(find.bySemanticsLabel('播放随机歌曲'));
    await tester.pump();

    expect(player.queues, hasLength(2));
    expect(player.startIndices.last, 0);
  });

  testWidgets('pull refresh invalidates every discover data source', (
    tester,
  ) async {
    var randomLoads = 0;
    var recentLoads = 0;
    var cardsLoads = 0;
    var channelsLoads = 0;
    final songs = _songs(count: 1);
    final playlists = <Playlist>[_playlist()];
    final randomRefresh = Completer<List<Song>>();
    final playlistsRefresh = Completer<List<Playlist>>();
    final recentRefresh = Completer<List<Playlist>>();
    final cardsRefresh = Completer<List<HomeCard>>();
    final channelsRefresh = Completer<RecommendResult>();

    await _pumpDiscover(
      tester,
      extraOverrides: <Override>[
        randomSongsProvider.overrideWith((ref) async {
          randomLoads += 1;
          return randomLoads == 1 ? songs : randomRefresh.future;
        }),
        recentPlaylistsProvider.overrideWith((ref) async {
          recentLoads += 1;
          return recentLoads == 1 ? playlists : recentRefresh.future;
        }),
        homeCardsProvider.overrideWith((ref) async {
          cardsLoads += 1;
          return cardsLoads == 1 ? <HomeCard>[] : cardsRefresh.future;
        }),
        recommendChannelsProvider.overrideWith((ref) async {
          channelsLoads += 1;
          return channelsLoads == 1
              ? RecommendResult(providerId: '', channels: const [])
              : channelsRefresh.future;
        }),
      ],
    );

    final refreshView = tester.widget<MusicFlowRefreshView>(
      find.byType(MusicFlowRefreshView),
    );
    final refresh = refreshView.onRefresh();
    var refreshCompleted = false;
    final trackedRefresh = refresh.then((_) => refreshCompleted = true);
    await tester.pump();

    // recent/频道在 build 时即被 watch(初始 1 次),刷新后再加载 1 次 → 2;
    // homeCardsProvider 为 autoDispose 且未被 widget watch(仅 _refresh/shouldRetry
    // 中 read),初始不加载,刷新时才首次执行 → 1。
    // randomSongs 走「广播变更信号 → 区块重拉」:信号在 _refresh 里 Future.wait
    // 全部完成之后才发出,所以此刻(一次 pump 后)仍是初始的 1 次,异步后置。
    expect(
      <int>[randomLoads, recentLoads, cardsLoads, channelsLoads],
      <int>[1, 2, 1, 2],
    );
    expect(refreshCompleted, isFalse);

    randomRefresh.complete(songs);
    playlistsRefresh.complete(playlists);
    recentRefresh.complete(playlists);
    cardsRefresh.complete(<HomeCard>[]);
    await tester.pump();
    expect(refreshCompleted, isFalse);

    channelsRefresh
        .complete(RecommendResult(providerId: '', channels: const []));
    await trackedRefresh;
    await tester.pumpAndSettle();
    expect(refreshCompleted, isTrue);
  });

  testWidgets('section errors and empty states remain local', (tester) async {
    await _pumpDiscover(
      tester,
      extraOverrides: <Override>[
        randomSongsProvider.overrideWith((ref) async => _songs(count: 2)),
        recentPlaylistsProvider.overrideWith((ref) async {
          throw StateError('recent unavailable');
        }),
        playlistsProvider.overrideWith((ref) async => <Playlist>[]),
        homeCardsProvider.overrideWith((ref) async => <HomeCard>[]),
        recommendChannelsProvider.overrideWith(
          (ref) async =>
              RecommendResult(providerId: '', channels: const []),
        ),
      ],
    );

    // 最近更新歌单失败只影响本区块。
    expect(find.text('最近更新歌单加载失败'), findsOneWidget);
    expect(find.byKey(const Key('discover-random-mix')), findsOneWidget);
    expect(find.bySemanticsLabel('最近更新歌单加载失败，请检查网络或切换线路后重试。'), findsOneWidget);
    expect(find.bySemanticsLabel('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RecordingPlayerNotifier extends TestPlayerNotifier {
  _RecordingPlayerNotifier() : super(PlayerState());

  final List<List<Song>> queues = <List<Song>>[];
  final List<int> startIndices = <int>[];

  @override
  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    queues.add(List<Song>.of(songs));
    startIndices.add(startIndex);
  }
}

Future<void> _pumpDiscover(
  WidgetTester tester, {
  Size size = const Size(390, 1400),
  double textScale = 1,
  List<Song>? songs,
  _RecordingPlayerNotifier? player,
  List<Override> extraOverrides = const <Override>[],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final connectivity = ConnectivityMonitor(AddressPool(Dio()));
  addTearDown(connectivity.stop);
  final overrides = <Override>[
    connectivityMonitorProvider.overrideWithValue(connectivity),
    // 避免 ensureActiveAddressProvider 的 200ms 探测轮询定时器在测试结束时挂起。
    ensureActiveAddressProvider.overrideWith(
      (ref) async => ServerAddress(
        id: 'server-1',
        libraryId: 'library-1',
        label: 'Test server',
        url: 'https://example.test',
        priority: 0,
      ),
    ),
    playerProvider.overrideWith((ref) => player ?? _RecordingPlayerNotifier()),
    if (extraOverrides.isEmpty) ...<Override>[
      randomSongsProvider.overrideWith((ref) async => songs ?? _songs()),
      playlistsProvider.overrideWith(
        (ref) async => <Playlist>[_playlist()],
      ),
      recentPlaylistsProvider.overrideWith(
        (ref) async => <Playlist>[_playlist(), _playlist('第二歌单')],
      ),
      homeCardsProvider.overrideWith((ref) async => <HomeCard>[
            HomeCard(
              playlistId: 'pl-card',
              name: '每日推荐',
              playlistName: '每日推荐',
              position: 0,
              isCombo: false,
              songCount: 12,
            ),
          ]),
      recommendChannelsProvider.overrideWith(
        (ref) async => RecommendResult(providerId: 'netease', channels: [
          RecommendChannel(
            source: 'netease',
            name: '网易云音乐',
            count: 1,
            playlists: [
              RecommendPlaylist(
                id: 'r-1',
                source: 'netease',
                name: '平台推荐歌单',
                creator: '官方',
                trackCount: '30',
                link: '',
                imported: false,
              ),
            ],
          ),
        ]),
      ),
      recommendProviderIdProvider.overrideWithValue(AsyncValue.data('netease')),
    ],
    ...extraOverrides,
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          );
        },
        home: const DiscoverPage(),
      ),
    ),
  );
  await tester.pump();
  // 随机歌曲区块不再随页面打开自动拉取(改为按需拉取)。测试通过广播
  // 「歌单变更」信号触发一次按需拉取,与生产环境「插件推送更新」一致。
  notifyRandomSongsChanged();
  await tester.pumpAndSettle();
}

Playlist _playlist([String name = '默认歌单']) => Playlist(
      id: 'pl-' + name.hashCode.toString(),
      name: name,
      songCount: 8,
      duration: 1800,
    );

List<Song> _songs({String titlePrefix = '歌曲', int count = 8}) {
  return List<Song>.generate(
    count,
    (index) => Song(
      id: 'song-$index',
      title: '$titlePrefix ${index + 1}',
      artist: '歌手 ${index + 1}',
      duration: 180 + index,
    ),
  );
}
