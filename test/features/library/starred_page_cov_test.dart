import 'dart:async';

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
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../player/test_player_notifier.dart';

void main() {
  final emptyStarred = StarredResult(
    artists: const <Artist>[],
    albums: const <Album>[],
    songs: const <Song>[],
  );

  for (final entry in <(StarredTab, String)>[
    (StarredTab.playlists, '暂无收藏歌单'),
    (StarredTab.songs, '暂无收藏歌曲'),
    (StarredTab.albums, '暂无收藏专辑'),
    (StarredTab.artists, '暂无收藏歌手'),
  ]) {
    testWidgets('空收藏渲染 ${entry.$1.name} 空态', (tester) async {
      await _pumpStarred(
        tester,
        initialTab: entry.$1,
        starred: emptyStarred,
        playlists: const <Playlist>[],
      );

      expect(find.text(entry.$2), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('starred-empty-scroll')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('四个收藏 tab 可切换并展示各自数据', (tester) async {
    final player = _RecordingPlayerNotifier();
    await _pumpStarred(
      tester,
      starred: _filledStarred(),
      playlists: <Playlist>[_playlist()],
      player: player,
    );

    expect(find.text('共收藏 4 项'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('starred-playlists-grid-scroll')),
      findsOneWidget,
    );
    expect(find.text('收藏歌单'), findsOneWidget);

    await tester.tap(find.text('歌曲'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('starred-songs-scroll')),
      findsOneWidget,
    );
    expect(find.text('收藏歌曲'), findsOneWidget);
    await tester.tap(find.text('播放全部'));
    await tester.pump();
    expect(player.queues.single.single.id, 'song-1');

    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('starred-albums-grid-scroll')),
      findsOneWidget,
    );
    expect(find.text('收藏专辑'), findsOneWidget);

    await tester.tap(find.text('歌手'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('starred-artists-scroll')),
      findsOneWidget,
    );
    expect(find.text('收藏歌手'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字体时歌单和专辑改用列表布局', (tester) async {
    await _pumpStarred(
      tester,
      starred: _filledStarred(),
      playlists: <Playlist>[_playlist()],
      textScale: 2,
    );
    expect(
      find.byKey(const ValueKey<String>('starred-playlists-list-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('starred-playlists-grid-scroll')),
      findsNothing,
    );

    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('starred-albums-list-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('starred-albums-grid-scroll')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('收藏数据 loading 分支渲染骨架', (tester) async {
    final starredPending = Completer<StarredResult>();
    final playlistsPending = Completer<List<Playlist>>();
    await _pumpStarredWithOverrides(
      tester,
      overrides: <Override>[
        starredProvider.overrideWith((ref) => starredPending.future),
        favoritePlaylistsProvider.overrideWith(
          (ref) => playlistsPending.future,
        ),
      ],
      settle: false,
    );

    expect(find.byType(MusicFlowAlbumGridSkeleton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单 Future 异常渲染可重试错误态', (tester) async {
    await _pumpStarredWithOverrides(
      tester,
      overrides: <Override>[
        starredProvider.overrideWith((ref) async => emptyStarred),
        favoritePlaylistsProvider.overrideWith(
          (ref) => Future<List<Playlist>>.error(StateError('playlist failed')),
        ),
      ],
    );

    expect(find.text('歌单加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌单降级为空且失败标记为真时渲染错误态', (tester) async {
    await _pumpStarred(
      tester,
      starred: emptyStarred,
      playlists: const <Playlist>[],
      playlistsLoadFailed: true,
    );

    expect(find.text('歌单加载失败'), findsOneWidget);
    expect(find.text('暂无收藏歌单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final entry in <(StarredTab, String)>[
    (StarredTab.songs, '收藏加载失败'),
    (StarredTab.albums, '收藏加载失败'),
    (StarredTab.artists, '收藏加载失败'),
  ]) {
    testWidgets('收藏 Future 异常渲染 ${entry.$1.name} 错误态', (tester) async {
      await _pumpStarredWithOverrides(
        tester,
        initialTab: entry.$1,
        overrides: <Override>[
          starredProvider.overrideWith(
            (ref) => Future<StarredResult>.error(StateError('starred failed')),
          ),
          favoritePlaylistsProvider.overrideWith(
            (ref) async => const <Playlist>[],
          ),
        ],
      );

      expect(find.text(entry.$2), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('下拉刷新会重新加载收藏与收藏歌单', (tester) async {
    var starredLoads = 0;
    var playlistLoads = 0;
    await _pumpStarredWithOverrides(
      tester,
      overrides: <Override>[
        starredProvider.overrideWith((ref) async {
          starredLoads += 1;
          return emptyStarred;
        }),
        favoritePlaylistsProvider.overrideWith((ref) async {
          playlistLoads += 1;
          return const <Playlist>[];
        }),
      ],
    );

    final refreshView = tester.widget<MusicFlowRefreshView>(
      find.byType(MusicFlowRefreshView),
    );
    await refreshView.onRefresh();
    await tester.pumpAndSettle();

    expect(starredLoads, 2);
    expect(playlistLoads, 2);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpStarred(
  WidgetTester tester, {
  StarredTab initialTab = StarredTab.playlists,
  required StarredResult starred,
  required List<Playlist> playlists,
  bool starredLoadFailed = false,
  bool playlistsLoadFailed = false,
  double textScale = 1,
  _RecordingPlayerNotifier? player,
}) {
  return _pumpStarredWithOverrides(
    tester,
    initialTab: initialTab,
    textScale: textScale,
    player: player,
    overrides: <Override>[
      starredProvider.overrideWith((ref) async => starred),
      favoritePlaylistsProvider.overrideWith((ref) async => playlists),
      starredLoadFailedProvider.overrideWith((ref) => starredLoadFailed),
      favoritePlaylistsLoadFailedProvider.overrideWith(
        (ref) => playlistsLoadFailed,
      ),
    ],
  );
}

Future<void> _pumpStarredWithOverrides(
  WidgetTester tester, {
  StarredTab initialTab = StarredTab.playlists,
  required List<Override> overrides,
  bool settle = true,
  double textScale = 1,
  _RecordingPlayerNotifier? player,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1000);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith(
          (ref) => player ?? _RecordingPlayerNotifier(),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
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
        home: StarredPage(initialTab: initialTab),
      ),
    ),
  );
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

StarredResult _filledStarred() => StarredResult(
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

Playlist _playlist() => Playlist(
  id: 'playlist-1',
  name: '收藏歌单',
  songCount: 8,
  duration: 1600,
  favorite: true,
);

class _RecordingPlayerNotifier extends TestPlayerNotifier {
  _RecordingPlayerNotifier() : super(PlayerState());

  final List<List<Song>> queues = <List<Song>>[];

  @override
  Future<void> playQueue(
    List<Song> songs, {
    bool shuffleRandomStart = false,
    int startIndex = 0,
    Duration? initialPosition,
  }) async {
    queues.add(List<Song>.of(songs));
  }
}
