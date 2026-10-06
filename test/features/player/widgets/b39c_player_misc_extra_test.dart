// b39c —— Route C 补测：player 侧零散缺口。
//
// 覆盖点：
//   * player_hero_helpers.dart:74 —— `_extractTextSnapshot` 的 `Center` 分支
//     （from/to hero 子节点是 Center 包裹 Text 时命中）。
//   * song_info_page.dart:128 —— `_nonEmpty` 的取值表达式（页面 build 时对
//     genre / path 调用）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/features/player/widgets/song_info_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

void main() {
  testWidgets('文本 Hero 穿梭器命中 Center 分支（player_hero_helpers 74）',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Hero(
                tag: 'from',
                child: Center(child: Text('A')),
              ),
              Hero(
                tag: 'to',
                child: Center(child: Text('AB')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final fromCtx = tester.element(
      find.byWidgetPredicate((w) => w is Hero && w.tag == 'from'),
    );
    final toCtx = tester.element(
      find.byWidgetPredicate((w) => w is Hero && w.tag == 'to'),
    );

    final shuttle = playerTextFlightShuttleBuilder(
      tester.element(find.byType(Scaffold)),
      const AlwaysStoppedAnimation<double>(0.4),
      HeroFlightDirection.push,
      fromCtx,
      toCtx,
    );

    expect(shuttle, isA<Widget>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌曲信息页 _nonEmpty 取值（song_info_page 128）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final song = Song(id: 's1', title: '曲目', artist: '歌手');

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith(
            (Ref ref) => TestPlayerNotifier(
              PlayerState(currentSong: song),
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(body: SongInfoPage(song: song)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SongInfoPage), findsOneWidget);
    expect(find.text('曲目'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
