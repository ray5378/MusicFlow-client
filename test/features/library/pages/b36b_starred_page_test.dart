// batch36-B —— `lib/features/library/pages/starred_page.dart` 错误态重试与各 tab 下拉刷新补测。
//
// 已有 starred_page_cov_test.dart 覆盖空态/数据态/大字体/loading/错误态**渲染**与
// 歌单 tab 下拉刷新；b32c 覆盖四个 tab 的行点击/长按。仍有几处**回调闭包**没被真正触发：
//   * 四个 tab 错误态里「重试」按钮的 onAction（invalidate 对应 provider）;
//   * 歌曲/专辑/歌手三个 tab 的 MusicFlowRefreshView.onRefresh。
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
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

StarredResult _filled() => StarredResult(
      artists: <Artist>[Artist(id: 'artist-1', name: '收藏歌手', albumCount: 3)],
      albums: <Album>[
        Album(id: 'album-1', name: '收藏专辑', artist: '收藏歌手', songCount: 1, duration: 200),
      ],
      songs: <Song>[
        Song(id: 'song-1', title: '收藏歌曲', artist: '收藏歌手', duration: 200),
      ],
    );

Playlist _playlist() => Playlist(
      id: 'playlist-1',
      name: '收藏歌单',
      songCount: 8,
      duration: 1600,
      favorite: true,
    );

Future<void> _pump(
  WidgetTester tester, {
  StarredTab initialTab = StarredTab.playlists,
  required List<Override> overrides,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith((Ref ref) => TestPlayerNotifier(PlayerState())),
        ...overrides,
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (BuildContext context, Widget? child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: StarredPage(initialTab: initialTab),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  group('错误态「重试」回调', () {
    for (final tab in <StarredTab>[
      StarredTab.songs,
      StarredTab.albums,
      StarredTab.artists,
    ]) {
      testWidgets('${tab.name} 收藏加载失败点重试 → 重新订阅收藏 provider', (tester) async {
        var loads = 0;
        await _pump(
          tester,
          initialTab: tab,
          overrides: <Override>[
            starredProvider.overrideWith((Ref ref) async {
              loads += 1;
              throw StateError('starred down');
            }),
            favoritePlaylistsProvider.overrideWith(
              (Ref ref) async => const <Playlist>[],
            ),
          ],
        );
        expect(find.text('重试'), findsOneWidget);
        expect(loads, greaterThanOrEqualTo(1));

        final before = loads;
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(loads, greaterThan(before), reason: '重试应 invalidate 后重新拉取');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('歌单加载失败点重试 → 重新订阅收藏歌单 provider', (tester) async {
      var loads = 0;
      await _pump(
        tester,
        overrides: <Override>[
          starredProvider.overrideWith((Ref ref) async => _filled()),
          favoritePlaylistsProvider.overrideWith((Ref ref) async {
            loads += 1;
            throw StateError('playlists down');
          }),
        ],
      );
      expect(find.text('重试'), findsOneWidget);
      final before = loads;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(loads, greaterThan(before));
      expect(tester.takeException(), isNull);
    });
  });

  group('各 tab 下拉刷新回调', () {
    testWidgets('歌曲/专辑/歌手 tab 的下拉刷新都会重新加载', (tester) async {
      var starredLoads = 0;
      var playlistLoads = 0;
      await _pump(
        tester,
        initialTab: StarredTab.songs,
        overrides: <Override>[
          starredProvider.overrideWith((Ref ref) async {
            starredLoads += 1;
            return _filled();
          }),
          favoritePlaylistsProvider.overrideWith((Ref ref) async {
            playlistLoads += 1;
            return <Playlist>[_playlist()];
          }),
        ],
      );

      Future<void> pullRefresh() async {
        final refreshView = tester.widget<MusicFlowRefreshView>(
          find.byType(MusicFlowRefreshView).first,
        );
        await refreshView.onRefresh();
        await tester.pumpAndSettle();
      }

      // songs
      await pullRefresh();
      final afterSongsStarred = starredLoads;
      expect(afterSongsStarred, greaterThanOrEqualTo(2));

      // albums
      await tester.tap(find.text('专辑'));
      await tester.pumpAndSettle();
      await pullRefresh();
      expect(starredLoads, greaterThan(afterSongsStarred));

      // artists
      final afterAlbumsStarred = starredLoads;
      await tester.tap(find.text('歌手'));
      await tester.pumpAndSettle();
      await pullRefresh();
      expect(starredLoads, greaterThan(afterAlbumsStarred));
      expect(playlistLoads, greaterThanOrEqualTo(4));
      expect(tester.takeException(), isNull);
    });
  });
}
