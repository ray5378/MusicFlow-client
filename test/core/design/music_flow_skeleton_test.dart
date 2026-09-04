import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(Widget child, {bool disableAnimations = false}) {
    // v3.4.66:MusicFlowSkeleton 改为 ConsumerStatefulWidget(窗口可见性门控),
    // 测试须包 ProviderScope(appVisibilityProvider 默认可见,行为与改造前一致)。
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );
  }

  testWidgets('normal motion animates with MusicFlow skeleton colors', (
    tester,
  ) async {
    await tester.pumpWidget(app(const MusicFlowSkeleton(width: 120, height: 16)));
    await tester.pump(const Duration(milliseconds: 300));

    final decoratedBox = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(MusicFlowSkeleton),
        matching: find.byType(DecoratedBox),
      ),
    );
    final decoration = decoratedBox.decoration as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    final expectedHighlight = Color.alphaBlend(
      MusicFlowColors.nightInk.withValues(alpha: 0.08),
      MusicFlowColors.nightRaised,
    );

    expect(gradient.colors, <Color>[
      MusicFlowColors.nightRaised,
      expectedHighlight,
      MusicFlowColors.nightRaised,
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('circle keeps 48dp geometry and excludes its semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const MusicFlowSkeleton.circle(size: 48), disableAnimations: true),
    );

    expect(tester.getSize(find.byType(MusicFlowSkeleton)), const Size(48, 48));
    final exclusion = tester.widget<ExcludeSemantics>(
      find.descendant(
        of: find.byType(MusicFlowSkeleton),
        matching: find.byType(ExcludeSemantics),
      ),
    );
    expect(exclusion.excluding, isTrue);
  });
}
