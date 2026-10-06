// batch36-B —— `lib/features/search/widgets/search_result_card.dart` 剩余分支补测。
//
// 已有 search_result_card_coverage_gap_test.dart 覆盖「渲染 + 回调」、
// b35c_search_result_card_test.dart 覆盖回调链与 compact 阶梯。仍有若干**条件分支**
// 从未被走到：
//   * album/artist/playlist 空结果 → _cardGrid 的 `children.isEmpty` 早退;
//   * 专辑/歌单副标题在 artist / trackCount 为空时回退 platformLabel;
//   * 歌曲行 artist 为空时元数据行只剩 platformLabel（where 过滤空串）;
//   * SearchAlbumCard 只显示播放 / 只显示入库的两组 showPlay/showImport 组合。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/features/search/widgets/search_result_card.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

SearchSong _song(String id, String name, {String artist = '', String platformLabel = ''}) =>
    SearchSong(id: id, name: name, artist: artist, platformLabel: platformLabel);

SearchAlbum _album(
  String id,
  String name, {
  String artist = '',
  String platformLabel = '',
}) =>
    SearchAlbum(
      id: id,
      name: name,
      artist: artist,
      platformLabel: platformLabel,
    );

SearchArtist _artist(String id, String name, {String platformLabel = ''}) =>
    SearchArtist(id: id, name: name, platformLabel: platformLabel);

SearchPlaylist _playlist(
  String id,
  String name, {
  String trackCount = '',
  String platformLabel = '',
}) =>
    SearchPlaylist(
      id: id,
      name: name,
      trackCount: trackCount,
      platformLabel: platformLabel,
    );

Future<Object?> _pumpCard(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        theme: AppTheme.light(),
        home: MusicFlowTapAnchorScope(child: Scaffold(body: child)),
      ),
    ),
  );
  await tester.pump();
  return tester.takeException();
}

void main() {
  group('SearchResultList 空网格早退', () {
    testWidgets('album 空结果 → 不渲染网格', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(kind: SearchEntityKind.album, outcome: SearchOutcome()),
      );
      expect(error, isNull);
      expect(find.byType(GridView), findsNothing);
    });

    testWidgets('artist 空结果 → 不渲染网格', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(kind: SearchEntityKind.artist, outcome: SearchOutcome()),
      );
      expect(error, isNull);
      expect(find.byType(GridView), findsNothing);
    });

    testWidgets('playlist 空结果 → 不渲染网格', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(kind: SearchEntityKind.playlist, outcome: SearchOutcome()),
      );
      expect(error, isNull);
      expect(find.byType(GridView), findsNothing);
    });
  });

  group('歌曲行元数据回退', () {
    testWidgets('artist 为空 → 元数据行只剩 platformLabel', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchResultList(
          kind: SearchEntityKind.song,
          outcome: SearchOutcome(
            songs: <SearchSong>[
              _song('s1', '只带来源的试听', platformLabel: '网易云'),
            ],
          ),
        ),
      );
      expect(error, isNull);
      expect(find.text('网易云'), findsOneWidget);
    });
  });

  group('SearchAlbumCard 副标题与按钮组合', () {
    testWidgets('artist 为空 → 副标题显示 platformLabel', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchAlbumCard(
          album: _album('a1', '无艺人专辑', platformLabel: '酷狗'),
          onPlay: () {},
          onImport: () {},
          onOpen: () {},
        ),
      );
      expect(error, isNull);
      expect(find.text('酷狗'), findsOneWidget);
    });

    testWidgets('只显示播放按钮 → 仅 1 个图标按钮', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchAlbumCard(
          album: _album('a2', '仅播放专辑'),
          onPlay: () {},
          onImport: () {},
          onOpen: () {},
          showImport: false,
        ),
      );
      expect(error, isNull);
      expect(find.byType(MusicFlowIconButton), findsOneWidget);
    });

    testWidgets('只显示入库按钮 → 仅 1 个图标按钮', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchAlbumCard(
          album: _album('a3', '仅入库专辑'),
          onPlay: () {},
          onImport: () {},
          onOpen: () {},
          showPlay: false,
        ),
      );
      expect(error, isNull);
      expect(find.byType(MusicFlowIconButton), findsOneWidget);
    });
  });

  group('SearchPlaylistCard 副标题回退', () {
    testWidgets('trackCount 为空 → 副标题显示 platformLabel', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchPlaylistCard(
          playlist: _playlist('p1', '未知曲数歌单', platformLabel: 'QQ音乐'),
          onPlay: () {},
          onOpen: () {},
        ),
      );
      expect(error, isNull);
      expect(find.text('QQ音乐'), findsOneWidget);
    });

    testWidgets('trackCount 非空 → 显示「共 N 首」而不是来源', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchPlaylistCard(
          playlist: _playlist('p2', '有曲数歌单', trackCount: '18', platformLabel: 'QQ音乐'),
          onPlay: () {},
          onOpen: () {},
        ),
      );
      final loc = AppLocalizations.of(
        tester.element(find.byType(SearchPlaylistCard)),
      );
      expect(error, isNull);
      expect(find.text(loc.search_song_count('18')), findsOneWidget);
      expect(find.text('QQ音乐'), findsNothing);
    });
  });

  group('SearchArtistCard 副标题', () {
    testWidgets('渲染 platformLabel 副标题', (tester) async {
      final error = await _pumpCard(
        tester,
        SearchArtistCard(
          artist: _artist('ar1', '某歌手', platformLabel: '虾米'),
          onPlay: () {},
          onOpen: () {},
        ),
      );
      expect(error, isNull);
      expect(find.text('某歌手'), findsOneWidget);
      expect(find.text('虾米'), findsOneWidget);
    });
  });
}
