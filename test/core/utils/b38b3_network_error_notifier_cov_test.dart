// b38b3 —— `lib/core/utils/network_error_notifier.dart` 补测。
//
// 未覆盖行（230 lcov）：38 —— `show()` 未显式传 message 时，取
//   `l10nNowCurrent().core_network_error` 作为默认文案。
// 既有 b36c 用例全部显式传入 message，故 `??` 右侧从未求值。
//
// 这里给一个「导航器已就绪」的根，使 ToastNotifier 真正把提示插进 Overlay，
// 再断言屏幕上出现的就是本地化的默认网络错误文案（真实可观测，而非恒真）。
//
// 说明：line 55（pending 定时器回调里的同名兜底）在 `_schedulePending` 里
// `_pendingMessage` 必先被赋值、且 `cancelPending` 会连定时器一起取消，
// 故其 null 分支不可达（详见回报）。
// 产品代码零改动；只读 lib。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('show() 不传 message 时使用本地化默认文案（命中 38）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: SizedBox.expand()),
    ));
    // 让根导航器/Overlay 完成首帧，确保 rootNavigatorKey.currentState 非空。
    await tester.pump();

    // 未 markAppStarted → 走即时路径 _showNow → 取出本地化默认文案。
    NetworkErrorNotifier.show();
    await tester.pump();

    final expected = l10nNowCurrent().core_network_error;
    expect(expected, isNotEmpty);
    expect(
      find.text(expected),
      findsOneWidget,
      reason: '未传 message 时应弹出本地化的 core_network_error 文案',
    );
  });
}
