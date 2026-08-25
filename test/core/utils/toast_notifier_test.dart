import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('global notifications use the MusicFlow message surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: AppTheme.light(),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    ToastNotifier.show('网络异常', kind: MusicFlowMessageKind.error);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('网络异常'), findsOneWidget);
    // 底部横幅已取消，改用右上角 Toast。
    expect(find.byType(SnackBar), findsNothing);
  });
}
