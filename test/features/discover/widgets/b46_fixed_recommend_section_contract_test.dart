// b46 —— FixedRecommendSection 空/降级分支契约钉子
//
// 背景：「为你推荐」的数据源改成服务端聚合快照后，区块有三种"看起来都像空"
// 的状态必须区分开：
//   1. 真的没有内容          → 整块隐藏（SizedBox.shrink），不占首屏；
//   2. 加载失败(loadFailed)   → 出可重试的错误态，用户知道"是没拉到"；
//   3. 固定卡集体失效(degraded 且 fixed 为空) → 同样出错误态，
//      而不是把一堆随机补位伪装成「为你推荐」。
// 旧实现里首屏这条链从不置位 loadFailed，1/2 永远混为一谈。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/features/discover/widgets/discover_section_message.dart';
import 'package:musicflow_client/features/discover/widgets/fixed_recommend_section.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';

HomeCard _card(String id, int songCount) => HomeCard(
      playlistId: id,
      name: 'Card $id',
      playlistName: 'Card $id',
      position: 1,
      isCombo: false,
      songCount: songCount,
      coverArt: 'pl-$id',
    );

Playlist _playlist(String id, int songCount) => Playlist(
      id: id,
      name: 'PL $id',
      songCount: songCount,
      duration: 0,
      coverArt: 'pl-$id',
    );

Widget _host({
  required HomeRecommendSection section,
  required bool loadFailed,
}) =>
    ProviderScope(
      overrides: <Override>[
        homeRecommendSectionProvider.overrideWith((ref) async => section),
        homeCardsLoadFailedProvider.overrideWith((ref) => loadFailed),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const Scaffold(
          body: SizedBox(
            width: 900,
            child: SingleChildScrollView(child: FixedRecommendSection()),
          ),
        ),
      ),
    );

void main() {
  testWidgets('10 固定 + 2 随机 → 正常出卡片行，无错误态', (tester) async {
    final section = HomeRecommendSection(
      hourBucket: 498541,
      homeCount: 12,
      fixed: <HomeCard>[
        for (var i = 0; i < 10; i++) _card('c$i', i == 0 ? 4142 : 30),
      ],
      random: <Playlist>[_playlist('p1', 303), _playlist('p2', 12)],
    );

    await tester.pumpWidget(_host(section: section, loadFailed: false));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverSectionMessage), findsNothing,
        reason: '有内容时不能出错误态');
    // 标题存在，且至少渲染出一张卡（横向 ListView 只建视口内卡片）。
    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('30 首'), findsWidgets);
  });

  testWidgets('空区块 + 未失败 → 整块隐藏（SizedBox.shrink）', (tester) async {
    await tester.pumpWidget(
      _host(section: const HomeRecommendSection.empty(), loadFailed: false),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverSectionMessage), findsNothing);
    expect(find.text('为你推荐'), findsOneWidget, reason: '标题栏仍在，只是内容区为空');
    expect(find.text('30 首'), findsNothing);
  });

  testWidgets('空区块 + 加载失败 → 出可重试错误态', (tester) async {
    await tester.pumpWidget(
      _host(section: const HomeRecommendSection.empty(), loadFailed: true),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverSectionMessage), findsOneWidget,
        reason: '加载失败必须与"真的没内容"区分开');
    expect(find.text('为你推荐暂时不可用'), findsOneWidget);
  });

  testWidgets('degraded 且固定卡全失效 → 走错误分支（不把随机补位伪装成推荐）',
      (tester) async {
    final section = HomeRecommendSection(
      hourBucket: 498541,
      homeCount: 12,
      degraded: true,
      fixed: const <HomeCard>[],
      random: <Playlist>[_playlist('p1', 303), _playlist('p2', 12)],
    );

    await tester.pumpWidget(_host(section: section, loadFailed: false));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverSectionMessage), findsOneWidget,
        reason: '固定卡集体失效等同没内容，不能静默降级成纯随机');
    expect(find.text('为你推荐暂时不可用'), findsOneWidget);
  });

  testWidgets('degraded 但仍有固定卡 → 正常展示（降级不等于空）', (tester) async {
    final section = HomeRecommendSection(
      hourBucket: 498541,
      homeCount: 12,
      degraded: true,
      fixed: <HomeCard>[_card('c1', 30)],
      random: <Playlist>[_playlist('p1', 303)],
    );

    await tester.pumpWidget(_host(section: section, loadFailed: false));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverSectionMessage), findsNothing);
    expect(find.text('Card c1'), findsOneWidget);
  });
}
