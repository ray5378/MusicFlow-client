import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/search/widgets/entity_search_bar.dart';

// Route C 补测：lib/features/search/widgets/entity_search_bar.dart
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

  testWidgets('updates controller text when query prop changes',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        EntitySearchBar(
          query: 'abc',
          onQueryChanged: (v) {},
        ),
      ),
    );
    await tester.pumpWidget(
      wrap(
        EntitySearchBar(
          query: 'xyz',
          onQueryChanged: (v) {},
        ),
      ),
    );
    await tester.pump();
    // 清空按钮出现（文本非空）。
    expect(find.byIcon(AppIcons.close), findsOneWidget);
  });

  testWidgets('clear button resets query', (tester) async {
    var changed = 'init';
    await tester.pumpWidget(
      wrap(
        EntitySearchBar(
          query: 'hello',
          onQueryChanged: (v) => changed = v,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pump();
    expect(changed, '');
  });

  testWidgets('debounced onQueryChanged fires after typing', (tester) async {
    var changed = '';
    await tester.pumpWidget(
      wrap(
        EntitySearchBar(
          query: '',
          onQueryChanged: (v) => changed = v,
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'song');
    // 越过 450ms debounce。
    await tester.pump(const Duration(milliseconds: 600));
    expect(changed, 'song');
  });
}
