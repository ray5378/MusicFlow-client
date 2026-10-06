// b38c3 —— Route C 补测：首页分区编辑页剩余缺口。
//   * home_section_edit_page.dart：143/144/146-152（ReorderableListView 的
//     proxyDecorator：拖拽上屏时包裹 AnimatedBuilder + Material(elevation lerp)）。
//
// 手法：homeSectionLayoutProvider 用 HomeSectionLayoutNotifier 子类覆写
// （build 直接返回内存布局、save 只记录不落盘），页面不触发 SharedPreferences；
// 用 ReorderableDragStartListener 的真实拖拽让 proxy 上屏（buildDefaultDragHandles=false，
// 拖拽只经行尾把手）。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/features/discover/home_section_registry.dart';
import 'package:musicflow_client/features/discover/pages/home_section_edit_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/home_section_layout_provider.dart';

class _FakeLayoutNotifier extends HomeSectionLayoutNotifier {
  _FakeLayoutNotifier(this.initial);

  final HomeSectionLayout initial;
  HomeSectionLayout? saved;

  @override
  Future<HomeSectionLayout> build() async => initial;

  @override
  Future<void> save(HomeSectionLayout layout) async {
    saved = layout;
    state = AsyncData<HomeSectionLayout>(layout);
  }
}

late AppLocalizations loc;

class _Harness {
  _Harness({this.notifier});

  final _FakeLayoutNotifier? notifier;

  late ProviderContainer container;

  Widget build(WidgetTester tester) {
    final notifier = this.notifier ?? _FakeLayoutNotifier(HomeSectionLayout.empty);
    container = ProviderContainer(
      overrides: <Override>[
        homeSectionLayoutProvider.overrideWith(() => notifier),
      ],
    );
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: const HomeSectionEditPage(),
      ),
    );
  }
}

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('home_section_edit：编辑页渲染全部默认分区行', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    // 6 个可拖动分区 + mini 播放器固定行。
    expect(find.byIcon(AppIcons.drag), findsNWidgets(kDefaultHomeSectionKeys.length));
    expect(find.text(loc.home_section_mini_player), findsOneWidget);
    expect(find.text(loc.home_section_customize_done), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home_section_edit：拖拽把手触发 proxyDecorator 且完成落盘（143/144/146-152）',
      (tester) async {
    final notifier = _FakeLayoutNotifier(HomeSectionLayout.empty);
    final h = _Harness(notifier: notifier);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    // 拖起前：没有任何高 elevation 的 Material（proxy 未创建）。
    int raisedMaterials() => tester
        .widgetList<Material>(find.byType(Material))
        .where((m) => m.elevation > 0)
        .length;
    final before = raisedMaterials();

    final handles = find.byIcon(AppIcons.drag);
    final start = tester.getCenter(handles.at(0));
    final end = tester.getCenter(handles.at(2));

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    // 拖拽需要指针位移才真正启动（proxy 在位移后上屏）。
    await gesture.moveTo(end);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 拖拽期：proxy 的 Material(elevation = lerpDouble(0, 8, t)) 已上屏且动画推进。
    final dragged = tester
        .widgetList<Material>(find.byType(Material))
        .where((m) => m.elevation > 0)
        .length;
    expect(dragged, greaterThan(before),
        reason: 'proxyDecorator 应在拖拽期构建抬升的 Material');

    await gesture.up();
    await tester.pumpAndSettle();

    // 完成 → save 被调用，顺序已改变（证明拖拽真实生效、非 no-op）。
    await tester.tap(find.text(loc.home_section_customize_done));
    await settle(tester);
    expect(notifier.saved, isNotNull);
    expect(notifier.saved!.order, isNot(equals(kDefaultHomeSectionKeys)));
    expect(notifier.saved!.order.length, kDefaultHomeSectionKeys.length);
    expect(tester.takeException(), isNull);
  });
}
