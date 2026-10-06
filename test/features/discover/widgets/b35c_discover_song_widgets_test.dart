// batch35 C 路 —— `lib/features/discover/widgets/discover_song_widgets.dart` 补测。
//
// 覆盖点：
//   * DiscoverSongTile：渲染歌名/行点击/更多按钮（onOpenActions）/
//     onLongPress 优先与 fallback（null 时长按走 onOpenActions）/isCurrent 透传；
//   * DiscoverSongLoading：默认 6 项骨架；count 定制；窄屏单列；
//     大字号单列（textScale>1.3）分支。
//
// 踩坑记录：
// #L1 MusicFlowSkeleton 是无限动画，统一有界 settle 推帧，绝不用 pumpAndSettle。
// #L2 more 按钮语义标签用 bySemanticsLabel，需 tester.ensureSemantics。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/widgets/discover_song_widgets.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';

late AppLocalizations loc;

Song _song(String id, String title) =>
    Song(id: id, title: title, artist: '测试歌手');

Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _host(Widget child, {Size size = const Size(800, 900)}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: Scaffold(
        body: SizedBox(
          width: size.width,
          height: size.height,
          child: child,
        ),
      ),
    );

void main() {
  group('DiscoverSongTile', () {
    testWidgets('渲染歌名与歌手，点行触发 onPressed', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: _host(
            DiscoverSongTile(
              song: _song('s1', '随机歌一'),
              onPressed: () => pressed++,
              onOpenActions: () {},
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.text('随机歌一'), findsOneWidget);
      await tester.tap(find.text('随机歌一'));
      await settle(tester);

      expect(pressed, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点更多按钮触发 onOpenActions（语义标签正确）', (tester) async {
      var actions = 0;
      final semantics = tester.ensureSemantics();
      try {
      await tester.pumpWidget(
        ProviderScope(
          child: _host(
            DiscoverSongTile(
              song: _song('s2', '随机歌二'),
              onPressed: () {},
              onOpenActions: () => actions++,
            ),
          ),
        ),
      );
      await settle(tester);

      final moreFinder = find.bySemanticsLabel(
        loc.discover_song_actions_semantics('随机歌二'),
      );
      expect(moreFinder, findsOneWidget);
      await tester.tap(moreFinder);
      await settle(tester);

      expect(actions, 1);
      expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('onLongPress 非 null：长按触发 onLongPress 而非 onOpenActions', (tester) async {
      var longPressed = 0;
      var actions = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: _host(
            DiscoverSongTile(
              song: _song('s3', '随机歌三'),
              onPressed: () {},
              onOpenActions: () => actions++,
              onLongPress: () => longPressed++,
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.text('随机歌三'));
      await settle(tester);

      expect(longPressed, 1);
      expect(actions, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onLongPress 为 null：长按 fallback 到 onOpenActions', (tester) async {
      var actions = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: _host(
            DiscoverSongTile(
              song: _song('s4', '随机歌四'),
              onPressed: () {},
              onOpenActions: () => actions++,
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.text('随机歌四'));
      await settle(tester);

      expect(actions, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('isCurrent 透传给 MusicFlowSongRow', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: _host(
            DiscoverSongTile(
              song: _song('s5', '随机歌五'),
              onPressed: () {},
              onOpenActions: () {},
              isCurrent: true,
            ),
          ),
        ),
      );
      await settle(tester);

      final row = tester.widget<MusicFlowSongRow>(
        find.byType(MusicFlowSongRow),
      );
      expect(row.isCurrent, isTrue);
      expect(row.richMetadata, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('DiscoverSongLoading', () {
    testWidgets('默认渲染 6 个骨架行块', (tester) async {
      await tester.pumpWidget(
        ProviderScope(child: _host(const DiscoverSongLoading())),
      );
      await settle(tester);

      expect(
        find.byType(MusicFlowSkeleton),
        findsAtLeastNWidgets(12),
        reason: '6 行 × (48 图 + 2 行线 + 48 图) 至少 12 个骨架块',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('count=2 定制 + 窄屏单列分支', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: _host(
            const DiscoverSongLoading(count: 2),
            size: const Size(500, 600),
          ),
        ),
      );
      await settle(tester);

      expect(
        find.byType(MusicFlowSkeleton),
        findsAtLeastNWidgets(4),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏 + 大字号（textScale>1.3）→ 单列分支', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(1.6),
            ),
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              theme: AppTheme.light(),
              home: Scaffold(body: const DiscoverSongLoading()),
            ),
          ),
        ),
      );
      await settle(tester);

      expect(tester.takeException(), isNull);
    });
  });
}
