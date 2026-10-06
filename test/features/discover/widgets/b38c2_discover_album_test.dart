// Route C 补测：`lib/features/discover/widgets/discover_album_widgets.dart`
//
// 覆盖点：
//   * 70/73：`DiscoverRecentAlbumRail` 无障碍大字号分支（textScale > 1.3）
//           下的行式列表 —— 点击与长按回调。
//   * 281：`DiscoverAlbumRail` 无障碍分支下的点击回调。
//   * 311：`DiscoverAlbumRail` 常规横滑分支下的长按回调。
//   * 352：`DiscoverFrequentAlbumShelf` 无障碍分支下的点击回调。
//   * 362：窄容器（maxWidth < 340）时卡片宽度上限退化为容器宽度。
//   * 471/559/615：三个 Loading 骨架组件的构造函数（此前全库无构造点）。
//
// 跳过并报告：
//   * 365 / 643：`minimumWidth = constraints.maxWidth < 280 ? ... : 280` 的
//     true 侧 —— 上方 `useAccessibleList = scale >= 1.3 || maxWidth < 280`
//     （源码 335 行）在 `maxWidth < 280` 时已经提前 return，永远走不到这两行
//     ⇒ 不可达的防御性分支。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/features/discover/widgets/discover_album_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

Album _album(String id, String name) => Album(
      id: id,
      name: name,
      artist: '歌手-$id',
      songCount: 10,
      duration: 600,
    );

/// [width] 决定 LayoutBuilder 的 maxWidth，[textScale] 决定无障碍分支。
Widget _host(Widget child, {double width = 800, double textScale = 1}) =>
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: TextScaler.linear(textScale),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('最近专辑 rail（大字号）行式列表：点击 / 长按（70/73）',
      (tester) async {
    final pressed = <Album>[];
    final longPressed = <Album>[];
    final album = _album('a1', '最近专辑一');

    await tester.pumpWidget(
      _host(
        DiscoverRecentAlbumRail(
          albums: <Album>[album],
          onAlbumPressed: pressed.add,
          onAlbumLongPress: longPressed.add,
        ),
        textScale: 1.5,
      ),
    );
    await tester.pumpAndSettle();

    // [D-007 已修复] spotlight 分支使用独立 key。
    expect(find.byKey(const Key('discover-recent-spotlight-spot')), findsOneWidget);

    await tester.tap(find.text('最近专辑一'));
    await tester.pumpAndSettle();
    expect(pressed, <Album>[album], reason: '70 行：点击整行应回调 onAlbumPressed');

    await tester.longPress(find.text('最近专辑一'));
    await tester.pumpAndSettle();
    expect(longPressed, <Album>[album], reason: '73 行：长按应回调 onAlbumLongPress');
    expect(tester.takeException(), isNull);
  });

  testWidgets('最新专辑 rail（大字号）行式列表：点击（281）', (tester) async {
    final pressed = <Album>[];
    final album = _album('a2', '最新专辑一');

    await tester.pumpWidget(
      _host(
        DiscoverAlbumRail(
          albums: <Album>[album],
          onAlbumPressed: pressed.add,
        ),
        textScale: 1.5,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('最新专辑一'));
    await tester.pumpAndSettle();
    expect(pressed, <Album>[album], reason: '281 行：点击整行应回调 onAlbumPressed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('最新专辑 rail（常规）横滑卡片：长按（311）', (tester) async {
    final longPressed = <Album>[];
    final album = _album('a3', '横滑专辑一');

    await tester.pumpWidget(
      _host(
        DiscoverAlbumRail(
          albums: <Album>[album],
          onAlbumPressed: (_) {},
          onAlbumLongPress: longPressed.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverAlbumTile), findsOneWidget);
    await tester.longPress(find.byType(DiscoverAlbumTile));
    await tester.pumpAndSettle();
    expect(longPressed, <Album>[album], reason: '311 行：长按卡片应回调 onAlbumLongPress');
    expect(tester.takeException(), isNull);
  });

  testWidgets('常听专辑 shelf（大字号）行式列表：点击（352）', (tester) async {
    final pressed = <Album>[];
    final album = _album('a4', '常听专辑一');

    await tester.pumpWidget(
      _host(
        DiscoverFrequentAlbumShelf(
          albums: <Album>[album],
          onAlbumPressed: pressed.add,
        ),
        textScale: 1.5,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('常听专辑一'));
    await tester.pumpAndSettle();
    expect(pressed, <Album>[album], reason: '352 行：点击整行应回调 onAlbumPressed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('常听专辑 shelf 窄容器：卡片宽度上限退化为容器宽（362）',
      (tester) async {
    final album = _album('a5', '窄屏专辑');

    await tester.pumpWidget(
      _host(
        DiscoverFrequentAlbumShelf(
          albums: <Album>[album],
          onAlbumPressed: (_) {},
        ),
        width: 320,
      ),
    );
    await tester.pumpAndSettle();

    // maxWidth=320 < 340 → maximumWidth = 320；tileWidth = clamp(320*0.86, 280, 320)。
    final group = tester.getSize(find.byKey(const ValueKey<String>('discover-frequent-group-0')));
    expect(group.width, closeTo(280, 0.5), reason: '窄屏下卡片宽度按 280（下限）取');
    expect(tester.takeException(), isNull);
  });

  testWidgets('三个 Loading 骨架组件可渲染（471/559/615）', (tester) async {
    await tester.pumpWidget(
      _host(
        ListView(
          children: const <Widget>[
            DiscoverRecentAlbumLoading(),
            DiscoverAlbumLoading(),
            DiscoverFrequentAlbumLoading(),
          ],
        ),
      ),
    );
    // 骨架自带 shimmer 动画，pumpAndSettle 永不收敛，只推固定帧数。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(DiscoverRecentAlbumLoading), findsOneWidget);
    expect(find.byType(DiscoverAlbumLoading), findsOneWidget);
    expect(find.byType(DiscoverFrequentAlbumLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
