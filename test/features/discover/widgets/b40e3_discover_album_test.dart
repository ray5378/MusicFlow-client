// batch40 E3 补测：D-007 修复锁定用例。
//
// DiscoverRecentAlbumRail 的 spotlight 分支（textScale > 1.3）使用独立 key
// 'discover-recent-spotlight-spot'，与普通分支 'discover-recent-spotlight'
// 不再冲突（修复前两分支共用同一个 key，Widget 复用行为不可预期）。
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
      artist: '歌手-\$id',
      songCount: 10,
      duration: 600,
    );

/// [width] 决定 LayoutBuilder 的 maxWidth，[textScale] 决定 spotlight 分支。
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
  testWidgets('D-007: 大字号(spotlight)分支使用独立 key 且原 key 不在场',
      (tester) async {
    await tester.pumpWidget(_host(
      DiscoverRecentAlbumRail(
        albums: <Album>[_album('a1', '最近专辑一')],
        onAlbumPressed: (_) {},
      ),
      textScale: 1.5,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discover-recent-spotlight-spot')),
        findsOneWidget);
    expect(find.byKey(const Key('discover-recent-spotlight')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D-007: 普通宽度分支保留原 key 且不出现 spot key', (tester) async {
    await tester.pumpWidget(_host(
      DiscoverRecentAlbumRail(
        albums: <Album>[_album('a1', '最近专辑一')],
        onAlbumPressed: (_) {},
      ),
      textScale: 1.0,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discover-recent-spotlight')), findsOneWidget);
    expect(find.byKey(const Key('discover-recent-spotlight-spot')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });
}
