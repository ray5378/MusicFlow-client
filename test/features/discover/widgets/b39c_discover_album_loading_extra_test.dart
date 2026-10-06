// b39c —— Route C 补测：`lib/features/discover/widgets/discover_album_widgets.dart` 剩余缺口。
//
// 覆盖点：
//   * 471：DiscoverRecentAlbumLoading 构造 + build。
//   * 559：DiscoverAlbumLoading 构造 + build。
//   * 615：DiscoverFrequentAlbumLoading 构造 + build。
//
// 报告为**不可达**（见文末）：365 / 643 是 `constraints.maxWidth < 280`
// 的三元真分支，但同函数前部 `useAccessibleList = scale >= 1.3 || maxWidth < 280`
// 已在 maxWidth < 280 时早退到无障碍列表 ⇒ 到达该行时 maxWidth 恒 >= 280，
// 真分支永不成立。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/discover/widgets/discover_album_widgets.dart';

void main() {
  Future<void> pumpInto(WidgetTester tester, Widget child) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(width: 960, height: 800, child: child),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('DiscoverRecentAlbumLoading 可构建（471）', (tester) async {
    await pumpInto(tester, const DiscoverRecentAlbumLoading());
    expect(find.byType(DiscoverRecentAlbumLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiscoverAlbumLoading 可构建（559）', (tester) async {
    await pumpInto(tester, const DiscoverAlbumLoading());
    expect(find.byType(DiscoverAlbumLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiscoverFrequentAlbumLoading 可构建（615）', (tester) async {
    await pumpInto(tester, const DiscoverFrequentAlbumLoading());
    expect(find.byType(DiscoverFrequentAlbumLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
