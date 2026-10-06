// b39b —— Route B：HomeSectionLayoutNotifier.save 落盘失败兜底补测。
//
// 覆盖 lcov 未命中行：
//   * home_section_layout_provider.dart:30  save() 落盘失败时的 catch 日志
//
// 触发链：SharedPreferences 平台通道抛错 → LocalStorage.saveHomeSectionLayout
// 内部 `getPrefs()` 抛 MissingPluginException → 命中 save() 的 catch → line 30。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/providers/ui/home_section_layout_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel prefsChannel = MethodChannel(
    'plugins.flutter.io/shared_preferences',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(prefsChannel, null);
  });

  test('save 落盘失败被吞并保留内存态（line 30）', () async {
    // 强制 prefs 通道抛错：无论 build 还是 save 都拿不到存储。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(prefsChannel, (MethodCall call) async {
      throw MissingPluginException('prefs unavailable (b39b)');
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(homeSectionLayoutProvider.notifier);
    const layout = HomeSectionLayout(
      order: <String>['discover'],
      hidden: <String>['radio'],
    );

    // 落盘会抛错，但被 catch 吞掉：不应向调用方抛出。
    await expectLater(notifier.save(layout), completes);

    // 内存态已先行更新（UI 立即生效）。
    expect(
      container.read(homeSectionLayoutProvider).valueOrNull?.order,
      <String>['discover'],
    );
  });
}
