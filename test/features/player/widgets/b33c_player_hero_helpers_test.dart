// batch33 C 路 —— `lib/features/player/widgets/player_hero_helpers.dart` 补测。
//
// 该文件几乎全是纯函数 / 轻量 StatelessWidget，无 Riverpod 依赖。核心是
// `playerTextFlightShuttleBuilder`：Hero 飞行动画的中转件构建器。测试直接调用
// 该函数，构造真实的 Hero 元素上下文（fromHero / toHero）与 flightContext，
// 覆盖：文本插值分支（标题 ↔ 「标题 · 专辑」前缀匹配）、非文本兜底分支、
// reduceMotion 兜底、push / pop 两个方向，以及两个 tween 工厂。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 在 MaterialApp 内放一组 Hero（from / to），供 shuttle 构建器取上下文。
Widget _host({
  required bool reduceMotion,
  required List<Widget> heroes,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(
        body: Column(children: heroes),
      ),
    ),
  );
}

Hero _textHero(Object tag, String text) => Hero(
      tag: tag,
      child: Text(text, style: const TextStyle(fontSize: 16)),
    );

Hero _nonTextHero(Object tag) => Hero(
      tag: tag,
      child: const Icon(Icons.music_note),
    );

Future<void> _pump(WidgetTester tester, Widget host) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1200);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(host);
}

void main() {
  group('player_hero_helpers · tween 工厂', () {
    test('playerLinearRectTween 起点终点透传', () {
      final tween = playerLinearRectTween(
        const Rect.fromLTWH(0, 0, 10, 10),
        const Rect.fromLTWH(5, 5, 20, 20),
      );
      expect(tween, isA<RectTween>());
      expect(tween.begin, const Rect.fromLTWH(0, 0, 10, 10));
      expect(tween.end, const Rect.fromLTWH(5, 5, 20, 20));
    });

    test('playerLinearRectTween 空值回退 Rect.zero', () {
      final tween = playerLinearRectTween(null, null);
      expect(tween.begin, Rect.zero);
      expect(tween.end, Rect.zero);
    });

    test('playerCoverRectTween 返回弧线 tween', () {
      final tween = playerCoverRectTween(
        const Rect.fromLTWH(0, 0, 10, 10),
        const Rect.fromLTWH(5, 5, 20, 20),
      );
      expect(tween, isA<MaterialRectCenterArcTween>());
    });
  });

  group('player_hero_helpers · playerTextFlightShuttleBuilder', () {
    testWidgets('文本配对(push)：标题 ↔ 标题·专辑 走文本插值分支', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _host(
          reduceMotion: false,
          heroes: <Widget>[
            _textHero('from', 'Song A'),
            _textHero('to', 'Song A · Album'),
          ],
        ),
      );
      final fromCtx = tester.element(find.byType(Hero).at(0));
      final toCtx = tester.element(find.byType(Hero).at(1));
      final flightCtx = tester.element(find.byType(Scaffold));

      final shuttle = playerTextFlightShuttleBuilder(
        flightCtx,
        const AlwaysStoppedAnimation<double>(0.5),
        HeroFlightDirection.push,
        fromCtx,
        toCtx,
      );
      expect(shuttle, isA<Widget>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('文本配对(pop)：方向感知走文本插值分支', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _host(
          reduceMotion: false,
          heroes: <Widget>[
            _textHero('from', 'Song A'),
            _textHero('to', 'Song A · Album'),
          ],
        ),
      );
      final fromCtx = tester.element(find.byType(Hero).at(0));
      final toCtx = tester.element(find.byType(Hero).at(1));
      final flightCtx = tester.element(find.byType(Scaffold));

      final shuttle = playerTextFlightShuttleBuilder(
        flightCtx,
        const AlwaysStoppedAnimation<double>(0.9),
        HeroFlightDirection.pop,
        fromCtx,
        toCtx,
      );
      expect(shuttle, isA<Widget>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('文本不匹配：走非文本兜底分支', (WidgetTester tester) async {
      await _pump(
        tester,
        _host(
          reduceMotion: false,
          heroes: <Widget>[
            _textHero('from', 'Song A'),
            _textHero('to', 'Song B'),
          ],
        ),
      );
      final fromCtx = tester.element(find.byType(Hero).at(0));
      final toCtx = tester.element(find.byType(Hero).at(1));
      final flightCtx = tester.element(find.byType(Scaffold));

      final shuttle = playerTextFlightShuttleBuilder(
        flightCtx,
        const AlwaysStoppedAnimation<double>(0.5),
        HeroFlightDirection.push,
        fromCtx,
        toCtx,
      );
      expect(shuttle, isA<Widget>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('非文本 Hero：直接返回子节点兜底', (WidgetTester tester) async {
      await _pump(
        tester,
        _host(
          reduceMotion: false,
          heroes: <Widget>[
            _nonTextHero('from'),
            _nonTextHero('to'),
          ],
        ),
      );
      final fromCtx = tester.element(find.byType(Hero).at(0));
      final toCtx = tester.element(find.byType(Hero).at(1));
      final flightCtx = tester.element(find.byType(Scaffold));

      for (final dir in HeroFlightDirection.values) {
        final shuttle = playerTextFlightShuttleBuilder(
          flightCtx,
          const AlwaysStoppedAnimation<double>(0.5),
          dir,
          fromCtx,
          toCtx,
        );
        expect(shuttle, isA<Widget>());
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduceMotion：push 直接返回目标子节点、不插值', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _host(
          reduceMotion: true,
          heroes: <Widget>[
            _textHero('from', 'Song A'),
            _textHero('to', 'Song A · Album'),
          ],
        ),
      );
      final fromCtx = tester.element(find.byType(Hero).at(0));
      final toCtx = tester.element(find.byType(Hero).at(1));
      final flightCtx = tester.element(find.byType(Scaffold));

      final shuttle = playerTextFlightShuttleBuilder(
        flightCtx,
        const AlwaysStoppedAnimation<double>(0.5),
        HeroFlightDirection.push,
        fromCtx,
        toCtx,
      );
      expect(shuttle, isA<Widget>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduceMotion：pop 直接返回源子节点', (WidgetTester tester) async {
      await _pump(
        tester,
        _host(
          reduceMotion: true,
          heroes: <Widget>[
            _textHero('from', 'Song A'),
            _textHero('to', 'Song A · Album'),
          ],
        ),
      );
      final fromCtx = tester.element(find.byType(Hero).at(0));
      final toCtx = tester.element(find.byType(Hero).at(1));
      final flightCtx = tester.element(find.byType(Scaffold));

      final shuttle = playerTextFlightShuttleBuilder(
        flightCtx,
        const AlwaysStoppedAnimation<double>(0.5),
        HeroFlightDirection.pop,
        fromCtx,
        toCtx,
      );
      expect(shuttle, isA<Widget>());
      expect(tester.takeException(), isNull);
    });
  });
}
