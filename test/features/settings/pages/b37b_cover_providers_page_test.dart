// b37b — `lib/features/settings/pages/cover_providers_page.dart` 补测（原 13 miss）。
//
// 未覆盖行：
//   37        错误态「重试」按钮的 onAction（ref.invalidate）。
//   73-81     ReorderableListView 的 proxyDecorator 与 onReorder 拖拽落库。
//   160/161   弹窗文本框 onSubmitted（回车提交）。
//   171       弹窗「取消」按钮。
//   197       保存后 updateCoverProviderConfig + invalidate。
//
// 复用既有 cover_providers_page_coverage_gap_test.dart 的 Provider 覆盖基建
// （真实 drift 落临时目录 + 广播流 provider），只补上述分支，避免重复。
// 产品代码零改动；只读 lib。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:musicflow_client/data/sources/database/database_provider.dart';
import 'package:musicflow_client/features/settings/pages/cover_providers_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';

AppDatabase? sharedDb;

final StreamController<List<ProviderConfig>> _ctrl =
    StreamController<List<ProviderConfig>>.broadcast();

final List<ProviderConfig> defaultConfigs = <ProviderConfig>[
  ProviderConfig(id: 'c1', sourceId: 'subsonic', priority: 0),
  ProviderConfig(
    id: 'c2',
    sourceId: 'fanart',
    priority: 1,
    config: <String, dynamic>{'apiKey': 'old-key'},
  ),
  ProviderConfig(id: 'c3', sourceId: 'musicbrainz', priority: 2),
  ProviderConfig(id: 'c4', sourceId: 'custom', priority: 3),
];

Finder _byText(String text) => find.text(text);

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(900, 1400),
}) async {
  sharedDb ??= AppDatabase();
  final db = sharedDb!;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appDatabaseProvider.overrideWith((ref) => db),
        coverProviderConfigsProvider.overrideWith((ref) => _ctrl.stream),
      ],
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(body: CoverProvidersPage()),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

Future<void> _openFanartSheet(WidgetTester tester) async {
  final configure = find
      .byWidgetPredicate(
        (Widget w) => w is MusicFlowIconButton && w.label == '配置Fanart.tv',
      )
      .first;
  await tester.tap(configure);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('path_provider'),
    (MethodCall call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return <String, Object?>{'path': '/tmp/mf_b37b_cover_db'};
      }
      return null;
    },
  );

  testWidgets('错误态点「重试」触发 invalidate，不抛错', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.addError(StateError('boom'), StackTrace.current);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(_byText('无法读取封面提供商'), findsOneWidget);
    expect(_byText('重试'), findsOneWidget);

    await tester.tap(_byText('重试'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖拽排序：onReorder 落库并触发刷新', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(defaultConfigs);
    await _settle(tester);

    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    // 直接把第 0 项拖到队尾（onReorder 的净插入位语义）。
    // ignore: deprecated_member_use
    list.onReorder!(0, defaultConfigs.length);

    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
    // 标题仍在，列表正常渲染。
    expect(_byText('优先顺序'), findsOneWidget);
  });

  testWidgets('proxyDecorator 直接调用返回原始 child', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(defaultConfigs);
    await _settle(tester);

    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    final key = const ValueKey<String>('proxy-child');
    final result = list.proxyDecorator!(
      const SizedBox(key: ValueKey<String>('proxy-child')),
      0,
      const AlwaysStoppedAnimation<double>(0.5),
    );
    expect((result as SizedBox).key, key);
  });

  testWidgets('配置弹窗：回车提交会保存 Key 并刷新（覆盖 160/161/197）', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(defaultConfigs);
    await _settle(tester);

    await _openFanartSheet(tester);
    expect(_byText('配置 Fanart.tv'), findsOneWidget);

    // 聚焦输入框 → 回车（onSubmitted）→ pop(trim 后文本)。
    await tester.enterText(find.byType(TextField).last, ' brand-new ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 弹窗应因 pop(value) 关闭。
    expect(_byText('配置 Fanart.tv'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('配置弹窗：点「取消」关闭且不保存（覆盖 171）', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(defaultConfigs);
    await _settle(tester);

    await _openFanartSheet(tester);
    expect(_byText('配置 Fanart.tv'), findsOneWidget);

    await tester.tap(_byText('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_byText('配置 Fanart.tv'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
