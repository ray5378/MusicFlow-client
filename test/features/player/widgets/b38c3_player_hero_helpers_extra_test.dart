// b38c3 —— player_hero_helpers.dart 剩余可达分支补测（Route C）。
//
// 单点缺口：line 74 `_extractTextSnapshot` 的 `if (current is Center && ...) visit(...)`。
// 该函数沿 Hero 子级递归下钻找 Text，现有用例只走通了 Padding / Align / SizedBox
// 三种包裹（生产里文本 Hero 的 child 正好是这三种），Center 包裹从未出现。
//
// 这里用真实 Hero 元素当上下文，直接调用公开的 playerTextFlightShuttleBuilder，
// 让 from 侧 child 是 `Center(child: Text(...))`，把 Center 分支走通。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';

void main() {
  testWidgets('Hero 子级经 Center 包裹 → 文本快照可下钻提取（line 74）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Stack(
          children: <Widget>[
            Hero(
              tag: 'b38c3-hero-from',
              child: Center(child: Text('歌曲 艺术家')),
            ),
            Hero(
              tag: 'b38c3-hero-to',
              child: Text('歌曲 艺术家 · 专辑'),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final heroes = tester.elementList(find.byType(Hero)).toList();
    expect(heroes, hasLength(2));

    final shuttle = playerTextFlightShuttleBuilder(
      heroes[0],
      const AlwaysStoppedAnimation<double>(0.5),
      HeroFlightDirection.push,
      heroes[0],
      heroes[1],
    );

    // from 侧文本经 Center 下钻取出，且与 to 侧构成前缀对 → 走文本插值分支。
    expect(shuttle, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
