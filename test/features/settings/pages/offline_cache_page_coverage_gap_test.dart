import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/offline_cache_size.dart';
import 'package:musicflow_client/features/settings/pages/offline_cache_page.dart';
import 'package:musicflow_client/features/settings/widgets/music_flow_settings_components.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/offline/offline_cache_settings_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

/// 缓存管理器桩：只提供设置页读到的三个入口（占用总量 / 分类计数 / 清空）。
/// 真 manager 会去 path_provider 建目录并扫磁盘，测试里没有意义。
class TestOfflineCache extends OfflineCacheManager {
  TestOfflineCache({this.bytes = 0, this.counts});

  int bytes;
  Map<OfflineCacheKind, int>? counts;
  int clearCalls = 0;

  @override
  int get totalBytes => bytes;

  @override
  Map<OfflineCacheKind, int> countByKind() =>
      counts ?? {for (final k in OfflineCacheKind.values) k: 0};

  @override
  Future<void> clearAll() async {
    clearCalls += 1;
    bytes = 0;
  }
}

/// 设置 notifier 桩：把“选档位 / 关闭”的调用记下来，不碰持久化与磁盘。
class TestOfflineSettings extends OfflineCacheSettingsNotifier {
  TestOfflineSettings(super.ref);

  List<OfflineCacheSize> setSizeCalls = <OfflineCacheSize>[];
  int disableCalls = 0;

  @override
  Future<void> setSize(OfflineCacheSize size) async {
    setSizeCalls.add(size);
    state = OfflineCacheSettings(enabled: true, size: size);
  }

  @override
  Future<void> disable() async {
    disableCalls += 1;
    state = OfflineCacheSettings(enabled: false, size: state.size);
  }
}

TestOfflineCache? lastCache;
TestOfflineSettings? lastSettings;

Future<void> _pump(
  WidgetTester tester, {
  int bytes = 0,
  Map<OfflineCacheKind, int>? counts,
  OfflineCacheSize size = OfflineCacheSize.g2,
  bool enabled = true,
  Size size2 = const Size(900, 1200),
}) async {
  lastCache = TestOfflineCache(bytes: bytes, counts: counts);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        offlineCacheManagerProvider.overrideWith((ref) => lastCache!),
        offlineCacheReadyProvider.overrideWith(
          (ref) => Future<void>.value(),
        ),
        offlineCacheSettingsProvider.overrideWith((ref) {
          final s = TestOfflineSettings(ref);
          lastSettings = s;
          return s;
        }),
      ],
      child: MediaQuery(
        data: MediaQueryData(size: size2),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(body: OfflineCachePage()),
        ),
      ),
    ),
  );
  // 页面 initState 等 ready → _refresh()，给一帧把 setState 放出来。
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
  // [D-011] enabled=false 时「关闭」行 onPressed 为空（已是关闭态），
  // 测试直接把 stub 状态摆成 enabled 与否来覆盖两条分支。
  lastSettings!.state = OfflineCacheSettings(enabled: enabled, size: size);
  await tester.pump();
}

/// 容量档位行 = ChoiceRow（title/description 都是 displayName，
/// 所以按文本找会撞到两个 Text，统一用「行本体」来定位）。
Finder _sizeRow(OfflineCacheSize s) =>
    find
        .widgetWithText(MusicFlowChoiceRow, s.displayName)
        .first;

/// 「找到某个 ChoiceRow，且它的子树里出现这段文本」——用于定位档位行本体。
Finder _choiceRowWith(String text) =>
    find.widgetWithText(MusicFlowChoiceRow, text);

/// 清空按钮本体（MusicFlowButton）。
Finder _clearButton() =>
    find.widgetWithText(MusicFlowButton, '清空缓存');

Finder _byText(String text) => find.text(text);

