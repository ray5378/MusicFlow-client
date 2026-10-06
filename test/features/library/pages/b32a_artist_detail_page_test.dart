// batch32 A 路：艺术家详情页 ArtistDetailPage（约 698 行，基线约 43.9%）。
// 覆盖点：加载骨架 / 未找到空态 / 加载失败+重试 / provider 异常+重试恢复 /
// 头部信息 / 热门歌曲预览与展开收起 / 热门歌曲空与失败分支 / 播放全部 /
// 点行起播（全部歌曲与热门歌曲两条队列）/ 当前播放高亮迁移 / 长按歌曲菜单 /
// 专辑 tab 网格+列表双布局 / 进专辑详情 / 长按专辑菜单 / 收藏开关三态 /
// 歌曲来源说明面板 / 无歌空态。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/media_detail_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../../helpers/mocks.dart';
import '../../player/test_player_notifier.dart';

class _B32aPlayer extends TestPlayerNotifier {
  _B32aPlayer(super.state);

  final List<int> playQueueStartIndexes = <int>[];
  final List<int> playQueueLengths = <int>[];
  final List<String> queueTitles = <String>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    if (songs.isEmpty) return;
    final safeIndex = startIndex.clamp(0, songs.length - 1);
    playQueueStartIndexes.add(safeIndex);
    playQueueLengths.add(songs.length);
    queueTitles.add(songs[safeIndex].title);
    state = state.copyWith(
      queue: songs,
      currentIndex: safeIndex,
      currentSong: songs[safeIndex],
    );
  }
}

class _B32aMusicRepository extends Mock implements MusicRepository {}

class _B32aCastPeer extends CastPeerController {
  _B32aCastPeer(super.ref);
}

class _B32aDlna extends DlnaCastNotifier {
  _B32aDlna(super.ref);
}

Song _song(String id, String title, {int duration = 180}) => Song(
      id: id,
      title: title,
      artist: '夜航西飞',
      album: '专辑一',
      albumId: 'al-1',
      track: 1,
      duration: duration,
    );

final _detailSongs = <Song>[
  _song('s-1', '归途'),
  _song('s-2', '灯塔'),
  _song('s-3', '起航'),
];

final _detailAlbums = <Album>[
  Album(
    id: 'al-1',
    name: '专辑一',
    artist: '夜航西飞',
    songCount: 3,
    duration: 900,
    year: 2026,
    genre: '流行',
  ),
  Album(
    id: 'al-2',
    name: '专辑二',
    artist: '夜航西飞',
    songCount: 2,
    duration: 600,
    year: 2025,
    genre: '民谣',
  ),
];

ArtistDetail _detail({List<Album>? albums, List<Song>? songs}) =>
    ArtistDetail(
      artist: Artist(
        id: 'ar-1',
        name: '夜航西飞',
        coverArt: null,
        albumCount: 2,
        starred: false,
      ),
      albums: albums ?? _detailAlbums,
      songs: songs ?? _detailSongs,
    );

/// 热门歌曲 7 首（标题与全部歌曲不同，便于区分两条队列）。
List<Song> _topSongs({int count = 7}) => List<Song>.generate(
      count,
      (i) => _song('t-${i + 1}', '热歌${i + 1}', duration: 200 + i),
    );

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(MusicFlowPressable),
    );

Finder _pressable(String label) => find.byWidgetPredicate(
      (w) => w is MusicFlowPressable && w.semanticLabel == label,
    );

