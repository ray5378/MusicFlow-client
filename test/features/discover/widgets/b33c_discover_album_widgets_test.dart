// batch33 C 路 —— `lib/features/discover/widgets/discover_album_widgets.dart` 补测。
//
// 基线覆盖率 50.59%。全部是纯 StatelessWidget，无 Riverpod 依赖。核心分支：
//   * 每个 Rail/Shelf/Loading 都在 LayoutBuilder 里按两维分叉：
//       - textScaler.scale(1) > 1.3 → 纵向 Column 的「无障碍行布局」；
//       - 宽度阈值（<260 / <280 / <330 / <340 / <360 / <400）→ 卡片/瓦片宽度档位。
//   * DiscoverFrequentAlbumShelf 两两分组：groupCount = (n+1)~/2。
//   * DiscoverRecentAlbumCard 的 isNowPlaying → NowPlayingCoverOverlay 叠层。
// 骨架屏 MusicFlowSkeleton 是无限动画，统一有界 pump，不用 pumpAndSettle。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/features/discover/widgets/discover_album_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';

final List<Album> kAlbums = <Album>[
  Album(id: 'al1', name: '专辑一', artist: '艺术家甲', artistId: 'ar1', songCount: 10, duration: 600),
  Album(id: 'al2', name: '专辑二', artist: '艺术家乙', artistId: 'ar2', songCount: 3, duration: 200),
  Album(id: 'al3', name: '专辑三', artist: '', artistId: 'ar3', songCount: 0, duration: 0),
];