void main() {
  group('OfflineCachePage · 用量面板', () {
    testWidgets('四类缓存计数与「已用」标题都渲染出来', (tester) async {
      await _pump(
        tester,
        bytes: 3 * 1024 * 1024,
        counts: <OfflineCacheKind, int>{
          OfflineCacheKind.song: 4,
          OfflineCacheKind.lyric: 5,
          OfflineCacheKind.cover: 6,
          OfflineCacheKind.playlistCover: 7,
        },
      );

      expect(find.byType(OfflineCachePage), findsOneWidget);
      expect(_byText('缓存占用'), findsOneWidget);
      expect(_byText('已用'), findsOneWidget);
      expect(_byText('歌曲'), findsOneWidget);
      expect(_byText('歌词'), findsOneWidget);
      expect(_byText('封面'), findsOneWidget);
      expect(_byText('歌单封面'), findsOneWidget);
      // 计数走 countByKind，缺哪个类型按 0 显示（不为 null）。
      expect(_byText('4'), findsOneWidget);
      expect(_byText('5'), findsOneWidget);
      expect(_byText('6'), findsOneWidget);
      expect(_byText('7'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('零占用显示 0 B 且清空按钮置灰', (tester) async {
      await _pump(tester, bytes: 0);
      expect(_byText('0 B'), findsOneWidget);
      final disabled = tester.widget<MusicFlowButton>(_clearButton());
      expect(disabled.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('小容量按 KB 格式化', (tester) async {
      await _pump(tester, bytes: 2048);
      expect(_byText('2 KB'), findsOneWidget);
      expect(
        tester.widget<MusicFlowButton>(_clearButton()).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('中等容量按 MB 格式化', (tester) async {
      await _pump(tester, bytes: 3 * 1024 * 1024);
      expect(_byText('3.0 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('大容量按 GB 格式化', (tester) async {
      await _pump(tester, bytes: 5 * 1024 * 1024 * 1024);
      expect(_byText('5.00 GB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空计数时四类仍渲染 0 而不是崩溃', (tester) async {
      await _pump(tester, bytes: 1024);
      // 四类计数都为 0 → 出现 4 个「0」文本，仍然完整渲染。
      expect(_byText('0'), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    });
  });

  group('OfflineCachePage · 容量档位', () {
    testWidgets('关闭行 + 全部档位行都在，当前档位有默认描述', (tester) async {
      await _pump(tester, size: OfflineCacheSize.g2);

      // 「关闭」行文案 + 10 个档位行。
      expect(_byText('关闭'), findsOneWidget);
      for (final s in OfflineCacheSize.values) {
        expect(_sizeRow(s), findsOneWidget, reason: '缺少档位 ${s.name}');
      }
      // g2 是默认档位 → 描述文案为「默认」。
      expect(_choiceRowWith('默认'), findsOneWidget);
      expect(
        tester.widget<MusicFlowChoiceRow>(_choiceRowWith('默认')).selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点档位交给 notifier.setSize 且状态即时更新', (tester) async {
      await _pump(tester, size: OfflineCacheSize.g2);

      await tester.tap(_sizeRow(OfflineCacheSize.g5));
      await tester.pump();

      expect(lastSettings!.setSizeCalls, <OfflineCacheSize>[OfflineCacheSize.g5]);
      // 选中态跟着 notifier 走：g5 变成 selected。
      // 同一行里 title 与 description 都是 displayName（两个 Text），
      // ancestor 会对每个起点各返回一个祖先，取第一个即可。
      final g5Row = find
          .ancestor(
            of: _byText(OfflineCacheSize.g5.displayName),
            matching: find.byType(MusicFlowChoiceRow),
          )
          .first;
      expect(tester.widget<MusicFlowChoiceRow>(g5Row).selected, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('OfflineCachePage · 清空缓存', () {
    testWidgets('有占用时清空按钮可用，点击后清空并提示', (tester) async {
      await _pump(tester, bytes: 7 * 1024 * 1024);

      final button = tester.widget<MusicFlowButton>(_clearButton());
      expect(button.onPressed, isNotNull);

      await tester.tap(_byText('清空缓存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(lastCache!.clearCalls, 1);
      expect(find.byType(MusicFlowMessage), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('零占用时按钮置灰且不清空', (tester) async {
      await _pump(tester, bytes: 0);

      await tester.tap(_byText('清空缓存'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(lastCache!.clearCalls, 0);
      expect(find.byType(MusicFlowMessage), findsNothing);
    });
  });

  group('OfflineCachePage · 关闭确认', () {
    testWidgets('确认后关闭并提示已关闭', (tester) async {
      await _pump(tester, bytes: 9 * 1024 * 1024, enabled: true);

      await tester.tap(_byText('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 确认框带当前占用体积。
      expect(find.textContaining('9.0 MB'), findsWidgets);

      await tester.tap(_byText('关闭并清除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(lastSettings!.disableCalls, 1);
      expect(find.byType(MusicFlowMessage), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消关闭则不关闭也不清空', (tester) async {
      await _pump(tester, bytes: 9 * 1024 * 1024, enabled: true);

      await tester.tap(_byText('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(_byText('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(lastSettings!.disableCalls, 0);
      expect(lastCache!.clearCalls, 0);
      expect(lastSettings!.state.enabled, isTrue);
    });
  });

  group('OfflineCachePage · 页头', () {
    testWidgets('标题为离线缓存且带返回项', (tester) async {
      await _pump(tester);
      expect(_byText('离线缓存'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
