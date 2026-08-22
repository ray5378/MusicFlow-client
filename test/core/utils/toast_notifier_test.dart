import 'package:musicflow_client/core/design/echo_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('global notifications use the Echo message surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: AppTheme.light(),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    ToastNotifier.show('网络异常', kind: EchoMessageKind.error);
    await tester.pump();

    expect(find.text('网络异常'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