Future<AppLocalizations> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(800, 900),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  late AppLocalizations loc;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (BuildContext context, Widget? child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: ProviderScope(
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: textScaler,
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 40));
  return loc;
}

Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  group('DiscoverAlbumTile', () {
    testWidgets('渲染专辑名 + 点击回调', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        DiscoverAlbumTile(
          album: kAlbums[0],
          width: 160,
          onPressed: () => taps += 1,
        ),
      );

      expect(find.text('专辑一'), findsOneWidget);
      await tester.tap(find.text('专辑一'));
      await settle(tester);
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('isNowPlaying → 封面叠 NowPlayingCoverOverlay', (tester) async {
      await _pump(
        tester,
        DiscoverAlbumTile(
          album: kAlbums[0],
          width: 160,
          isNowPlaying: true,
          onPressed: () {},
        ),
      );

      expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DiscoverRecentAlbumRail', () {
    testWidgets('常规宽度 → 横向卡片列表（最近在听卡渲染专辑名/艺术家）', (tester) async {
      var pressed = 0;
      await _pump(
        tester,
        DiscoverRecentAlbumRail(
          albums: kAlbums,
          onAlbumPressed: (Album a) => pressed += 1,
        ),
        size: const Size(800, 900),
      );

      expect(find.byKey(const Key('discover-recent-spotlight')), findsOneWidget);
      expect(find.text('专辑一'), findsOneWidget);
      expect(find.textContaining('艺术家甲'), findsOneWidget);
      await tester.tap(find.text('专辑一').first);
      await settle(tester);
      expect(pressed, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄视口(<260) → 卡片宽度取视口全宽档位', (tester) async {
      await _pump(
        tester,
        DiscoverRecentAlbumRail(
          albums: kAlbums,
          onAlbumPressed: (Album a) {},
        ),
        size: const Size(220, 900),
      );

      expect(find.byKey(const Key('discover-recent-spotlight')), findsOneWidget);
      expect(find.text('专辑一'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大字号(textScaler 2.0) → 纵向无障碍行布局', (tester) async {
      await _pump(
        tester,
        DiscoverRecentAlbumRail(
          albums: kAlbums,
          onAlbumPressed: (Album a) {},
        ),
        size: const Size(800, 1400),
        textScaler: const TextScaler.linear(2.0),
      );

      expect(find.byKey(const Key('discover-recent-spotlight')), findsOneWidget);
      // 行布局：三张专辑各占一行，专辑名都直接可见。
      expect(find.text('专辑一'), findsOneWidget);
      expect(find.text('专辑二'), findsOneWidget);
      expect(find.text('专辑三'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DiscoverRecentAlbumCard', () {
    testWidgets('艺术家为空 → 元数据行只剩曲目数语义', (tester) async {
      final loc = await _pump(
        tester,
        SizedBox(
          width: 320,
          height: 170,
          child: DiscoverRecentAlbumCard(
            album: kAlbums[2],
            width: 320,
            height: 170,
            onPressed: () {},
          ),
        ),
      );

      expect(
        find.text(loc.discover_recent_song_count('0')),
        findsOneWidget,
        reason: 'artist 为空时 metadata 只有 songCount 一段',
      );
      expect(find.text('专辑三'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('isNowPlaying → 叠加播放遮罩 + 长按回调透传', (tester) async {
      var longPressed = 0;
      await _pump(
        tester,
        SizedBox(
          width: 320,
          height: 170,
          child: DiscoverRecentAlbumCard(
            album: kAlbums[0],
            width: 320,
            height: 170,
            isNowPlaying: true,
            onPressed: () {},
            onLongPress: () => longPressed += 1,
          ),
        ),
      );

      expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('专辑一')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await settle(tester);
      expect(longPressed, 1, reason: '长按透传 onAlbumLongPress');
      expect(tester.takeException(), isNull);
    });
  });

  group('DiscoverAlbumRail', () {
    testWidgets('常规宽度 → 瓦片渲染 + 点击回调', (tester) async {
      var pressed = 0;
      await _pump(
        tester,
        DiscoverAlbumRail(
          albums: kAlbums,
          onAlbumPressed: (Album a) => pressed += 1,
        ),
        size: const Size(800, 900),
      );

      expect(find.byKey(const Key('discover-newest-rail')), findsOneWidget);
      expect(find.text('专辑一'), findsOneWidget);
      await tester.tap(find.text('专辑一').first);
      await settle(tester);
      expect(pressed, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄视口(<400) → 小档瓦片 + 大字号走行布局', (tester) async {
      await _pump(
        tester,
        DiscoverAlbumRail(
          albums: kAlbums,
          onAlbumPressed: (Album a) {},
        ),
        size: const Size(360, 900),
      );
      expect(find.byKey(const Key('discover-newest-rail')), findsOneWidget);

      await _pump(
        tester,
        DiscoverAlbumRail(
          albums: kAlbums,
          onAlbumPressed: (Album a) {},
        ),
        size: const Size(800, 1600),
        textScaler: const TextScaler.linear(2.0),
      );
      expect(find.text('专辑一'), findsOneWidget);
      expect(find.text('专辑二'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DiscoverFrequentAlbumShelf', () {
    testWidgets('3 张专辑 → 两两分组(2 组) + 组内行点击回调', (tester) async {
      final pressed = <String>[];
      await _pump(
        tester,
        DiscoverFrequentAlbumShelf(
          albums: kAlbums,
          onAlbumPressed: (Album a) => pressed.add(a.id),
        ),
        size: const Size(800, 900),
      );

      expect(find.byKey(const Key('discover-frequent-shelf')), findsOneWidget);
      expect(
        find.byKey(const Key('discover-frequent-group-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('discover-frequent-group-1')),
        findsOneWidget,
        reason: '(3+1)~/2 = 2 组，第二组只装 1 张',
      );

      await tester.tap(find.text('专辑一').first);
      await settle(tester);
      expect(pressed, <String>['al1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄视口(<280) → 纵向无障碍行布局', (tester) async {
      await _pump(
        tester,
        DiscoverFrequentAlbumShelf(
          albums: kAlbums,
          onAlbumPressed: (Album a) {},
        ),
        size: const Size(240, 1200),
      );

      expect(find.byKey(const Key('discover-frequent-shelf')), findsOneWidget);
      expect(find.text('专辑一'), findsOneWidget);
      expect(find.text('专辑三'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('加载骨架', () {
    testWidgets('三个 Loading 组件常规宽度渲染骨架', (tester) async {
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            DiscoverRecentAlbumLoading(count: 2),
            DiscoverAlbumLoading(count: 3),
            DiscoverFrequentAlbumLoading(count: 3),
          ],
        ),
        size: const Size(800, 1200),
      );

      expect(find.byType(DiscoverRecentAlbumLoading), findsOneWidget);
      expect(find.byType(DiscoverAlbumLoading), findsOneWidget);
      expect(find.byType(DiscoverFrequentAlbumLoading), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大字号 → 骨架走纵向行布局分支', (tester) async {
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            DiscoverRecentAlbumLoading(count: 2),
            DiscoverAlbumLoading(count: 2),
            DiscoverFrequentAlbumLoading(count: 2),
          ],
        ),
        size: const Size(800, 1600),
        textScaler: const TextScaler.linear(2.0),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('Loading 的窄视口宽度档位分支', (tester) async {
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            DiscoverRecentAlbumLoading(count: 1),
            DiscoverAlbumLoading(count: 1),
            DiscoverFrequentAlbumLoading(count: 1),
          ],
        ),
        size: const Size(240, 1200),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
