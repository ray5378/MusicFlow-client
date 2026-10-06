// batch33 C 路 —— `lib/features/settings/pages/lyrics_providers_page.dart` 补测。
//
// 基线覆盖率 17.33%。与封面提供商页（cover_providers_page_coverage_gap_test）
// 是镜像页面，套路完全照搬：
//   * `lyricsProviderConfigsProvider` 是 StreamProvider —— 覆盖成广播流，
//     测试侧随时 add 数据模拟 invalidate 后的重取；
//   * `appDatabaseProvider` 覆盖成真 AppDatabase（路径指到 /tmp 临时目录，
//     由 path_provider mock 提供）—— AppDatabase 建库时会种子默认配置行，
//     toggle / reorder 的 drift 写路径能真跑一遍并断言落库；
//   * 行内开关是 `MusicFlowPressable(minimumSize: Size(60, 48))`（无独立
//     Switch 组件），按此谓词定位；
//   * 拖动把手是行内 `ReorderableDragStartListener`，长按拖拽触发 onReorder。
//   * 真库断言必须在 `tester.runAsync` 内执行：testWidgets 是 FakeAsync
//     环境，drift 真实 I/O 永不完成（did not complete），并用轮询等待
//     页面异步写库落盘；main() 里先清掉共享临时库防跨轮残留假绿。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:musicflow_client/data/sources/database/database_provider.dart';
import 'package:musicflow_client/features/settings/pages/lyrics_providers_page.dart';
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';

AppDatabase? sharedDb;

final StreamController<List<ProviderConfig>> _ctrl =
    StreamController<List<ProviderConfig>>.broadcast();

final List<ProviderConfig> kConfigs = <ProviderConfig>[
  ProviderConfig(id: 'lyrics_subsonic', sourceId: 'subsonic', priority: 0),
  ProviderConfig(id: 'lyrics_lrclib', sourceId: 'lrclib', priority: 1),
  ProviderConfig(id: 'lyrics_netease', sourceId: 'netease', priority: 2),
  ProviderConfig(id: 'lyrics_custom', sourceId: 'custom', priority: 3),
  ProviderConfig(id: 'weird-source', sourceId: 'weird-source', priority: 4),
];

Future<AppLocalizations> _pump(
  WidgetTester tester, {
  Size size = const Size(900, 1400),
}) async {
  sharedDb ??= AppDatabase();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appDatabaseProvider.overrideWith((ref) => sharedDb!),
        lyricsProviderConfigsProvider.overrideWith((ref) => _ctrl.stream),
      ],
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(body: LyricsProvidersPage()),
        ),
      ),
    ),
  );
  await tester.pump();
  // 预热打开数据库：LazyDatabase 首开要 spawn drift isolate，若由后续
  // tap 触发则发生在 FakeAsync zone 内，等待链被 FakeAsync 化导致
  // did not complete 挂死。先在 runAsync（真实 zone）里打开并读一次。
  await tester.runAsync(
    () async =>
        sharedDb!.select(sharedDb!.lyricsProviderConfigs).get(),
  );
  return AppLocalizations.of(
    tester.element(find.byType(LyricsProvidersPage)),
  );
}

