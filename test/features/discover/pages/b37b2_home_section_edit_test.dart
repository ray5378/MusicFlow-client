// b37b2 —— `lib/features/discover/pages/home_section_edit_page.dart` 残余分支补测。
//
// 已有 home_section_edit_page_test.dart 覆盖：全量展示、关开关隐藏、向下拖拽、
// 完成保存。本文件补：
//   * 把已隐藏分区「重新打开」（visible=true → _hidden.remove + 保存）；
//   * mini 播放器固定行的开关（不影响 _order，只改 miniPlayerVisible）；
//   * 拖拽把手**向上**拖（_handleReorder 的 newIndex<=oldIndex 分支）；
//   * 初始布局带隐藏项时，编辑页仍展示该行（开关初值为关）。
// 产品代码零改动；仅新增 test/。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/sources/prefs_gate.dart';
import 'package:musicflow_client/features/discover/pages/home_section_edit_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/home_section_layout_provider.dart';

class _FixedHomeSectionLayoutNotifier extends HomeSectionLayoutNotifier {
  _FixedHomeSectionLayoutNotifier(this._initial);

  final HomeSectionLayout _initial;

  @override
  Future<HomeSectionLayout> build() async => _initial;
}

void main() {
  ProviderContainer? container;

  Future<void> pumpEditPage(
    WidgetTester tester, {
    required HomeSectionLayout initial,
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
    // 先把布局 provider 解析成 AsyncData：initState 用 valueOrNull 读初值，
    // 若仍处于 loading 会回落 empty，导致初始 hidden 丢失。
    await c.read(homeSectionLayoutProvider.future);
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

  HomeSectionLayout layoutOf() => container!.read(homeSectionLayoutProvider).value!;

  testWidgets('已隐藏分区：重新打开开关 + 完成 → hidden 移除该项', (tester) async {
    await pumpEditPage(
      tester,
      initial: const HomeSectionLayout(
        order: <String>['random-songs', 'home-recommend'],
        hidden: <String>['home-recommend'],
      ),
    );

    // 编辑页始终展示全部行；「为你推荐」开关初值为关（在 hidden 里）。
    final recSwitch = find.descendant(
      of: find.byKey(const ValueKey<String>('home-section-edit-home-recommend')),
      matching: find.byType(Switch),
    );
    expect(recSwitch, findsOneWidget);
    expect(tester.widget<Switch>(recSwitch).value, isFalse);

    await tester.tap(recSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final layout = layoutOf();
    expect(layout.hidden, isNot(contains('home-recommend')),
        reason: '重新打开开关后应把该分区移出 hidden');
  });

  testWidgets('mini 播放器固定行开关 → 只改 miniPlayerVisible，不动 order', (tester) async {
    await pumpEditPage(
      tester,
      initial: const HomeSectionLayout(
        order: <String>['random-songs'],
        miniPlayerVisible: true,
      ),
    );

    // 顶部固定行：文本「迷你播放器」，其行内开关。
    final miniRow = find.ancestor(
      of: find.text('迷你播放器'),
      matching: find.byType(Row),
    );
    final miniSwitch = find.descendant(of: miniRow, matching: find.byType(Switch));
    expect(tester.widget<Switch>(miniSwitch).value, isTrue);

    await tester.tap(miniSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final layout = layoutOf();
    expect(layout.miniPlayerVisible, isFalse);
    expect(layout.order, contains('random-songs'), reason: 'mini 行不参与分区排序');
  });

  testWidgets('拖拽把手向上移动 → 顺序上移（newIndex<=oldIndex 分支）', (tester) async {
    await pumpEditPage(tester, initial: HomeSectionLayout.empty);

    // 取树中顺序排列的分区行 key。
    final rowKeys = find
        .byWidgetPredicate((Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('home-section-edit-'))
        .evaluate()
        .map((e) => (e.widget.key! as ValueKey<String>).value)
        .toList();
    expect(rowKeys.length, greaterThan(1));
    final secondKey = rowKeys[1].replaceFirst('home-section-edit-', '');

    // 把第二行把手向上拖到首位。
    final row = find.byKey(ValueKey<String>('home-section-edit-$secondKey'));
    final handle = find.descendant(
      of: row,
      matching: find.byType(ReorderableDragStartListener),
    );
    expect(handle, findsOneWidget);

    await tester.drag(handle, const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final order = layoutOf().order;
    expect(order.first, secondKey,
        reason: '向上拖到首位后该项应排在最前');
  });

  testWidgets('初始布局为空：编辑页回落到客户端默认清单，不崩', (tester) async {
    await pumpEditPage(tester, initial: HomeSectionLayout.empty);
    expect(find.text('完成'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
