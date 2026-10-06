// batch32 C 路 —— `lib/features/library/pages/starred_page.dart` 交互层补测。
//
// 分工（与既有 starred_page_cov_test.dart）：
//   * cov_test 打的是骨架/空态/tab 切换/骨架屏/错误态/下拉刷新；
//   * 本文件打剩余的交互分支：
//     - 歌曲行点击 → playEffectiveQueue(startIndex)（走 RecordingPlayer 记录）；
//     - 当前播放歌曲行 isCurrent 高亮；
//     - 歌单卡封面分支（CoverArtImage）+ 点击进 PlaylistDetailPage + 长按开
//       歌单操作弹窗；
//     - 专辑卡点击进 AlbumDetailPage + queueOrigin 匹配 → isNowPlaying +
//       大字体（textScale≥1.6）时专辑/歌单改用行布局（列表 key）；
//     - 歌手行点击进 ArtistDetailPage + 长按开歌手操作弹窗；
//     - 歌曲行长按开歌曲操作弹窗。
//
// 踩坑记录（C 路约定）：
//   * 点卡片 push 出来的详情页（Playlist/Album/ArtistDetailPage）在仓库为 null
//     时各自渲染错误态/空态，不碰网络，可以安全断言 byType。
//   * 长按打开的 options sheet 会 watch playerProvider（song options）→ 本文件
//     全部用例统一 override playerProvider 为 RecordingPlayer；cast/dlna 两个
//     provider 用默认态即可（无投屏设备，构造无副作用）。
//   * queueOriginProvider 是 StateProvider，等首帧后经 ProviderScope.containerOf
//     写入，再 pump 一帧触发 isNowPlaying 重建。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/features/library/pages/album_detail_page.dart';
import 'package:musicflow_client/features/library/pages/artist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

import '../../player/test_player_notifier.dart';

/// 记录 playQueue 调用的播放器桩（TestPlayerNotifier 未 override playQueue）。
class RecordingPlayer extends TestPlayerNotifier {
  RecordingPlayer([PlayerState? initial]) : super(initial ?? PlayerState());

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
    state = state.copyWith(queue: songs, currentIndex: startIndex);
  }
}

StarredResult _filledStarred({bool withCover = false}) => StarredResult(
  artists: <Artist>[
    Artist(id: 'artist-1', name: '收藏歌手', albumCount: 3, starred: true),
  ],
  albums: <Album>[
    Album(
      id: 'album-1',
      name: '收藏专辑',
      artist: '收藏歌手',
      songCount: 1,
      duration: 200,
      starred: true,
      coverArt: withCover ? 'album-cover' : null,
    ),
  ],
  songs: <Song>[
    Song(
      id: 'song-1',
      title: '收藏歌曲',
      artist: '收藏歌手',
      album: '收藏专辑',
      duration: 200,
      starred: true,
    ),
  ],
);

Playlist _playlist({bool withCover = false}) => Playlist(
  id: 'playlist-1',
  name: '收藏歌单',
  songCount: 8,
  duration: 1600,
  favorite: true,
  coverArt: withCover ? 'pl-cover' : null,
);

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpStarred(
  WidgetTester tester, {
  StarredTab initialTab = StarredTab.playlists,
  StarredResult? starred,
  List<Playlist>? playlists,
  RecordingPlayer? player,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith((Ref ref) => player ?? RecordingPlayer()),
        starredProvider.overrideWith(
          (Ref ref) async => starred ?? _filledStarred(),
        ),
        favoritePlaylistsProvider.overrideWith(
          (Ref ref) async => playlists ?? <Playlist>[_playlist()],
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          );
        },
        home: StarredPage(initialTab: initialTab),
      ),
    ),
  );
  await tester.pump();
  await settle(tester);
}

