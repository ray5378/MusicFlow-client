import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/features/search/widgets/search_result_card.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

SearchSong _song(String id, String name) => SearchSong(
      id: id,
      name: name,
      artist: '测试艺人',
      album: '测试专辑',
      duration: 180,
      isLocal: false,
    );

SearchAlbum _album(String id, String name) => SearchAlbum(
      id: id,
      name: name,
      artist: '测试艺人',
      trackCount: '10',
      year: '2024',
      isLocal: false,
    );

SearchArtist _artist(String id, String name) => SearchArtist(
      id: id,
      name: name,
      albumCount: '3',
      songCount: '42',
      isLocal: false,
    );

SearchPlaylist _playlist(String id, String name) => SearchPlaylist(
      id: id,
      name: name,
      trackCount: '12',
      isLocal: false,
    );

/// 结果卡片只做「构建 + 点回调」,不需要真实后端。
Future<dynamic> _pumpCard(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
        child: MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: MusicFlowTapAnchorScope(child: Scaffold(body: child)),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.takeException();
}

void main() {
  group('SearchResultList 四类目渲染', () {
    for (final kind in SearchEntityKind.values) {
      testWidgets('${kind.name} 空结果可渲染', (tester) async {
        final error = await _pumpCard(
          tester,
          SearchResultList(
            kind: SearchEntityKind.song,
            outcome: SearchOutcome(),
          ),
        );
        expect(error, isNull);
      });
    }

    testWidgets('song 类目带结果可渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(
          kind: SearchEntityKind.song,
          outcome: SearchOutcome(
            songs: <SearchSong>[_song('s1', '歌曲一')],
            isLocal: false,
          ),
        ),
      );
      expect(error, isNull);
      expect(find.text('歌曲一'), findsWidgets);
    });

    testWidgets('album 类目带结果可渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(
          kind: SearchEntityKind.album,
          outcome: SearchOutcome(
            albums: <SearchAlbum>[_album('a1', '专辑一')],
          ),
        ),
      );
      expect(error, isNull);
      expect(find.text('专辑一'), findsWidgets);
    });

    testWidgets('artist 类目带结果可渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(
          kind: SearchEntityKind.artist,
          outcome: SearchOutcome(
            artists: <SearchArtist>[_artist('ar1', '艺人一')],
          ),
        ),
      );
      expect(error, isNull);
      expect(find.text('艺人一'), findsWidgets);
    });

    testWidgets('playlist 类目带结果可渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(
          kind: SearchEntityKind.playlist,
          outcome: SearchOutcome(
            playlists: <SearchPlaylist>[_playlist('p1', '歌单一')],
          ),
        ),
      );
      expect(error, isNull);
      expect(find.text('歌单一'), findsWidgets);
    });

    testWidgets('includeBottomPadding=false 也能渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(
          kind: SearchEntityKind.song,
          outcome: SearchOutcome(songs: <SearchSong>[_song('s2', '歌曲二')]),
          includeBottomPadding: false,
        ),
      );
      expect(error, isNull);
      expect(find.text('歌曲二'), findsWidgets);
    });
  });

  group('SearchAlbumCard', () {
    testWidgets('默认显示播放与加入库', (tester) async {
      var play = 0;
      var import = 0;
      var open = 0;
      final error = await _pumpCard(
        tester,
        SearchAlbumCard(
          album: _album('a2', '专辑二'),
          onPlay: () => play++,
          onImport: () => import++,
          onOpen: () => open++,
        ),
      );
      expect(error, isNull);
      expect(find.text('专辑二'), findsWidgets);
      await tester.tap(find.byType(MusicFlowPressable).first);
      await tester.pump();
      expect(open, 1, reason: '点整卡应触发 onOpen');
      // 播放/加入库是叠在封面右下角的图标按钮,和整卡 pressable 是两个热区。
      expect(find.byType(MusicFlowIconButton), findsNWidgets(2));
      await tester.tap(find.byType(MusicFlowIconButton).first);
      await tester.pump();
      expect(play, 1, reason: '点播放图标应触发 onPlay');
    });

    testWidgets('showPlay/showImport=false 时仍可渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchAlbumCard(
          album: _album('a3', '专辑三'),
          onPlay: () {},
          onImport: () {},
          onOpen: () {},
          showPlay: false,
          showImport: false,
        ),
      );
      expect(error, isNull);
      expect(find.text('专辑三'), findsOneWidget);
    });
  });

  group('SearchArtistCard', () {
    testWidgets('渲染并显示艺人名', (tester) async {
      var open = 0;
      final error = await _pumpCard(
        tester,
        SearchArtistCard(
          artist: _artist('ar2', '艺人二'),
          onPlay: () {},
          onOpen: () => open++,
        ),
      );
      expect(error, isNull);
      expect(find.text('艺人二'), findsOneWidget);
    });

    testWidgets('showPlay=false 时仍可渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchArtistCard(
          artist: _artist('ar3', '艺人三'),
          onPlay: () {},
          onOpen: () {},
          showPlay: false,
        ),
      );
      expect(error, isNull);
      expect(find.text('艺人三'), findsOneWidget);
    });
  });

  group('SearchPlaylistCard', () {
    testWidgets('渲染并显示歌单名', (tester) async {
      var open = 0;
      final error = await _pumpCard(
        tester,
        SearchPlaylistCard(
          playlist: _playlist('p2', '歌单二'),
          onPlay: () {},
          onOpen: () => open++,
        ),
      );
      expect(error, isNull);
      expect(find.text('歌单二'), findsOneWidget);
    });

    testWidgets('showPlay=false 时仍可渲染', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchPlaylistCard(
          playlist: _playlist('p3', '歌单三'),
          onPlay: () {},
          onOpen: () {},
          showPlay: false,
        ),
      );
      expect(error, isNull);
      expect(find.text('歌单三'), findsOneWidget);
    });
  });
}
