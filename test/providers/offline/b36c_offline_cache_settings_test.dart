// b36c —— `lib/providers/offline/offline_cache_settings_provider.dart` 补测
// （原 16/32）。
//
// 覆盖：构造时 _load（读取持久化开关+档位并同步到管理器，enabled 时写容量）/
// setSize（隐含开启 + 落盘 + 同步容量）/ disable（停止写入 + clearAll）/
// enable（沿用上次档位重新开启）。
//
// 打桩：用真实 OfflineCacheManager(rootForTest: 临时目录) 替换管理器 provider
// （脱离 path_provider），offlineCacheReadyProvider 覆写为等待其 init 完成；
// SharedPreferences 走 mock 初始值。
//
// 产品代码零改动；只读 lib。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/data/models/offline_cache_size.dart';
import 'package:musicflow_client/providers/offline/offline_cache_settings_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late OfflineCacheManager manager;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('b36c_offline_cache');
    manager = OfflineCacheManager(rootForTest: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: <Override>[
        offlineCacheManagerProvider.overrideWithValue(manager),
        offlineCacheReadyProvider.overrideWith(
          (ref) => manager.init(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('构造时读取默认设置并同步到管理器', () async {
    final container = makeContainer();
    final state = container.read(offlineCacheSettingsProvider);
    // 同步初值（构造同步返回）。
    expect(state.enabled, isTrue);

    await _settle();

    final settled = container.read(offlineCacheSettingsProvider);
    expect(settled.enabled, isTrue);
    expect(settled.size, OfflineCacheSize.g2);
    expect(manager.enabled, isTrue);
    expect(manager.maxBytes, OfflineCacheSize.g2.maxBytes);
  });

  test('setSize 隐含开启、落盘并同步容量', () async {
    final container = makeContainer();
    final notifier = container.read(offlineCacheSettingsProvider.notifier);
    await _settle();

    await notifier.setSize(OfflineCacheSize.g5);
    await _settle();

    expect(container.read(offlineCacheSettingsProvider).size, OfflineCacheSize.g5);
    expect(container.read(offlineCacheSettingsProvider).enabled, isTrue);
    expect(manager.enabled, isTrue);
    expect(manager.maxBytes, OfflineCacheSize.g5.maxBytes);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('offline_cache_size'), OfflineCacheSize.g5.name);
    expect(prefs.getBool('offline_cache_enabled'), isTrue);
  });

  test('disable 停止写入并清空缓存', () async {
    final container = makeContainer();
    final notifier = container.read(offlineCacheSettingsProvider.notifier);
    await _settle();

    await notifier.disable();
    await _settle();

    final state = container.read(offlineCacheSettingsProvider);
    expect(state.enabled, isFalse);
    expect(manager.enabled, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('offline_cache_enabled'), isFalse);
  });

  test('enable 沿用上次档位重新开启', () async {
    final container = makeContainer();
    final notifier = container.read(offlineCacheSettingsProvider.notifier);
    await _settle();

    await notifier.setSize(OfflineCacheSize.g3);
    await _settle();
    await notifier.disable();
    await _settle();
    expect(container.read(offlineCacheSettingsProvider).enabled, isFalse);

    await notifier.enable();
    await _settle();

    final state = container.read(offlineCacheSettingsProvider);
    expect(state.enabled, isTrue);
    expect(state.size, OfflineCacheSize.g3);
    expect(manager.enabled, isTrue);
    expect(manager.maxBytes, OfflineCacheSize.g3.maxBytes);
  });
}
