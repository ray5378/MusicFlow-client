import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_media_actions.dart';

// Route C 补测：lib/widgets/music_flow_media_actions.dart
void main() {
  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: child),
        ),
      );

  testWidgets('renders play-only when shuffle absent', (tester) async {
    var played = false;
    await tester.pumpWidget(
      wrap(
        MusicFlowMediaActions(
          onPlay: () => played = true,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(MusicFlowButton).first);
    expect(played, isTrue);
  });

  testWidgets('renders shuffle beside play and secondary actions',
      (tester) async {
    var shuffled = false;
    var acted = false;
    await tester.pumpWidget(
      wrap(
        MusicFlowMediaActions(
          onPlay: () {},
          onShuffle: () => shuffled = true,
          showShuffle: true,
          secondaryActions: <MusicFlowMediaAction>[
            MusicFlowMediaAction(
              icon: AppIcons.heart,
              label: 'fav',
              onPressed: () => acted = true,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // 次要操作渲染为纯图标按钮(MusicFlowIconButton)，label 只作为语义标签，
    // 树中没有 Text('fav')，因此按 label 定位该图标按钮。
    final favAction = find.byWidgetPredicate(
      (Widget widget) => widget is MusicFlowIconButton && widget.label == 'fav',
    );
    expect(favAction, findsOneWidget);
    await tester.tap(favAction);
    expect(acted, isTrue);

    // shuffle 与 play 并排：两者同处一个 Row，shuffle 为次要变体按钮。
    final playButton = find.byWidgetPredicate(
      (Widget widget) => widget is MusicFlowButton && widget.label == '播放',
    );
    final shuffleButton = find.byWidgetPredicate(
      (Widget widget) =>
          widget is MusicFlowButton &&
          widget.variant == MusicFlowButtonVariant.secondary &&
          widget.label == '随机播放',
    );
    expect(playButton, findsOneWidget);
    expect(shuffleButton, findsOneWidget);

    final primaryRow = find.ancestor(
      of: playButton,
      matching: find.byType(Row),
    );
    expect(primaryRow, findsOneWidget);
    expect(
      find.descendant(of: primaryRow, matching: shuffleButton),
      findsOneWidget,
    );

    await tester.tap(shuffleButton);
    expect(shuffled, isTrue);
  });

  testWidgets('stacks primary actions when width is narrow', (tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 200,
          child: MusicFlowMediaActions(
            onPlay: () {},
            onShuffle: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(MusicFlowButton), findsNWidgets(2));
  });
}
