// b38c3 —— Route C 补测：PlaylistLoadingPreview 的构造函数（playlist_detail_blocks.dart:196）。
//   生产里该占位组件只在 const 上下文实例化（常量折叠 → 构造行不计命中），
//   且在 playlist_detail_page 的空态分支下被遮蔽（[D-049]）；这里直接以非 const
//   实例化并渲染，覆盖构造行本身。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/playlist_detail_blocks.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  testWidgets('PlaylistLoadingPreview 非 const 实例化（构造行 196）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    // 无封面（coverArt == null）→ 不发起封面请求，避免 pending Timer。
    final name = '我的歌单${DateTime.now().microsecond % 9}';
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: PlaylistLoadingPreview(name: name, songCount: 12),
        ),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.byType(PlaylistLoadingPreview), findsOneWidget);
    expect(find.text(name), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
