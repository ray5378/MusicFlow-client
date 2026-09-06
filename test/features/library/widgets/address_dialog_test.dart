import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/features/library/widgets/address_dialog.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildDialog() {
    return MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: AddressDialog(libraryId: 'lib-1')),
    );
  }

  Finder addressEditor() => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is MusicFlowTextField && widget.label == '服务器地址',
    ),
    matching: find.byType(TextField),
  );

  testWidgets('shows warning icon for http urls and opens hint dialog', (tester) async {
    await tester.pumpWidget(buildDialog());
    // 从当前树取实际本地化文案,避免断言在 zh 文案上硬编码(历史坑)。
    final loc = AppLocalizations.of(tester.element(addressEditor()));

    expect(addressEditor(), findsOneWidget);
    await tester.enterText(addressEditor(), 'http://192.168.1.5:4533');
    await tester.pumpAndSettle();

    final warningAction = find.byWidgetPredicate(
      (widget) =>
          widget is MusicFlowIconButton &&
          widget.label == loc.library_http_tip_title,
    );
    expect(warningAction, findsOneWidget);

    await tester.tap(warningAction);
    await tester.pumpAndSettle();

    expect(find.text(loc.library_http_tip_title), findsOneWidget);
    expect(find.text(loc.library_http_hint), findsNWidgets(2));
    expect(find.text(loc.library_got_it), findsOneWidget);
  });

  testWidgets('does not show warning icon for https urls', (tester) async {
    await tester.pumpWidget(buildDialog());

    expect(addressEditor(), findsOneWidget);
    await tester.enterText(addressEditor(), 'https://music.example.com');
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate(
      (widget) =>
          widget is MusicFlowIconButton &&
          widget.label == AppLocalizations.of(tester.element(addressEditor())).library_http_tip_title,
    ), findsNothing);
  });
}
