// b39c2 —— Route C 清尾：cover_providers_page.dart 剩余缺口。
//   * 202：_editFanartApiKey 弹窗返回非 null 后
//     `await updateCoverProviderConfig(...); ref.invalidate(coverProviderConfigsProvider);`
//     —— 保存 API Key 的落库 + 刷新链路。
//
// 手法沿用 cover_providers_page_coverage_gap_test：真 AppDatabase（临时目录落盘）
// + 广播流桩 coverProviderConfigsProvider。注意 L105 附近 [D-059] 注释区只读不动。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:musicflow_client/data/sources/database/database_provider.dart';
import 'package:musicflow_client/features/settings/pages/cover_providers_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';

final StreamController<List<ProviderConfig>> _ctrl =
    StreamController<List<ProviderConfig>>.broadcast();

List<ProviderConfig> _configs() => <ProviderConfig>[
      ProviderConfig(id: 'c1', sourceId: 'subsonic', priority: 0),
      ProviderConfig(
        id: 'c2',
        sourceId: 'fanart',
        priority: 1,
        config: <String, dynamic>{'apiKey': '  '},
      ),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fanart 保存 API Key → 落库 + invalidate 刷新为已配置（202）',
      (tester) async {
    final db = AppDatabase();
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appDatabaseProvider.overrideWith((ref) => db),
          coverProviderConfigsProvider.overrideWith((ref) => _ctrl.stream),
        ],
        child: MediaQuery(
          data: const MediaQueryData(size: Size(900, 1400)),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const CoverProvidersPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    _ctrl.add(_configs());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // fanart 行的「配置」入口（MusicFlowIconButton，label 含标题）。
    final configure = find
        .byWidgetPredicate(
          (Widget w) =>
              w is MusicFlowIconButton && w.label == '配置Fanart.tv',
        )
        .first;
    await tester.tap(configure);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('配置 Fanart.tv'), findsOneWidget,
        reason: '应弹出 API Key 配置弹窗');

    // 输入并保存 → pop(非 null) → updateCoverProviderConfig + invalidate（202）。
    await tester.enterText(find.byType(TextField).last, ' k39c2key ');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // invalidate 后流桩重订阅，推入落库后的新配置模拟重拉结果。
    _ctrl.add(_configs().map((c) {
      if (c.sourceId != 'fanart') return c;
      return c.copyWith(config: <String, dynamic>{'apiKey': 'k39c2key'});
    }).toList());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('配置 Fanart.tv'), findsNothing, reason: '弹窗应已关闭');
    expect(find.textContaining('已配置'), findsOneWidget,
        reason: '保存后副标题应变为已配置');
    expect(tester.takeException(), isNull);
  });
}