MusicFlowPressable _pressableWidget(WidgetTester tester, Finder finder) =>
    tester.widget<MusicFlowPressable>(finder.first);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    api = MockSubsonicApiClient();
    when(
      () => api.getCoverArtUrl(any(), size: any(named: 'size')),
    ).thenReturn('https://example.test/cover?id=x');
  });

  Future<(_B32aPlayer, ProviderContainer)> pumpPage(
    WidgetTester tester, {
    required FutureOr<ArtistDetail?> Function() detail,
    FutureOr<List<Song>> Function()? topSongs,
    bool loadFailed = false,
    _B32aPlayer? playerOverride,
    _B32aMusicRepository? repo,
    Size size = const Size(900, 1400),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final activePlayer = playerOverride ?? _B32aPlayer(PlayerState());
    final container = ProviderContainer(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(
          ConnectivityMonitor(AddressPool(Dio())),
        ),
        subsonicApiClientProvider.overrideWithValue(api),
        playerProvider.overrideWith((ref) => activePlayer),
        castPeerControllerProvider.overrideWith(
          (Ref ref) => _B32aCastPeer(ref),
        ),
        dlnaCastProvider.overrideWith((Ref ref) => _B32aDlna(ref)),
        musicRepositoryProvider.overrideWithValue(repo),
        ensureActiveAddressProvider.overrideWith(
          (ref) async => const ServerAddress(
            id: 'addr-1',
            libraryId: 'lib-1',
            label: '主线路',
            url: 'https://example.test',
            priority: 0,
          ),
        ),
        artistDetailProvider.overrideWith(
          (ref, String artistId) async => detail(),
        ),
        artistDetailLoadFailedProvider.overrideWith(
          (ref, String artistId) => loadFailed,
        ),
        topSongsByArtistProvider.overrideWith(
          (ref, String artistName) async {
            if (topSongs == null) return const <Song>[];
            return topSongs();
          },
        ),
        // 长按专辑会打开专辑操作面板（watch playlistsProvider）。
        playlistsProvider.overrideWith((ref) async => const <Playlist>[]),
        // 进专辑详情页时的数据。
        albumDetailProvider.overrideWith(
          (ref, String albumId) async => AlbumDetail(
            album: _detailAlbums.first,
            songs: const <Song>[],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.light(),
          home: const Scaffold(
            body: ArtistDetailPage(artistId: 'ar-1'),
          ),
        ),
      ),
    );
    return (activePlayer, container);
  }

  testWidgets('艺术家详情:加载中先渲染骨架,完成后渲染头部与全部歌曲行', (tester) async {
    final gate = Completer<ArtistDetail?>();
    await pumpPage(tester, detail: () => gate.future);
    await tester.pump();
    expect(find.byType(MediaDetailLoadingView), findsOneWidget);

    gate.complete(_detail());
    await _settle(tester);

    expect(find.byType(MediaDetailLoadingView), findsNothing);
    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.text('夜航西飞'), findsOneWidget);
    expect(
      find.textContaining(loc.library_artist_counts('3', '2')),
      findsOneWidget,
    );
    expect(find.text(loc.library_all_songs), findsOneWidget);
    expect(find.text(loc.library_song_count('3')), findsOneWidget);
    expect(_row('归途'), findsOneWidget);
    expect(_row('灯塔'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:详情为 null 且未失败 → 未找到空态', (tester) async {
    await pumpPage(tester, detail: () => null);
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.byType(MusicFlowEmptyState), findsOneWidget);
    expect(find.text(loc.library_artist_not_found), findsOneWidget);
    expect(find.text('夜航西飞'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:provider 抛异常 → 错误态,重试后恢复数据', (tester) async {
    var fail = true;
    await pumpPage(
      tester,
      detail: () async {
        if (fail) throw StateError('boom');
        return _detail();
      },
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.byType(MusicFlowErrorState), findsOneWidget);
    expect(find.text(loc.library_artist_load_failed), findsOneWidget);
    expect(find.text(loc.widgets_retry), findsOneWidget);

    fail = false;
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester);

    expect(find.byType(MusicFlowErrorState), findsNothing);
    expect(find.text('夜航西飞'), findsOneWidget);
    expect(_row('归途'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:loadFailed 且数据为 null → 错误态,重试恢复数据后保留缓存提示条', (tester) async {
    var loaded = false;
    await pumpPage(
      tester,
      detail: () => loaded ? _detail() : null,
      loadFailed: true,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.byType(MusicFlowErrorState), findsOneWidget);
    expect(find.text(loc.widgets_retry), findsOneWidget);

    loaded = true;
    await tester.tap(find.text(loc.widgets_retry));
    await _settle(tester);

    // 数据已渲染，但 loadFailed 标记仍在 → 显示「网络受限，展示缓存内容」提示。
    expect(find.text('夜航西飞'), findsOneWidget);
    expect(find.byType(MediaLoadNotice), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:热门歌曲超过 5 首默认截断,可展开与收起', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.text(loc.library_top_songs), findsOneWidget);
    expect(
      find.textContaining(loc.library_top_songs_count('7')),
      findsOneWidget,
    );
    for (var i = 1; i <= 5; i++) {
      expect(find.text('热歌$i'), findsOneWidget, reason: '预览应包含热歌$i');
    }
    expect(find.text('热歌6'), findsNothing);
    expect(find.text(loc.action_show_all), findsOneWidget);

    await tester.tap(find.text(loc.action_show_all));
    await _settle(tester);
    expect(find.text('热歌6'), findsOneWidget);
    expect(find.text('热歌7'), findsOneWidget);
    expect(find.text(loc.action_collapse), findsOneWidget);

    await tester.tap(find.text(loc.action_collapse));
    await _settle(tester);
    expect(find.text('热歌6'), findsNothing);
    expect(find.text('热歌5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:热门歌曲为空不渲染热门区', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => const <Song>[],
    );
    await _settle(tester);
    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.text(loc.library_top_songs), findsNothing);
    expect(find.text(loc.library_all_songs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:热门歌曲失败显示局部错误提示,全部歌曲区不受影响', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () async => throw StateError('top songs down'),
    );
    await _settle(tester);
    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    expect(find.text(loc.library_top_songs), findsNothing);
    expect(find.byType(MediaLoadNotice), findsOneWidget);
    expect(find.text(loc.library_top_songs_unavailable), findsOneWidget);
    expect(find.text(loc.library_all_songs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:点「播放全部」从第 0 首起播全部歌曲整队', (tester) async {
    final (recPlayer, container) = await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(find.text(loc.library_play_all));
    await _settle(tester);

    expect(recPlayer.playQueueLengths, <int>[3]);
    expect(recPlayer.playQueueStartIndexes, <int>[0]);
    expect(recPlayer.queueTitles, <String>['归途']);
    expect(
      container.read(playerProvider).queue.map((s) => s.title).toList(),
      <String>['归途', '灯塔', '起航'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:点全部歌曲第 2 行从该行起播', (tester) async {
    final (recPlayer, _) = await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
    );
    await _settle(tester);

    await tester.tap(_row('灯塔'));
    await _settle(tester);

    expect(recPlayer.playQueueStartIndexes, <int>[1]);
    expect(recPlayer.queueTitles, <String>['灯塔']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:点热门歌曲行按热门队列起播对应索引', (tester) async {
    final (recPlayer, _) = await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
    );
    await _settle(tester);

    await tester.tap(_row('热歌3'));
    await _settle(tester);

    expect(recPlayer.playQueueLengths, <int>[7]);
    expect(recPlayer.playQueueStartIndexes, <int>[2]);
    expect(recPlayer.queueTitles, <String>['热歌3']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:当前播放行高亮随 currentSong 迁移', (tester) async {
    final (_, container) = await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
      playerOverride: _B32aPlayer(
        PlayerState(currentSong: _detailSongs[1]),
      ),
    );
    await _settle(tester);

    expect(_pressableWidget(tester, _row('灯塔')).selected, isTrue);
    expect(_pressableWidget(tester, _row('归途')).selected, isNot(true));

    final state = container.read(playerProvider);
    (container.read(playerProvider.notifier) as dynamic).emit(
      state.copyWith(currentSong: _detailSongs[0]),
    );
    await _settle(tester);

    expect(_pressableWidget(tester, _row('归途')).selected, isTrue);
    expect(_pressableWidget(tester, _row('灯塔')).selected, isNot(true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:长按歌曲行弹出歌曲操作面板', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      topSongs: () => _topSongs(),
    );
    await _settle(tester);

    await tester.longPress(_row('起航'));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:切到专辑 tab 宽屏渲染网格,点卡片进入专辑详情页', (tester) async {
    await pumpPage(tester, detail: () => _detail());
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_albums));
    await _settle(tester);

    expect(find.byType(MediaDetailAlbumTile), findsNWidgets(2));
    expect(find.text('专辑一'), findsOneWidget);
    expect(find.text('专辑二'), findsOneWidget);
    // 歌曲区已收起。
    expect(find.text(loc.library_all_songs), findsNothing);

    await tester.tap(find.byType(MediaDetailAlbumTile).first);
    await _settle(tester);

    expect(find.byType(AlbumDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:专辑为空显示空态', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(albums: const <Album>[]),
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_albums));
    await _settle(tester);

    expect(find.byType(MusicFlowEmptyState), findsOneWidget);
    expect(find.text(loc.library_no_albums), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:窄屏专辑走列表行布局,长按弹出专辑操作面板', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      size: const Size(480, 900),
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_albums));
    await _settle(tester);

    // 窄屏（<520 或大字号）走 SliverList 列表行，不出网格卡。
    expect(find.byType(MediaDetailAlbumTile), findsNothing);
    expect(find.text('专辑一'), findsOneWidget);

    await tester.longPress(find.text('专辑一'));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:未收藏点击收藏按钮调用 setArtistStarred(true)', (tester) async {
    final repo = _B32aMusicRepository();
    when(() => repo.setArtistStarred('ar-1', true)).thenAnswer((_) async {});
    await pumpPage(
      tester,
      detail: () => _detail(),
      repo: repo,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_favorite_artist));
    await _settle(tester);

    verify(() => repo.setArtistStarred('ar-1', true)).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:仓库为 null 时点收藏按钮静默早退不崩溃', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(),
      repo: null,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_favorite_artist));
    await _settle(tester);

    // 未起播、未崩溃即可。
    expect(find.text(loc.library_play_songs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:setArtistStarred 抛错时不崩溃走失败提示路径', (tester) async {
    final repo = _B32aMusicRepository();
    when(() => repo.setArtistStarred(any(), any()))
        .thenThrow(StateError('starred down'));
    await pumpPage(
      tester,
      detail: () => _detail(),
      repo: repo,
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_favorite_artist));
    await _settle(tester);

    verify(() => repo.setArtistStarred('ar-1', true)).called(1);
    // 页面仍在，未崩溃（错误被页面捕获后只弹 Toast）。
    expect(find.text('夜航西飞'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:歌曲为空时头部「播放歌曲」禁用且显示无歌空态', (tester) async {
    await pumpPage(
      tester,
      detail: () => _detail(songs: const <Song>[]),
      topSongs: () => const <Song>[],
    );
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    final playButton = tester.widget<MusicFlowButton>(
      find.ancestor(
        of: find.text(loc.library_play_songs),
        matching: find.byType(MusicFlowButton),
      ),
    );
    expect(playButton.onPressed, isNull);
    expect(find.text(loc.library_no_songs), findsOneWidget);
    expect(find.text(loc.library_no_playable_songs), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('艺术家详情:顶栏「歌曲来源」按钮弹出说明面板可关闭', (tester) async {
    await pumpPage(tester, detail: () => _detail());
    await _settle(tester);

    final loc = AppLocalizations.of(
      tester.element(find.byType(ArtistDetailPage)),
    );
    await tester.tap(_pressable(loc.library_artist_song_source));
    await _settle(tester);

    expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
    expect(find.text(loc.library_artist_song_source_desc), findsOneWidget);

    await tester.tap(find.text(loc.library_got_it));
    await _settle(tester, frames: 12);
    expect(find.byType(MusicFlowBottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
