// b38c3 —— lyrics_providers_page.dart 剩余可达分支补测（Route C）。
//
// 单点缺口：line 74 `proxyDecorator: (child, index, animation) => child`。
// 这是表达式体闭包，只有**真实拖拽**时才会被调用（既有用例只验证了列表渲染
// 与 onReorder 的落库，从未真的把某一行拖起来过）。
//
// 直接覆盖 lyricsProviderConfigsProvider 拿两条配置（不走 DB），拖起第一行的
// 拖拽把手后 **取消**（不发 onReorder，避免触发 appDatabaseProvider）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/features/settings/pages/lyrics_providers_page.dart';
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ProviderConfig> _configs() => <ProviderConfig>[
      ProviderConfig(id: 'p1', sourceId: 'lrclib', enabled: true, priority: 0),
      ProviderConfig(id: 'p2', sourceId: 'netease', enabled: false, priority: 1),
    ];

void main() {
  testWidgets('拖起歌词提供商行 → proxyDecorator 被调用（拖拽态 proxy 构造）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          lyricsProviderConfigsProvider.overrideWith(
            (ref) => Stream<List<ProviderConfig>>.value(_configs()),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const LyricsProvidersPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MusicFlowProviderSettingRow), findsNWidgets(2));

    // 真实拖拽第一行的把手：初始只有 pointer down 时不会构造 proxy，必须带位移。
    final handle = find.byIcon(AppIcons.dragHandle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveBy(const Offset(0, 60));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    // 拖拽态：被拖行进入 proxy（此处 proxyDecorator 即 line 74 被执行）。
    // 取消拖拽，避免进入 onReorder 触发 DB。
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(find.byType(MusicFlowProviderSettingRow), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
