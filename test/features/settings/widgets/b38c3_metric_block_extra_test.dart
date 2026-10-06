// b38c3 —— Route C 补测：MusicFlowMetricBlock 的构造函数
//   （music_flow_settings_components.dart:432）。
//   生产里以 const 实例化（常量折叠 → 构造行不计命中）；非 const 实例化即覆盖。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  testWidgets('MusicFlowMetricBlock 非 const 实例化（构造行 432）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final value = '${DateTime.now().microsecond % 500} 首';
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      home: Scaffold(
        body: MusicFlowMetricBlock(
          icon: AppIcons.library,
          label: '曲库规模',
          value: value,
          detail: '缓存命中率 92%',
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.byType(MusicFlowMetricBlock), findsOneWidget);
    expect(find.text(value), findsOneWidget);
    expect(find.text('缓存命中率 92%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
