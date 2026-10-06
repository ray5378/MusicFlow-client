// Route C 补测：`lib/features/library/widgets/windowed_paginated_list.dart`
// 与 `lib/features/library/widgets/windowed_list_view.dart` 的剩余缺口。
//
// 覆盖点：
//   * windowed_paginated_list.dart
//     - 76/77/131-135：滚动窗口外整块剪枝 `_nullPage`（keepPages 之外的旧块置 null）
//     - 63：`retry()` 以当前 query 重拉
//     - 126：`_growTo` 在「列表总长在分页途中增长」时把旧槽位拷进更长的稀疏数组
//   * windowed_list_view.dart
//     - 53：`initState` 时 controller 尚未加载（total<=0 且非 loading）→ 主动 `load('')`
//     - 61-64：`didUpdateWidget` 换了新 controller → 换监听并对新 controller 首拉
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/library/widgets/windowed_list_view.dart';
import 'package:musicflow_client/features/library/widgets/windowed_paginated_list.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 固定数据源的分页控制器；[total] 为服务端总长。
class _FakeList {
  _FakeList(this.total, {this.growTo});

  final int total;
  final int? growTo;
  int calls = 0;

  WindowedPaginatedList<String> build({int pageSize = 1, int keepPages = 1}) =>
      WindowedPaginatedList<String>(
        pageSize: pageSize,
        keepPages: keepPages,
        concurrency: 32,
        fetcher: (page, size, query) async {
          calls++;
          final effective = (growTo != null && calls > 1) ? growTo! : total;
          final start = (page - 1) * size;
          final n = (effective - start).clamp(0, size);
          return (
            items: List<String>.generate(n, (i) => 'song-${start + i}'),
            total: effective,
          );
        },
      );
}

Future<void> _settle([int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: child),
      ),
    );

void main() {
  test('窗口外整块剪枝：keepPages 之外的旧块置 null（76/77/131-135）', () async {
    final source = _FakeList(10);
    final controller = source.build(pageSize: 1, keepPages: 1);

    controller.load('');
    await _settle();

    // 全部 10 页均已到达（concurrency=32 不做限流）。
    expect(controller.total, 10);
    for (var i = 0; i < 10; i++) {
      expect(controller[i], isNotNull, reason: '第 $i 槽位应已加载');
    }

    // 视口跳到最后一页：first=9 → pruneFirst=8，0..7 页被剪枝。
    controller.ensureRange(9, 9);
    await _settle();

    expect(controller[0], isNull, reason: '0 号块已被剪枝回 null');
    expect(controller[7], isNull, reason: '7 号块在窗口外，已剪枝');
    expect(controller[8], isNotNull, reason: '8 号块仍在 keepPages 窗口内');
    expect(controller[9], isNotNull, reason: '当前视口所在块必须保留');
  });

  test('retry() 以当前 query 重新拉取（63）', () async {
    final source = _FakeList(4);
    final controller = source.build(pageSize: 2, keepPages: 2);

    controller.load('abc');
    await _settle();
    final afterFirstLoad = source.calls;
    expect(controller.total, 4);
    expect(controller[0], 'song-0');

    // 人为置错后 retry：应重新走一次 fetcher（而不是什么都不做）。
    controller.retry();
    await _settle();

    expect(
      source.calls,
      greaterThan(afterFirstLoad),
      reason: 'retry 必须重新发起一次拉取',
    );
    expect(controller[0], 'song-0', reason: 'retry 后数据应重新可用');
    expect(controller.hasError, isFalse);
  });

  test('分页途中总长增长：_growTo 把旧槽位拷进更长的数组（126）', () async {
    // 首块报 total=4，后续块报 total=8：第二次 _growTo 时 _slots 非空且更短，
    // 才会走到「逐位拷贝」这一行。
    final source = _FakeList(4, growTo: 8);
    final controller = source.build(pageSize: 2, keepPages: 4);

    controller.load('');
    await _settle();

    expect(controller.total, 8, reason: '总长被后续块刷新为 8');
    expect(controller.slots.length, 8, reason: '稀疏数组被扩容到新总长');
    expect(controller[0], 'song-0', reason: '首块槽位在扩容后仍然保留');
    expect(controller[3], 'song-3');
    expect(controller[7], isNull, reason: '尚未抓取的槽位仍为 null');
  });

  testWidgets('WindowedListView 首次挂载时自动首拉（53）', (tester) async {
    final source = _FakeList(3);
    final controller = source.build(pageSize: 3, keepPages: 2);

    await tester.pumpWidget(
      _wrap(
        WindowedListView<String>(
          controller: controller,
          itemBuilder: (context, index, item) =>
              Text(item ?? 'placeholder-$index'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // 挂载即触发 load('')：无需外部调用方手动拉第一页。
    expect(source.calls, 1, reason: 'initState 应主动 load("")');
    expect(controller.total, 3);
    expect(find.text('song-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WindowedListView 换 controller 后换监听并重新首拉（61-64）',
      (tester) async {
    final first = _FakeList(2);
    final controllerA = first.build(pageSize: 2, keepPages: 2);

    await tester.pumpWidget(
      _wrap(
        WindowedListView<String>(
          controller: controllerA,
          itemBuilder: (context, index, item) => Text(item ?? 'empty-$index'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('song-0'), findsOneWidget);

    // 换成另一个全新 controller（total=0）：didUpdateWidget 应重新接线并首拉。
    final second = _FakeList(2);
    final controllerB = second.build(pageSize: 2, keepPages: 2);
    await tester.pumpWidget(
      _wrap(
        WindowedListView<String>(
          controller: controllerB,
          itemBuilder: (context, index, item) => Text(item ?? 'empty-$index'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(second.calls, 1, reason: '新 controller 应被自动首拉一次');
    expect(controllerB.total, 2);

    // 旧 controller 的通知不应再驱动重建：给它发通知后界面不应崩溃。
    controllerA.load('stale');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
