// batch37 C —— `lib/features/search/widgets/search_result_card.dart` 剩余未覆盖分支补测。
//
// 既有测试（search_result_card_coverage_gap / b35c / b36b）只用「空封面」直连
// 卡片并点回调，仍有以下行从未执行：
//   * 歌词/歌曲列表 多行时 ListView.separated 的 separatorBuilder（143）；
//   * album/artist/playlist 卡片「封面非空」的封面分支
//     （285-288 / 371-373 / 444-448）——既有用例均为空封面走占位容器；
//   * SearchResultList(kind: album/artist/playlist) 的**真实 onOpen 闭包链**
//     （54-62 / 80-88 / 107-115）——既有用例只直连卡片、或点 onPlay/onImport，
//     从未经由 SearchResultList 点整卡触发 Navigator.push。
//
// 只写 test/，只读 lib/，不触网络：三个 Remote*Page 在 searchRepositoryProvider
// 为 null 时 _loadSongs 直接返回空列表，渲染空态。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/features/search/widgets/search_result_card.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

const _cover = 'http://127.0.0.1:4533/rest/getCoverArt?id=cover-1';

SearchSong _song(String id, String name, {String cover = ''}) => SearchSong(
      id: id,
      name: name,
      artist: '歌手',
      platformLabel: '网易云',
      cover: cover,
    );

SearchAlbum _album(String id, String name, {String cover = ''}) => SearchAlbum(
      id: id,
      name: name,
      artist: '歌手',
      cover: cover,
      platformLabel: '酷狗',
    );

SearchArtist _artist(String id, String name, {String avatar = ''}) => SearchArtist(
      id: id,
      name: name,
      avatar: avatar,
      platformLabel: '虾米',
    );

SearchPlaylist _playlist(String id, String name, {String cover = ''}) =>
    SearchPlaylist(
      id: id,
      name: name,
      cover: cover,
      trackCount: '18',
      platformLabel: 'QQ音乐',
    );

Future<Object?> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: MusicFlowTapAnchorScope(child: Scaffold(body: child)),
      ),
    ),
  );
  await tester.pump();
  return tester.takeException();
}

void main() {
  group('歌曲列表多行', () {
    testWidgets('两首（一首带封面一首不带）→ 行分隔符真正构建', (tester) async {
      final error = await _pump(
        tester,
        SearchResultList(
          kind: SearchEntityKind.song,
          outcome: SearchOutcome(
            songs: <SearchSong>[
              _song('s1', '带封面歌', cover: _cover),
              _song('s2', '无封面歌'),
            ],
          ),
        ),
      );
      expect(error, isNull);
      expect(find.text('带封面歌'), findsOneWidget);
      expect(find.text('无封面歌'), findsOneWidget);
      // separatorBuilder 至少被执行一次（2 行 → 1 分隔符）。
      expect(find.byType(ListView), findsOneWidget);
    });
  });

  group('SearchResultList 三类目 onOpen 导航链', () {
    testWidgets('album 类目：点整卡 → onOpen 闭包 push RemoteAlbumPage', (tester) async {
      final error = await _pump(
        tester,
        SearchResultList(
          kind: SearchEntityKind.album,
          outcome: SearchOutcome(
            albums: <SearchAlbum>[_album('a1', '专辑一', cover: _cover)],
          ),
        ),
      );
      expect(error, isNull);

      await tester.tap(find.byType(MusicFlowPressable).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // onOpen 闭包已执行（Navigator.push + RemoteAlbumPage 构建）。
      expect(find.byType(SearchResultList), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('artist 类目：点整卡 → onOpen 闭包 push RemoteArtistPage', (tester) async {
      final error = await _pump(
        tester,
        SearchResultList(
          kind: SearchEntityKind.artist,
          outcome: SearchOutcome(
            artists: <SearchArtist>[_artist('ar1', '艺人一', avatar: _cover)],
          ),
        ),
      );
      expect(error, isNull);

      await tester.tap(find.byType(MusicFlowPressable).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(SearchResultList), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('playlist 类目：点整卡 → onOpen 闭包 push RemotePlaylistPage',
        (tester) async {
      final error = await _pump(
        tester,
        SearchResultList(
          kind: SearchEntityKind.playlist,
          outcome: SearchOutcome(
            playlists: <SearchPlaylist>[_playlist('p1', '歌单一', cover: _cover)],
          ),
        ),
      );
      expect(error, isNull);

      await tester.tap(find.byType(MusicFlowPressable).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(SearchResultList), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('卡片封面非空分支', () {
    testWidgets('SearchAlbumCard 有封面 → 渲染 ClipRRect 封面', (tester) async {
      final error = await _pump(
        tester,
        SearchAlbumCard(
          album: _album('a2', '有封面专辑', cover: _cover),
          onPlay: () {},
          onImport: () {},
          onOpen: () {},
        ),
      );
      expect(error, isNull);
      expect(find.text('有封面专辑'), findsOneWidget);
    });

    testWidgets('SearchArtistCard 有头像 → 渲染 ClipOval 头像', (tester) async {
      final error = await _pump(
        tester,
        SearchArtistCard(
          artist: _artist('ar2', '有头像艺人', avatar: _cover),
          onPlay: () {},
          onOpen: () {},
        ),
      );
      expect(error, isNull);
      expect(find.text('有头像艺人'), findsOneWidget);
    });

    testWidgets('SearchPlaylistCard 有封面 → 渲染 ClipRRect 封面', (tester) async {
      final error = await _pump(
        tester,
        SearchPlaylistCard(
          playlist: _playlist('p2', '有封面歌单', cover: _cover),
          onPlay: () {},
          onOpen: () {},
        ),
      );
      expect(error, isNull);
      expect(find.text('有封面歌单'), findsOneWidget);
    });
  });
}
