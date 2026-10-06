// b38b3 —— `music_flow_refresh_view.dart` 剩余缺口：减少动画时刷新图标降级。
//
// lcov 未命中行 271：`animationsDisabled ? Icon(AppIcons.refresh, ...) : ...`。
// 当系统要求减少动画（MediaQuery.disableAnimations）时，刷新中不应渲染
// CircularProgressIndicator，而应回退为静态 refresh 图标。
//
// 产品代码零改动；仅新增 test/。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  testWidgets('减少动画时刷新中显示静态图标而非进度圈', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final completer = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(
              disableAnimations: true,
              size: Size(800, 600),
            ),
            child: Scaffold(
              body: MusicFlowRefreshView(
                onRefresh: () => completer.future,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const <Widget>[SizedBox(height: 900)],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('正在刷新'), findsOneWidget);
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '减少动画时不渲染旋转进度圈',
      );
      expect(
        find.byIcon(AppIcons.refresh),
        findsOneWidget,
        reason: '回退为静态 refresh 图标（line 271）',
      );

      completer.complete();
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
