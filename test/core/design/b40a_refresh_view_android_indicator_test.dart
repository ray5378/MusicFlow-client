import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 安卓触屏端下拉刷新的「刷新中」动画。
///
/// 背景：安卓端用的是 `RefreshIndicator.noSpinner`（刻意不画转圈），文字气泡又被
/// `!isAndroidTouch` 整块挡掉 —— 下拉刷新曾经是**全程零反馈**，用户看不出到底刷
/// 没刷。本文件钉住三条，缺一条都算回归：
/// 1. 刷新进行中必须有一个转圈动画；
/// 2. 绝不出现任何可见文案（旧版文字气泡被判定会干扰正常向下滚动）；
/// 3. 刷新结束后指示器必须彻底离开 widget 树（不留 `opacity: 0` 的僵尸节点，
///    否则会污染所有按 `CircularProgressIndicator` 计数的既有断言）。
void main() {
  // flutter test 默认平台就是 android；这里仍显式设置，避免将来默认值变化后
  // 本用例悄悄变成「在桌面路径上空转」。
  Future<void> runAsAndroid(
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body();
    } finally {
      // flutter_test 在 testBody 返回后立即校验 foundation debug 变量，
      // 必须在这里复位（与 music_flow_refresh_view_test.dart 的约定一致）。
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> pumpView(
    WidgetTester tester, {
    required Future<void> Function() onRefresh,
    bool disableAnimations = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              final view = MusicFlowRefreshView(
                onRefresh: onRefresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const <Widget>[SizedBox(height: 900)],
                ),
              );
              if (!disableAnimations) return view;
              return MediaQuery(
                data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
                child: view,
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> pullAndRelease(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, 350));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('安卓刷新进行中显示转圈动画，且全程没有任何可见文案', (tester) async {
    await runAsAndroid(() async {
      final completer = Completer<void>();
      var refreshCount = 0;

      await pumpView(
        tester,
        onRefresh: () {
          refreshCount += 1;
          return completer.future;
        },
      );

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '空闲态不得有转圈：指示器只在 refreshing 阶段进树',
      );

      await pullAndRelease(tester);

      expect(refreshCount, 1);
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: '安卓刷新中必须有纯动画指示器（此前 noSpinner + 无气泡 = 零反馈）',
      );
      expect(find.text('正在刷新'), findsNothing, reason: '动画指示器刻意不带文字');
      expect(find.text('下拉刷新'), findsNothing);
      expect(find.text('松开刷新'), findsNothing);

      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '刷新结束必须彻底移除指示器',
      );
    });
  });

  testWidgets('开启「减少动效」时退化为静态图标，不再转动', (tester) async {
    await runAsAndroid(() async {
      final completer = Completer<void>();
      await pumpView(
        tester,
        onRefresh: () => completer.future,
        disableAnimations: true,
      );

      await pullAndRelease(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(AppIcons.refresh), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();
    });
  });

  testWidgets('刷新失败时指示器同样在结束后移除', (tester) async {
    await runAsAndroid(() async {
      final completer = Completer<void>();
      await pumpView(tester, onRefresh: () => completer.future);

      await pullAndRelease(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.completeError(StateError('refresh failed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '失败分支同样不能把指示器留在树里',
      );
    });
  });
}
