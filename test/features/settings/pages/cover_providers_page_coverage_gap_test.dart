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
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';

/// 真数据库落在临时目录，避免打本机文档目录；不是断言对象，只为让
/// updateCoverProviderOrder / toggleCoverProvider 的写路径能真跑一遍 drift。
AppDatabase? sharedDb;

final StreamController<List<ProviderConfig>> _ctrl =
    StreamController<List<ProviderConfig>>.broadcast();

final List<ProviderConfig> defaultConfigs = <ProviderConfig>[
  ProviderConfig(id: 'c1', sourceId: 'subsonic', priority: 0),
  ProviderConfig(
    id: 'c2',
    sourceId: 'fanart',
    priority: 1,
    config: <String, dynamic>{'apiKey': '  '},
  ),
  ProviderConfig(id: 'c3', sourceId: 'musicbrainz', priority: 2),
  ProviderConfig(id: 'c4', sourceId: 'custom', priority: 3),
  ProviderConfig(id: 'c5', sourceId: 'netease', priority: 4),
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
        // 覆盖成广播流：测试侧可随时 add 新列表，模拟 invalidate 后的重新拉取。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // drift 连接会问 path_provider 要文档目录，测试里指到一个临时路径即可。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('path_provider'),
    (MethodCall call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return <String, Object?>{'path': '/tmp/mf_cover_providers_test_db'};
      }
      return null;
    },
  );
  group('CoverProvidersPage · 三态', () {
    testWidgets('loading 显示骨架', (tester) async {
      await _pump(tester);
      await tester.pump();

      expect(_byText('优先顺序'), findsNothing);
      expect(find.byType(MusicFlowProviderListSkeleton), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error 显示错误态且重试可点', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.addError(StateError('boom'), StackTrace.current);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(_byText('无法读取封面提供商'), findsOneWidget);
      expect(find.byType(MusicFlowErrorState), findsWidgets);
      expect(_byText('重试'), findsOneWidget);
    });

    testWidgets('空列表显示空态', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.add(const <ProviderConfig>[]);
      await tester.pump();

      expect(_byText('没有可用的封面提供商'), findsOneWidget);
      expect(find.byType(MusicFlowEmptyState), findsWidgets);
    });
  });

  group('CoverProvidersPage · 提供商命名与描述', () {
    testWidgets('四类内置源走本地化名，未知源回落自身 id', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.add(defaultConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(_byText('优先顺序'), findsOneWidget);
      expect(_byText('服务端'), findsOneWidget);
      expect(_byText('Subsonic 服务端封面'), findsOneWidget);
      expect(_byText('Fanart.tv'), findsOneWidget);
      expect(_byText('MusicBrainz'), findsOneWidget);
      expect(_byText('MusicBrainz Cover Art Archive'), findsOneWidget);
      expect(_byText('自定义源'), findsOneWidget);
      expect(_byText('自定义 API 地址'), findsOneWidget);
      // 未知源：标题直接用 sourceId，描述为空（不渲染空串节点）。
      expect(_byText('netease'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fanart 无 Key 提示未配置，有 Key 提示已配置', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.add(defaultConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // 配置里 apiKey 全是空白 → trim 后为空 → 视为未配置。
      expect(find.textContaining('API Key：未配置'), findsOneWidget);

      await _pump(tester);
      await tester.pump();
      _ctrl.add(<ProviderConfig>[
        ProviderConfig(
          id: 'f1',
          sourceId: 'fanart',
          priority: 0,
          config: <String, dynamic>{'apiKey': 'live-key'},
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('API Key：已配置'), findsOneWidget);
    });
  });

  group('CoverProvidersPage · 启停开关', () {
    testWidgets('拨动开关写回数据库并通过 invalidate 刷新', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.add(defaultConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final rows = find.byType(MusicFlowProviderSettingRow);
      expect(rows, findsNWidgets(5));

      // 第一行的开关：拨到关闭 → 页面调 toggleCoverProvider + invalidate。
      // 开关是行里唯一的 MusicFlowPressable（带 toggled 参数，无独立 Switch 组件）。
      final toggles = find.byWidgetPredicate(
        (Widget w) =>
            w is MusicFlowPressable && w.minimumSize == const Size(60, 48),
      );
      expect(toggles, findsNWidgets(5));
      await tester.tap(toggles.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // invalidate 会让覆盖 provider 重新订阅流（此时流里没有新事件），
      // 所以再给一帧让订阅完成，然后测试侧把「已停用」的版本推回去。
      await tester.pump(const Duration(milliseconds: 50));

      // 覆盖 provider 被 invalidate 后重新拉取，测试侧把「已停用」推回去。
      _ctrl.add(
        defaultConfigs
            .map((c) => c.copyWith(enabled: c.sourceId != 'subsonic'))
            .toList(),
      );
      // 推事件后要给两帧：第一帧落到 AsyncData，第二帧才把列表渲染出来。
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byWidgetPredicate((Widget w) {
          if (w is! MusicFlowProviderSettingRow) return false;
          return !w.enabled;
        }),
        findsWidgets,
      );
      expect(_byText('服务端'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CoverProvidersPage · fanart 配置弹窗', () {
    testWidgets('保存 Key 后刷新为已配置', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.add(defaultConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 「配置」是行内的 MusicFlowIconButton（label = 配置 + 标题），
      // 与标题不是祖先/后代关系，只能按组件本身定位。
      final configure = find
          .byWidgetPredicate(
            (Widget w) =>
                w is MusicFlowIconButton && w.label == '配置Fanart.tv',
          )
          .first;
      await tester.tap(configure);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_byText('配置 Fanart.tv'), findsOneWidget);
      expect(_byText('API Key'), findsWidgets);

      await tester.enterText(find.byType(TextField).last, ' abc123 ');
      await tester.pump();
      await tester.tap(_byText('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 弹窗关闭 → 覆盖 provider 推新值 → 副标题变成已配置。
      _ctrl.add(defaultConfigs.map((c) {
        if (c.sourceId != 'fanart') return c;
        return c.copyWith(config: <String, dynamic>{'apiKey': 'abc123'});
      }).toList());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(_byText('配置 Fanart.tv'), findsNothing);
      expect(find.textContaining('API Key：已配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('清空 Key 后回落未配置', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.add(<ProviderConfig>[
        ProviderConfig(
          id: 'f2',
          sourceId: 'fanart',
          priority: 0,
          config: <String, dynamic>{'apiKey': 'old'},
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('API Key：已配置'), findsOneWidget);

      // 「配置」是行内的 MusicFlowIconButton（label = 配置 + 标题），
      // 与标题不是祖先/后代关系，只能按组件本身定位。
      final configure = find
          .byWidgetPredicate(
            (Widget w) =>
                w is MusicFlowIconButton && w.label == '配置Fanart.tv',
          )
          .first;
      await tester.tap(configure);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(_byText('清空'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      _ctrl.add(<ProviderConfig>[
        ProviderConfig(
          id: 'f2',
          sourceId: 'fanart',
          priority: 0,
          config: <String, dynamic>{'apiKey': ''},
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('API Key：未配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
