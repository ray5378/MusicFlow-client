// b38b3 —— `music_flow_media_color_scope.dart` 剩余缺口：父主题缺少 MusicFlow 扩展时的回退。
//
// lcov 未命中行 30-32（colors 回退到 dark()/light()）与 35（typography 回退到
// MusicFlowTypography.standard）。当 MusicFlowMediaColorScope 挂在不带这些扩展的
// 普通 ThemeData 下时，应仍能合成完整的地域令牌而不崩溃。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';

void main() {
  Future<MusicFlowColors> pumpWith(
    WidgetTester tester, {
    required Brightness brightness,
    required Color seed,
  }) async {
    late MusicFlowColors scoped;
    late MusicFlowTypography scopedTypography;
    await tester.pumpWidget(
      MaterialApp(
        // 有意不使用 AppTheme —— 以便触发「父主题缺少扩展」的回退分支。
        theme: ThemeData(brightness: brightness),
        darkTheme: ThemeData(brightness: brightness),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        home: MusicFlowMediaColorScope(
          visuals: MusicFlowMediaVisuals.fallback(seed: seed),
          role: MusicFlowMediaSurfaceRole.panel,
          child: Builder(
            builder: (context) {
              scoped = context.musicFlowColors;
              scopedTypography = context.musicFlowTypography;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(scopedTypography.body.fontSize, isNotNull);
    return scoped;
  }

  testWidgets('暗色父主题（无扩展）回退 dark()', (tester) async {
    final scoped = await pumpWith(
      tester,
      brightness: Brightness.dark,
      seed: const Color(0xFF223355),
    );
    // 回退分支产出的应是可用的 MusicFlow 语义色。
    expect(scoped.surface, isNotNull);
    expect(scoped.ink, isNotNull);
  });

  testWidgets('亮色父主题（无扩展）回退 light()', (tester) async {
    final scoped = await pumpWith(
      tester,
      brightness: Brightness.light,
      seed: const Color(0xFFFFE36B),
    );
    expect(scoped.surface, isNotNull);
    expect(scoped.ink, isNotNull);
  });
}
