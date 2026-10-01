import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/features/discover/widgets/discover_album_widgets.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/features/search/search_scope.dart';
import 'package:musicflow_client/features/search/widgets/search_scope_picker.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

late AppLocalizations loc;

Album _album(String id, String name) => Album(
      id: id,
      name: name,
      songCount: 3,
      duration: 180,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _pressableIn(Finder root) {
  final target =
      find.descendant(of: root, matching: find.byType(MusicFlowPressable));
  expect(target, findsOneWidget);
  return target;
}

void main() {
  setUp(() {
    loc = lookupAppLocalizations(const Locale('zh'));
  });

  group('SearchScopeTabs', () {
    testWidgets('渲染全部五档,选中档与传入值一致', (tester) async {
      SearchScope? last;
      await _pump(
        tester,
        SearchScopeTabs(
          value: SearchScope.song,
          onChanged: (s) => last = s,
        ),
      );
      expect(
        find.byType(MusicFlowPressable),
        findsNWidgets(SearchScope.values.length),
      );
      expect(find.text(loc.widgets_music), findsOneWidget);
      expect(last, isNull);
    });

    testWidgets('点击某档回传对应枚举', (tester) async {
      SearchScope? last;
      await _pump(
        tester,
        SearchScopeTabs(
          value: SearchScope.all,
          onChanged: (s) => last = s,
        ),
      );
      await tester.tap(find.text(loc.widgets_albums));
      await tester.pump();
      expect(last, SearchScope.album);
    });

    test('枚举顺序与 UI 展示顺序一致', () {
      final named = SearchScope.values.map((s) => s.name).toList();
      expect(named, ['all', 'playlist', 'song', 'artist', 'album']);
    });
  });

  group('SearchScopePanel', () {
    testWidgets('五档面板可渲染且点击回传', (tester) async {
      SearchScope? last;
      await _pump(
        tester,
        SearchScopePanel(
          value: SearchScope.all,
          onChanged: (s) => last = s,
        ),
      );
      expect(find.text(loc.search_scope_title), findsOneWidget);
      // 面板行用 RichText 渲染,按 MusicFlowPressable 顺序点击(枚举序 all→playlist…)
      final rows = find.byType(MusicFlowPressable);
      expect(rows, findsNWidgets(SearchScope.values.length));
      await tester.tap(rows.at(1));
      await tester.pump();
      expect(last, SearchScope.playlist);
    });
  });

  group('Discover 组件', () {
    testWidgets('DiscoverAlbumTile 点击与长按都回调', (tester) async {
      var pressed = 0;
      var longPressed = 0;
      await _pump(
        tester,
        DiscoverAlbumTile(
          album: _album('1', 'A'),
          onPressed: () => pressed++,
          onLongPress: () => longPressed++,
          width: 120,
        ),
      );
      final tile = find.byType(DiscoverAlbumTile);
      await tester.tap(_pressableIn(tile));
      await tester.pump();
      expect(pressed, 1);

      await tester.longPress(_pressableIn(tile));
      await tester.pump();
      expect(longPressed, 1);
    });

    testWidgets('DiscoverAlbumTile 宽度生效且 nowPlaying 态可渲染', (tester) async {
      await _pump(
        tester,
        DiscoverAlbumTile(
          album: _album('1', 'A'),
          onPressed: () {},
          width: 137,
          isNowPlaying: true,
        ),
        size: const Size(300, 600),
      );
      expect(tester.getSize(find.byType(DiscoverAlbumTile)).width, 137);
    });

    testWidgets('DiscoverRecentAlbumRail 窄容器走卡片分支并可点击', (tester) async {
      var tapped = 0;
      await _pump(
        tester,
        DiscoverRecentAlbumRail(
          albums: <Album>[_album('1', 'A'), _album('2', 'B')],
          onAlbumPressed: (_) => tapped++,
        ),
        size: const Size(360, 700),
      );
      // 正常字号:横向卡片轨道
      expect(find.byType(DiscoverRecentAlbumCard), findsNWidgets(2));
      expect(find.byType(MusicFlowAlbumRow), findsNothing);
      expect(find.byKey(const Key('discover-recent-spotlight')), findsOneWidget);
      await tester.tap(find.byType(MusicFlowPressable).first);
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('DiscoverRecentAlbumRail 大字号走 spotlight 分支', (tester) async {
      await _pump(
        tester,
        DiscoverRecentAlbumRail(
          albums: <Album>[_album('1', 'A'), _album('2', 'B')],
          onAlbumPressed: (_) {},
        ),
        size: const Size(360, 700),
        textScale: 1.6,
      );
      // 大字号:切到「spotlight 行列表」分支(两条分支刻意共用同一个 key)
      expect(find.byType(DiscoverRecentAlbumCard), findsNothing);
      expect(find.byType(MusicFlowAlbumRow), findsNWidgets(2));
      expect(find.byKey(const Key('discover-recent-spotlight')), findsOneWidget);
    });

    testWidgets('DiscoverAlbumRail / DiscoverFrequentAlbumShelf 可渲染', (tester) async {
      var count = 0;
      await _pump(
        tester,
        Column(
          children: <Widget>[
            DiscoverAlbumRail(
              albums: <Album>[_album('1', 'A')],
              onAlbumPressed: (_) => count++,
            ),
            DiscoverFrequentAlbumShelf(
              albums: <Album>[_album('2', 'B')],
              onAlbumPressed: (_) => count++,
            ),
          ],
        ),
        size: const Size(360, 900),
      );
      expect(find.byType(MusicFlowPressable), findsWidgets);
    });
  });

  group('MusicFlowTapAnchorScope', () {
    testWidgets('指针按下后记录全局坐标供锚点弹窗复用', (tester) async {
      musicFlowLastTapGlobalPosition = null;
      await _pump(
        tester,
        MusicFlowTapAnchorScope(
          child: const SizedBox(width: 80, height: 80),
        ),
        size: const Size(200, 200),
      );
      await tester.tapAt(const Offset(30, 40));
      await tester.pump();
      expect(musicFlowLastTapGlobalPosition, const Offset(30, 40));
    });
  });
}