/// 行内开关：行里唯一的 Size(60,48) MusicFlowPressable。
Finder toggles() => find.byWidgetPredicate(
      (Widget w) =>
          w is MusicFlowPressable && w.minimumSize == const Size(60, 48),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // drift 连接会问 path_provider 要文档目录，测试里指到临时路径。
  // 注意通道名必须带 plugins.flutter.io 前缀（踩坑 #195-D），裸名 mock 无效。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/mf_lyrics_providers_test_db',
  );
  // 清掉共享临时库并重建目录：AppDatabase 会种子默认行，残留库会让上一轮
  // 写入（enabled=false / priority 重排）跨轮泄漏导致断言假绿；且
  // NativeDatabase 要求目录存在（踩坑 #202-D 姿势：清后 createSync）。
  final tmpDir = Directory('/tmp/mf_lyrics_providers_test_db');
  if (tmpDir.existsSync()) {
    tmpDir.deleteSync(recursive: true);
  }
  tmpDir.createSync(recursive: true);

  group('LyricsProvidersPage · 三态', () {
    testWidgets('loading 显示骨架', (tester) async {
      await _pump(tester);
      await tester.pump();

      expect(find.byType(MusicFlowProviderListSkeleton), findsWidgets);
      expect(find.byType(MusicFlowProviderSettingRow), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error 显示错误态，重试可重订阅流', (tester) async {
      final loc = await _pump(tester);
      await tester.pump();
      _ctrl.addError(StateError('boom'), StackTrace.current);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text(loc.settings_lyrics_provider_page_error_title),
        findsOneWidget,
      );
      expect(find.byType(MusicFlowErrorState), findsWidgets);
      expect(find.text(loc.widgets_retry), findsOneWidget);

      // 点重试 → invalidate → 重订阅流 → 推数据恢复。
      await tester.tap(find.text(loc.widgets_retry));
      await tester.pump();
      _ctrl.add(kConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(MusicFlowProviderSettingRow), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('空列表显示空态', (tester) async {
      final loc = await _pump(tester);
      await tester.pump();
      _ctrl.add(const <ProviderConfig>[]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text(loc.settings_lyrics_provider_empty_title),
        findsOneWidget,
      );
      expect(find.byType(MusicFlowEmptyState), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('LyricsProvidersPage · 命名与描述', () {
    testWidgets('四类内置源走本地化名，未知源回落 sourceId', (tester) async {
      final loc = await _pump(tester);
      await tester.pump();
      _ctrl.add(kConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(loc.settings_priority_order), findsOneWidget);
      expect(find.text(loc.settings_provider_subsonic), findsOneWidget);
      expect(find.text('LRCLIB'), findsOneWidget);
      expect(find.text(loc.settings_provider_netease), findsOneWidget);
      expect(find.text(loc.settings_provider_custom), findsOneWidget);
      // 未知源：标题直接用 sourceId，描述为空字符串（不渲染空 Text 节点）。
      expect(find.text('weird-source'), findsOneWidget);
      expect(find.text(loc.settings_lyrics_provider_subsonic_desc),
          findsOneWidget);
      expect(find.text(loc.settings_lyrics_provider_lrclib_desc),
          findsOneWidget);
      expect(find.text(loc.settings_lyrics_provider_netease_desc),
          findsOneWidget);
      expect(find.text(loc.settings_lyrics_provider_custom_desc),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('LyricsProvidersPage · 启停开关', () {
    testWidgets('拨动开关 → toggleLyricsProvider 落库 enabled=false',
        (tester) async {
      final loc = await _pump(tester);
      await tester.pump();
      _ctrl.add(kConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(toggles(), findsNWidgets(5));
      await tester.tap(toggles().first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 真库断言：lyrics_subsonic 行 enabled 已写为 false。
      // FakeAsync 环境真实 I/O 不会完成，必须 runAsync 逃逸并轮询等待
      // 页面 onTap 里的异步写库落盘（最多 ~3s）。
      dynamic subsonic;
      await tester.runAsync(() async {
        for (var i = 0; i < 60; i++) {
          final rows =
              await sharedDb!.select(sharedDb!.lyricsProviderConfigs).get();
          final found =
              rows.where((r) => r.id == 'lyrics_subsonic').toList();
          if (found.isNotEmpty && found.first.enabled == false) {
            subsonic = found.first;
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      expect(subsonic, isNotNull,
          reason: '第一行原本 enabled=true，点关后应写 false 落库');
      expect(subsonic!.enabled, isFalse);

      // invalidate 后重订阅广播流（无重放），测试侧推回停用版验证页面刷新。
      _ctrl.add(
        kConfigs
            .map((c) => c.copyWith(enabled: c.sourceId != 'subsonic'))
            .toList(),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byWidgetPredicate((Widget w) =>
            w is MusicFlowProviderSettingRow && !w.enabled),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      // 消除 lint 未使用告警。
      expect(loc.settings_lyrics_provider, isNotEmpty);
    });
  });

  group('LyricsProvidersPage · 优先级拖拽', () {
    testWidgets('拖动第一行下移 → onReorder 重写库内 priority', (tester) async {
      await _pump(tester);
      await tester.pump();
      _ctrl.add(kConfigs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // onReorder 闭包是被测代码（重排 + updateLyricsProviderOrder 落库 +
      // invalidate）；ReorderableDragStartListener 的 SDK 手势识别链在
      // FakeAsync 下不稳定（多轮 startGesture/move 序列均未触发），不在
      // 被测范围，直接取 widget 调用 onReorder 复刻「首行拖到第三位」。
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorder?.call(0, 2); // ignore: deprecated_member_use
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 真库断言：runAsync 逃逸 FakeAsync，轮询等待 updateLyricsProviderOrder
      // 全表重写落盘（首行 priority 被改写为非 0 即视为完成）。
      // updateLyricsProviderOrder 是串行 N 次 await write（background
      // isolate）：第 1 个请求同步发出，后续 continuation 卡在 FakeAsync
      // microtask 队列（只随 pump flush），而 isolate 响应需要真实 event
      // loop —— 两者必须交替推进：pump → runAsync(delay) → 轮询查库。
      dynamic savedRows;
      for (var i = 0; i < 12 && savedRows == null; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.runAsync(() async {
          final rows =
              await sharedDb!.select(sharedDb!.lyricsProviderConfigs).get();
          final s = rows.where((r) => r.id == 'lyrics_subsonic').toList();
          if (s.isNotEmpty && s.first.priority != 0) {
            savedRows = rows;
          }
        });
      }
      savedRows ??=
          await tester.runAsync(() =>
              sharedDb!.select(sharedDb!.lyricsProviderConfigs).get());
      final subsonic = savedRows.firstWhere((r) => r.id == 'lyrics_subsonic');
      expect(
        subsonic.priority,
        isNot(0),
        reason: '首行被拖离顶部后 updateLyricsProviderOrder 重写了 priority',
      );
      // 各行 priority 仍是连续序（重写走全表 0..n）。
      final priorities = savedRows.map((r) => r.priority).toSet();
      expect(priorities.length, savedRows.length, reason: 'priority 互不重复');
      expect(tester.takeException(), isNull);
    });
  });
}
