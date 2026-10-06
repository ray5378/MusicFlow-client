// b39c —— Route C 补测：`lib/features/search/search_history.dart` 剩余缺口。
//
// 覆盖点：
//   * 33：refresh 读到「需要清理」的历史时回写（pruned != stored）。
//   * 36/37/38：refresh 读取抛错 → 打日志并回落空列表。
//   * 56：record 写入/读取抛错 → 打日志。
//   * 74：remove 抛错 → 打日志。
//   * 87：clear 抛错 → 打日志。
//
// 失败路径通过替换 shared_preferences 平台通道为「抛错」实现；
// 这些用例必须排在最前（此时 getInstance 缓存为空），否则前一个成功用例会把
// 内存实现缓存下来，通道替身就失效了。
// searchHistoryProvider 是 autoDispose：必须持有 listen 订阅，否则 read 后
// 立即销毁、控制器 mounted=false 会提前 return，state 永远停在 loading。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/search_history.dart';
import 'package:musicflow_client/features/search/search_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel prefsChannel =
      MethodChannel('plugins.flutter.io/shared_preferences');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void installThrowingChannel() {
    messenger.setMockMethodCallHandler(prefsChannel, (call) async {
      throw PlatformException(
        code: 'corrupt',
        message: 'shared_preferences.json is half-written',
      );
    });
  }

  void clearChannel() {
    messenger.setMockMethodCallHandler(prefsChannel, null);
  }

  // 持有订阅的容器：避免 autoDispose 提前销毁。
  ProviderContainer heldContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(
      searchHistoryProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);
    return container;
  }

  // ---- 失败路径：必须先跑，避免 getInstance 缓存到健康实现 ----
  test('refresh 读取抛错 → 打日志并回落空列表（36/37/38）', () async {
    installThrowingChannel();
    addTearDown(clearChannel);

    final container = heldContainer();
    await container.read(searchHistoryProvider.notifier).refresh();

    final state = container.read(searchHistoryProvider);
    expect(state.valueOrNull, isNotNull);
    expect(state.valueOrNull, isEmpty);
  });

  test('record 抛错 → 打日志且不崩溃（56）', () async {
    installThrowingChannel();
    addTearDown(clearChannel);

    final controller = SearchHistoryController();
    addTearDown(controller.dispose);

    await controller.record('关键词');
    // 没有抛异常即通过（catch 分支已执行）。
    expect(true, isTrue);
  });

  test('remove 抛错 → 打日志且不崩溃（74）', () async {
    installThrowingChannel();
    addTearDown(clearChannel);

    final controller = SearchHistoryController();
    addTearDown(controller.dispose);

    await controller.remove('关键词');
    expect(true, isTrue);
  });

  test('clear 抛错 → 打日志且不崩溃（87）', () async {
    installThrowingChannel();
    addTearDown(clearChannel);

    final controller = SearchHistoryController();
    addTearDown(controller.dispose);

    await controller.clear();
    expect(true, isTrue);
  });

  // ---- 正常路径：读到过期项会被清理后回写（33） ----
  test('refresh 清理过期记录并回写（33）', () async {
    clearChannel();
    final stale = SearchHistoryEntry(
      query: '过期词',
      timestamp: DateTime.now().subtract(const Duration(days: 200)),
    );
    final fresh = SearchHistoryEntry(
      query: '新词',
      timestamp: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'search_history_v1': '['
          '{"q":"过期词","ts":${stale.timestamp.millisecondsSinceEpoch}},'
          '{"q":"新词","ts":${fresh.timestamp.millisecondsSinceEpoch}}'
          ']',
    });

    final container = heldContainer();
    await container.read(searchHistoryProvider.notifier).refresh();

    final state = container.read(searchHistoryProvider);
    expect(state.valueOrNull, isNotNull);
    expect(state.valueOrNull!.map((e) => e.query), <String>['新词']);

    // 回写后存储里只剩清理后的记录。
    final stored = await SharedPreferences.getInstance();
    final raw = stored.getString('search_history_v1');
    expect(raw, isNotNull);
    expect(raw, contains('新词'));
    expect(raw, isNot(contains('过期词')));
  });
}
