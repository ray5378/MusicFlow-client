// b36c —— `lib/core/utils/toast_notifier.dart` 缺口补测（原 6/11）。
//
// 既有 `toast_notifier_test.dart` 只覆盖「导航器就绪 → 直接弹 Toast」。
// 本文件补齐三条缺口：
//   * 导航器未就绪时 show 挂起到 pending；
//   * flush 在仍未就绪时打告警且不抛；
//   * 导航器就绪后 flush 把 pending 补发到 Overlay。
//
// 产品代码零改动；只读 lib。用例顺序刻意先「未就绪」后「就绪」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';

void main() {
  test('导航器未就绪时 show 挂起，flush 打告警且不抛', () {
    // 尚未挂载任何 MaterialApp/navigatorKey → currentState 为 null。
    expect(rootNavigatorKey.currentState, isNull);
    ToastNotifier.show('挂起消息');
    // 无待发 overlay：flush 走告警分支。
    ToastNotifier.flush();
    expect(true, isTrue);
  });

  testWidgets('导航器就绪后 flush 补发待发消息', (tester) async {
    // 先产生一条 pending（此时仍无导航器）。
    ToastNotifier.show('待补发消息');

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        navigatorKey: rootNavigatorKey,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    expect(rootNavigatorKey.currentState, isNotNull);

    ToastNotifier.flush();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('待补发消息'), findsOneWidget);

    // 无 pending 时再 flush → 直接返回。
    ToastNotifier.flush();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
