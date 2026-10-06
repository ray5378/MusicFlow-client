// batch37 C(2) —— `lib/features/discover/widgets/discover_album_widgets.dart` 剩余分支。
//
// 既有 b33c 已覆盖：Tile / RecentRail（常规/窄/大字号）/ RecentCard（空艺术家/
// nowPlaying+长按）/ AlbumRail（常规/窄+大字号）/ FrequentShelf（分组/窄）/ 三个 Loading。
// 本文件补：
//   * DiscoverRecentAlbumCard 有艺术家 → 元数据含「艺术家 · N 首」；
//   * 各 Rail/Shelf 传入 onAlbumLongPress 时的长按回调透传（卡片与行两路）；
//   * RecentRail 中带宽档位（260≤w<330 → 240；330≤w<360 → 280）；
//   * 三个 Loading 的窄视口宽度档位分支。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/features/discover/widgets/discover_album_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

final List<Album> kAlbums = <Album>[
  Album(id: 'al1', name: '专辑一', artist: '艺术家甲', artistId: 'ar1', songCount: 10, duration: 600),
  Album(id: 'al2', name: '专辑二', artist: '艺术家乙', artistId: 'ar2', songCount: 3, duration: 200),
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
      builder: (BuildContext context, Widget? c) {
        loc = AppLocalizations.of(context);
        return c!;
      },
      home: ProviderScope(
        child: MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
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

Future<void> _longPress(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.up();
  await settle(tester);
}

void main() {
  testWidgets('DiscoverRecentAlbumCard 有艺术家 → 元数据含艺术家与曲目数', (tester) async {
    final loc = await _pump(
      tester,
      SizedBox(
        width: 320,
        height: 170,
        child: DiscoverRecentAlbumCard(
          album: kAlbums[0],
          width: 320,
          height: 170,
          onPressed: () {},
        ),
      ),
    );

    expect(find.textContaining('艺术家甲'), findsOneWidget);
    expect(find.textContaining(loc.discover_recent_song_count('10')), findsOneWidget);
    expect(find.text('专辑一'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiscoverRecentAlbumRail 传入 onAlbumLongPress → 卡片长按透传', (tester) async {
    final pressed = <String>[];
    await _pump(
      tester,
      DiscoverRecentAlbumRail(
        albums: kAlbums,
        onAlbumPressed: (Album a) {},
        onAlbumLongPress: (Album a) => pressed.add(a.id),
      ),
      size: const Size(800, 900),
    );

    await _longPress(tester, find.text('专辑一').first);
    expect(pressed, <String>['al1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiscoverAlbumRail 大字号 + onLongPress → 行长按透传', (tester) async {
    final pressed = <String>[];
    await _pump(
      tester,
      DiscoverAlbumRail(
        albums: kAlbums,
        onAlbumPressed: (Album a) {},
        onAlbumLongPress: (Album a) => pressed.add(a.id),
      ),
      size: const Size(800, 1600),
      textScaler: const TextScaler.linear(2.0),
    );

    await _longPress(tester, find.text('专辑二').first);
    expect(pressed, <String>['al2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiscoverFrequentAlbumShelf onLongPress：窄屏行布局 + 常规分组均透传', (tester) async {
    final pressed = <String>[];
    // 窄屏 → 无障碍行布局（useAccessibleList）。
    await _pump(
      tester,
      DiscoverFrequentAlbumShelf(
        albums: kAlbums,
        onAlbumPressed: (Album a) {},
        onAlbumLongPress: (Album a) => pressed.add(a.id),
      ),
      size: const Size(240, 1200),
    );
    await _longPress(tester, find.text('专辑一').first);
    expect(pressed, contains('al1'));

    // 常规宽度 → 两两分组内的行布局。
    final pressed2 = <String>[];
    await _pump(
      tester,
      DiscoverFrequentAlbumShelf(
        albums: kAlbums,
        onAlbumPressed: (Album a) {},
        onAlbumLongPress: (Album a) => pressed2.add(a.id),
      ),
      size: const Size(800, 900),
    );
    await _longPress(tester, find.text('专辑二').first);
    expect(pressed2, contains('al2'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiscoverRecentAlbumRail 中带宽档位（260/330/350）渲染不抛', (tester) async {
    for (final w in <double>[260, 300, 330, 350]) {
      await _pump(
        tester,
        DiscoverRecentAlbumRail(
          albums: kAlbums,
          onAlbumPressed: (Album a) {},
        ),
        size: Size(w, 900),
      );
      expect(find.byKey(const Key('discover-recent-spotlight')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('三个 Loading 的窄视口宽度档位渲染不抛', (tester) async {
    for (final w in <double>[240, 300, 350, 380]) {
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
        size: Size(w, 1200),
      );
      expect(find.byType(DiscoverRecentAlbumLoading), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
