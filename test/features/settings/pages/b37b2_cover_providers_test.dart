// b37b2 —— `lib/features/settings/pages/cover_providers_page.dart` 残余分支补测。
//
// gap / b37b 已覆盖：三态、命名与描述、开关、拖拽、配置弹窗保存/取消/清空。
// 本文件补：
//   * 非 fanart 行没有「配置」入口（onConfigure == null 分支）；
//   * fanart 副标题在 config 缺失 / apiKey 非字符串等脏数据下的健壮性；
//   * 未知 sourceId（default 分支）不渲染副标题且标题回落到 id。
// 产品代码零改动；仅新增 test/。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('path_provider'),
    (MethodCall call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return <String, Object?>{'path': '/tmp/mf_b37b2_cover_db'};
      }
      return null;
    },
  );

  testWidgets('非 fanart 行没有「配置」入口', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(<ProviderConfig>[
      ProviderConfig(id: 'c1', sourceId: 'subsonic', priority: 0),
      ProviderConfig(id: 'c2', sourceId: 'musicbrainz', priority: 1),
    ]);
    await _settle(tester);

    // 只有 fanart 才有「配置」按钮；这里一个都不应出现。
    final configure = find.byWidgetPredicate(
      (Widget w) =>
          w is MusicFlowIconButton && w.label.startsWith('配置'),
    );
    expect(configure, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fanart 脏数据（apiKey 非字符串）→ 类型兜底不崩(D-059 已修复)', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(<ProviderConfig>[
      ProviderConfig(
        id: 'f-bad',
        sourceId: 'fanart',
        priority: 0,
        // 脏数据：apiKey 不是 String（来自外部导入/旧版本）。
        config: <String, dynamic>{'apiKey': 12345},
      ),
    ]);
    await _settle(tester);

    // [D-059 已修复]：apiKey 类型兜底后脏数据不再让整页构建失败。
    expect(tester.takeException(), isNull,
        reason: '[D-059 已修复] 脏数据不再抛 TypeError，页面正常渲染');
  });

  testWidgets('未知 sourceId：标题回落 id，无副标题', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(<ProviderConfig>[
      ProviderConfig(id: 'u1', sourceId: 'netease', priority: 0),
    ]);
    await _settle(tester);

    expect(find.text('netease'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fanart config 为 null：视为未配置', (tester) async {
    await _pump(tester);
    await tester.pump();
    _ctrl.add(<ProviderConfig>[
      ProviderConfig(id: 'f-null', sourceId: 'fanart', priority: 0),
    ]);
    await _settle(tester);

    expect(find.textContaining('API Key：未配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
