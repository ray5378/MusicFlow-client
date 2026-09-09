import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/sources/prefs_gate.dart';
import 'package:musicflow_client/features/discover/pages/home_section_edit_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/home_section_layout_provider.dart';

/// 首页分区编辑页(客户端自治)交互测试:
/// 5 个分区行全量展示、显隐开关、拖拽排序、完成保存进 provider 并返回。
void main() {
  ProviderContainer? container;

  Future<void> pumpEditPage(
    WidgetTester tester, {
    HomeSectionLayout initial = HomeSectionLayout.empty,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final c = ProviderContainer(
      overrides: <Override>[
        homeSectionLayoutProvider.overrideWith(
          () => _FixedHomeSectionLayoutNotifier(initial),
        ),
      ],
    );
    container = c;
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const HomeSectionEditPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows all five sections with switches and drag handles', (
    tester,
  ) async {
    await pumpEditPage(tester);

    // 编辑页始终展示客户端认识的全部分区(含隐藏的)。
    for (final name in <String>['随机歌曲', '最近更新的歌单', '为你推荐', '平台推荐', '插件推荐']) {
      expect(
        find.descendant(of: find.byType(HomeSectionEditPage), matching: find.text(name)),
        findsOneWidget,
        reason: '编辑页应展示分区行「$name」',
      );
    }
    // 每行一个显隐开关 + 一个拖拽把手。
    expect(find.byType(Switch), findsNWidgets(5));
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(5));
    expect(find.text('完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling a switch off then done persists hidden section', (
    tester,
  ) async {
    await pumpEditPage(tester);

    // 默认顺序第 3 行是「为你推荐」(home-recommend),关闭其开关。
    await tester.tap(find.byType(Switch).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final layout = container!.read(homeSectionLayoutProvider).value;
    expect(layout, isNotNull);
    expect(layout!.hidden, contains('home-recommend'));
  });

  testWidgets('dragging the handle reorders, done persists the order', (
    tester,
  ) async {
    await pumpEditPage(tester);

    // 把「随机歌曲」行尾把手向下拖两行。
    final row = find.byKey(const ValueKey<String>('home-section-edit-random-songs'));
    final handle = find.descendant(
      of: row,
      matching: find.byType(ReorderableDragStartListener),
    );
    expect(handle, findsOneWidget);
    await tester.drag(handle, const Offset(0, 140));
    await tester.pumpAndSettle();

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final layout = container!.read(homeSectionLayoutProvider).value;
    expect(layout, isNotNull);
    final order = layout!.order;
    expect(order, hasLength(5), reason: '拖拽只改顺序,不应丢失分区');
    expect(order.first, isNot('random-songs'), reason: '「随机歌曲」被向下拖动后不应仍在首位');
  });
}

/// 固定初始布局的 Fake notifier(不落盘,save 走父类仅写 mock prefs)。
class _FixedHomeSectionLayoutNotifier extends HomeSectionLayoutNotifier {
  _FixedHomeSectionLayoutNotifier(this._initial);

  final HomeSectionLayout _initial;

  @override
  Future<HomeSectionLayout> build() async => _initial;
}