void main() {
  group('starred_page · 歌曲tab交互', () {
    testWidgets('点歌曲行 → playEffectiveQueue 以该行为起点整队播放', (tester) async {
      final player = RecordingPlayer();
      await pumpStarred(
        tester,
        initialTab: StarredTab.songs,
        starred: _filledStarred(),
        playlists: const <Playlist>[],
        player: player,
      );

      await tester.tap(find.text('收藏歌曲'));
      await tester.pump();
      await tester.pump();

      expect(player.queues, <List<String>>[<String>['song-1']]);
      expect(player.startIndices, <int>[0]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('当前播放歌曲行 isCurrent 高亮', (tester) async {
      final current = _filledStarred().songs.single;
      final player = RecordingPlayer(
        PlayerState(
          queue: <Song>[current],
          currentIndex: 0,
          currentSong: current,
        ),
      );
      await pumpStarred(
        tester,
        initialTab: StarredTab.songs,
        starred: _filledStarred(),
        playlists: const <Playlist>[],
        player: player,
      );

      final row = tester.widget<SongListItem>(
        find.widgetWithText(SongListItem, '收藏歌曲'),
      );
      expect(row.isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按歌曲行打开歌曲操作弹窗', (tester) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.songs,
        starred: _filledStarred(),
        playlists: const <Playlist>[],
      );

      await tester.longPress(find.text('收藏歌曲'));
      await settle(tester);

      expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('starred_page · 歌单tab交互', () {
    testWidgets('带封面歌单卡渲染 CoverArtImage,点击进歌单详情', (tester) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.playlists,
        playlists: <Playlist>[_playlist(withCover: true)],
      );

      expect(find.byType(CoverArtImage), findsOneWidget);

      await tester.tap(find.text('收藏歌单'));
      await settle(tester);

      expect(find.byType(PlaylistDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按歌单卡打开歌单操作弹窗', (tester) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.playlists,
        playlists: <Playlist>[_playlist()],
      );

      await tester.longPress(find.text('收藏歌单'));
      await settle(tester);

      expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大字体(≥1.6)歌单 tab 改用列表布局', (tester) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.playlists,
        playlists: <Playlist>[_playlist()],
        textScale: 1.8,
      );

      expect(
        find.byKey(const ValueKey<String>('starred-playlists-list-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('starred-playlists-grid-scroll')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('starred_page · 专辑tab交互', () {
    testWidgets('queueOrigin 匹配专辑 → 专辑卡 isNowPlaying,点击进专辑详情', (
      tester,
    ) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.albums,
        playlists: const <Playlist>[],
      );

      // 首帧后写入队列来源（StateProvider 直接写状态）。
      final BuildContext pageContext = tester.element(
        find.byType(StarredPage),
      );
      ProviderScope.containerOf(pageContext)
          .read(queueOriginProvider.notifier)
          .state = const QueueOrigin(QueueOriginKind.album, 'album-1');
      await tester.pump();

      final tile = tester.widget<MusicFlowAlbumTile>(
        find.widgetWithText(MusicFlowAlbumTile, '收藏专辑'),
      );
      expect(tile.isNowPlaying, isTrue);

      await tester.tap(find.text('收藏专辑'));
      await settle(tester);

      expect(find.byType(AlbumDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大字体(≥1.6)专辑 tab 改用行布局,点行进专辑详情', (tester) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.albums,
        playlists: const <Playlist>[],
        textScale: 2,
      );

      expect(
        find.byKey(const ValueKey<String>('starred-albums-list-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('starred-albums-grid-scroll')),
        findsNothing,
      );

      await tester.tap(find.text('收藏专辑'));
      await settle(tester);

      expect(find.byType(AlbumDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('starred_page · 歌手tab交互', () {
    testWidgets('点歌手行进歌手详情', (tester) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.artists,
        playlists: const <Playlist>[],
      );

      await tester.tap(find.text('收藏歌手'));
      await settle(tester);

      expect(find.byType(ArtistDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按歌手行打开歌手操作弹窗', (tester) async {
      await pumpStarred(
        tester,
        initialTab: StarredTab.artists,
        playlists: const <Playlist>[],
      );

      await tester.longPress(find.text('收藏歌手'));
      await settle(tester);

      expect(find.byType(MusicFlowBottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
